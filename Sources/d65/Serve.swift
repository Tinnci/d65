#if os(macOS)
import AppKit
import D65Core
import D65Display
import D65Link
import D65Measurement
import Foundation
import Network

/// Full-screen patch window. Created lazily on the main thread.
final class PatchWindow {
    private var window: NSWindow?

    func show(_ color: NSColor) {
        if let window {
            window.backgroundColor = color
            return
        }
        guard let screen = NSScreen.main else { return }
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.backgroundColor = color
        window.isOpaque = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}

/// Receives phased measurements from the probe and runs one calibration session.
final class CalibrationServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "d65.serve")
    private let applyToDisplay: Bool
    private let ddcTest: Bool
    private let gammaTest: Bool
    private let output = MacDisplayOutput()
    private let normalizer = MeasurementNormalizer(minimumLux: 1)
    private var buffers: [ObjectIdentifier: Data] = [:]
    private var samples: [String: [MeasurementSample]] = [:]
    private var sessionRunning = false
    private var activeConnection: NWConnection?
    private let patch = PatchWindow()

    init(port: UInt16, applyToDisplay: Bool, ddcTest: Bool = false, gammaTest: Bool = false) throws {
        self.applyToDisplay = applyToDisplay
        self.ddcTest = ddcTest
        self.gammaTest = gammaTest
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NWError.posix(.EINVAL)
        }
        listener = try NWListener(using: parameters, on: nwPort)
        listener.service = NWListener.Service(name: "D65", type: Link.serviceType)
    }

    func start() {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("serving \(Link.serviceType) — waiting for a probe")
            case .failed(let error):
                print("listener failed: \(error)")
                exit(1)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        buffers[id] = Data()
        activeConnection = connection

        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("connection failed: \(error)")
            }
        }
        connection.start(queue: queue)
        receive(on: connection, id: id)
    }

    private func receive(on connection: NWConnection, id: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffers[id, default: Data()].append(data)
                self.process(id: id, connection: connection)
            }
            if let error {
                print("receive error: \(error)")
                connection.cancel()
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.receive(on: connection, id: id)
        }
    }

    private func process(id: ObjectIdentifier, connection: NWConnection) {
        guard var buffer = buffers[id] else { return }
        do {
            let messages = try MessageFraming.drain(&buffer)
            buffers[id] = buffer
            for message in messages { handle(message, connection: connection) }
        } catch {
            print("framing error: \(error)")
        }
    }

    private func handle(_ message: CalibrationMessage, connection: NWConnection) {
        switch message {
        case .hello(let model, let build):
            print("probe connected: \(model) / \(build)")
            send(.ready(options: ["targetCCT": Chromaticity.d65.correlatedColorTemperature()]),
                 to: connection)
            startSession()

        case .phasedSample(let phase, let sample):
            samples[phase, default: []].append(sample)

        case .sample, .ready, .progress, .result, .failure, .sensorCalibration:
            break
        }
    }

    private struct Patch {
        let name: String
        let color: NSColor
    }

    private let patches: [Patch] = [
        Patch(name: "black", color: .black),
        Patch(name: "white", color: .white),
        Patch(name: "red", color: .red),
        Patch(name: "green", color: .green),
        Patch(name: "blue", color: .blue),
        Patch(name: "yellow", color: .yellow),
        Patch(name: "cyan", color: .cyan),
        Patch(name: "magenta", color: .magenta),
    ]

    private func startSession() {
        guard !sessionRunning else { return }
        sessionRunning = true
        samples.removeAll()
        print("session: \(patches.count) patches")
        runPatch(at: 0)
    }

    private func runPatch(at index: Int) {
        guard index < patches.count else {
            finishMeasurement()
            return
        }
        let patch = patches[index]
        DispatchQueue.main.async { self.patch.show(patch.color) }
        send(.progress(phase: patch.name, fraction: Double(index) / Double(patches.count)))

        after(2.0) {
            self.send(.progress(phase: "done", fraction: 0))
            self.runPatch(at: index + 1)
        }
    }

    private func mean(_ list: [MeasurementSample]) -> XYZ? {
        guard !list.isEmpty else { return nil }
        let n = Double(list.count)
        return XYZ(
            x: list.reduce(0) { $0 + $1.xyz.x } / n,
            y: list.reduce(0) { $0 + $1.xyz.y } / n,
            z: list.reduce(0) { $0 + $1.xyz.z } / n
        )
    }

    private func filtered(_ list: [MeasurementSample]) -> [MeasurementSample] {
        guard list.count >= 3 else { return list }
        let sorted = list.map(\.xyz.y).sorted()
        let median = sorted[sorted.count / 2]
        let tolerance = max(0.5, median * 0.35)
        return list.filter { abs($0.xyz.y - median) <= tolerance }
    }

    private func subtract(_ lhs: XYZ, _ rhs: XYZ) -> XYZ {
        XYZ(
            x: max(lhs.x - rhs.x, 0),
            y: max(lhs.y - rhs.y, 0),
            z: max(lhs.z - rhs.z, 0)
        )
    }

    private func describe(_ name: String, _ value: XYZ) {
        let chroma = value.chromaticity
        let cct = chroma?.correlatedColorTemperature() ?? 0
        print(String(
            format: "  %-8@ Y=%8.2f  x=%.4f y=%.4f  CCT=%5.0f K",
            name as NSString, value.y, chroma?.x ?? 0, chroma?.y ?? 0, cct
        ))
    }

    private func finishMeasurement() {
        let ambient = mean(filtered(samples["black"] ?? []))
        guard let ambient else {
            print("measurement: no black samples — is the probe pointed at the screen?")
            sessionRunning = false
            return
        }
        print(String(format: "ambient Y=%.2f", ambient.y))

        var emitted: [String: XYZ] = [:]
        for patch in patches where patch.name != "black" {
            guard let raw = mean(filtered(samples[patch.name] ?? [])) else { continue }
            let value = subtract(raw, ambient)
            // Blue has very little luminance; allow it through rather than
            // requiring the patch to out-shine the room.
            if value.y > 0.3 { emitted[patch.name] = value }
        }

        for name in ["white", "red", "green", "blue", "yellow", "cyan", "magenta"] {
            if let value = emitted[name] { describe(name, value) }
        }

        // Additivity: secondaries should be the sum of their primaries if the
        // panel is linear in this range. Large errors mean tone response or
        // cross-channel leakage, neither of which a diagonal gain can fix.
        func additivity(_ secondary: String, _ a: String, _ b: String) {
            guard let s = emitted[secondary], let x = emitted[a], let y = emitted[b] else { return }
            let sum = XYZ(x: x.x + y.x, y: x.y + y.y, z: x.z + y.z)
            let deltaE = ColorDifference.deltaE00(s, sum)
            print(String(format: "  additivity %@ vs %@+%@: ΔE00 %.1f", secondary, a, b, deltaE))
        }
        func comparePrimary(_ name: String, to reference: Chromaticity, label: String) {
            guard let value = emitted[name], let chroma = value.chromaticity else { return }
            let dx = chroma.x - reference.x
            let dy = chroma.y - reference.y
            print(String(format: "  %@ vs %@: Δx=%+.4f Δy=%+.4f", name, label, dx, dy))
        }
        comparePrimary("red", to: Chromaticity(x: 0.640, y: 0.330), label: "sRGB")
        comparePrimary("red", to: Chromaticity(x: 0.680, y: 0.320), label: "P3")
        comparePrimary("green", to: Chromaticity(x: 0.300, y: 0.600), label: "sRGB")
        comparePrimary("green", to: Chromaticity(x: 0.265, y: 0.690), label: "P3")
        comparePrimary("blue", to: Chromaticity(x: 0.150, y: 0.060), label: "sRGB/P3")

        additivity("yellow", "red", "green")
        additivity("cyan", "green", "blue")
        additivity("magenta", "red", "blue")

        guard let white = emitted["white"], white.y > 1 else {
            print("measurement: white too dim — raise display brightness")
            sessionRunning = false
            return
        }

        let gate = QualityGate()
        let full = WhitePointSolver.gains(measuredWhite: white)
        let target = Chromaticity.d65.xyz(luminance: white.y)
        let pre = ColorDifference.deltaE00(white, target)
        let fullPredicted = WhitePointSolver.predictedWhite(after: full, measuredWhite: white)
        let fullPost = ColorDifference.deltaE00(fullPredicted, target)

        print(String(format: "white  CCT≈%.0f K  full gains R=%.4f G=%.4f B=%.4f  ΔE00 %.2f → %.2f  (luminance ×%.3f)",
                     white.chromaticity?.correlatedColorTemperature() ?? 0,
                     full.r, full.g, full.b, pre, fullPost, full.luminanceScale))

        if pre <= gate.minimumPreCorrectionDeltaE {
            print("       display already within tolerance — nothing applied")
            DispatchQueue.main.async { self.patch.close() }
            sessionRunning = false
            return
        }

        // Find the largest blend that still passes the gate. A full correction
        // can be rejected for losing too much luminance; a partial one usually
        // is not, and is better than nothing.
        var chosen: (gains: RGBGains, post: Double, alpha: Double)?
        var alpha = 1.0
        while alpha >= 0.05 {
            let candidate = full.blended(alpha: alpha)
            let predicted = WhitePointSolver.predictedWhite(after: candidate, measuredWhite: white)
            let post = ColorDifference.deltaE00(predicted, target)
            if gate.verdict(preDeltaE: pre, postDeltaE: post, luminanceScale: candidate.luminanceScale) == .improved {
                chosen = (candidate, post, alpha)
                break
            }
            alpha -= 0.05
        }

        guard let chosen else {
            print("       rejected by quality gate at every blend — nothing applied")
            DispatchQueue.main.async { self.patch.close() }
            sessionRunning = false
            return
        }

        let gains = chosen.gains
        print(String(format: "       selected alpha=%.2f  R=%.4f G=%.4f B=%.4f  ΔE00 %.2f → %.2f  luminance ×%.3f",
                     chosen.alpha, gains.r, gains.g, gains.b, pre, chosen.post, gains.luminanceScale))

        if gammaTest {
            let test = RGBGains(r: 1.0, g: 1.0, b: 0.70)
            do {
                try output.apply(test)
                print("       applied test gains R=1.000 G=1.000 B=0.700; re-measuring white")
                startVerification(ambient: ambient, before: pre, restoreRed: nil, resetGammaAfter: true)
            } catch {
                print("       gamma apply failed: \(error)")
                sessionRunning = false
            }
            return
        }

        if ddcTest {
            if let display = DDCDisplay.external(), let red = display.read(DDCDisplay.redGain) {
                let target = red.current > 25 ? red.current - 25 : 0
                _ = display.write(DDCDisplay.redGain, value: target)
                print("       DDC red gain \(red.current) -> \(target); re-measuring white")
                startVerification(ambient: ambient, before: pre, restoreRed: red.current, resetGammaAfter: false)
            } else {
                print("       DDC unavailable")
                sessionRunning = false
            }
            return
        }

        guard applyToDisplay else {
            print("       would apply (use --apply)")
            DispatchQueue.main.async { self.patch.close() }
            sessionRunning = false
            return
        }

        do {
            try output.apply(gains)
            print("       applied — re-measuring white without moving the phone")
        } catch {
            print("       apply failed: \(error)")
            sessionRunning = false
            return
        }

        startVerification(ambient: ambient, before: pre, restoreRed: nil, resetGammaAfter: false)
    }

    /// Re-measure white in the same session so the phone cannot move.
    private func startVerification(ambient: XYZ, before: Double, restoreRed: UInt16?, resetGammaAfter: Bool) {
        samples.removeAll()
        DispatchQueue.main.async { self.patch.show(.white) }
        send(.progress(phase: "verify", fraction: 1))
        after(2.5) {
            self.send(.progress(phase: "done", fraction: 0))
            DispatchQueue.main.async { self.patch.close() }
            self.finishVerification(ambient: ambient, before: before, restoreRed: restoreRed, resetGammaAfter: resetGammaAfter)
        }
    }

    private func finishVerification(ambient: XYZ, before: Double, restoreRed: UInt16?, resetGammaAfter: Bool) {
        defer { sessionRunning = false }
        if let restoreRed, let display = DDCDisplay.external() {
            _ = display.write(DDCDisplay.redGain, value: restoreRed)
            print("       DDC red gain restored to \(restoreRed)")
        }
        guard let raw = mean(filtered(samples["verify"] ?? [])), raw.y > ambient.y else {
            print("verify: no samples")
            return
        }
        let after = subtract(raw, ambient)
        let target = Chromaticity.d65.xyz(luminance: after.y)
        let deltaE = ColorDifference.deltaE00(after, target)
        if resetGammaAfter {
            try? output.reset()
            print("       gamma table restored")
        }
        print(String(
            format: "VERIFY after apply: Y=%.2f  x=%.4f y=%.4f  CCT≈%.0f K  ΔE00 %.2f → %.2f",
            after.y,
            after.chromaticity?.x ?? 0,
            after.chromaticity?.y ?? 0,
            after.chromaticity?.correlatedColorTemperature() ?? 0,
            before,
            deltaE
        ))
    }

    private func send(_ message: CalibrationMessage, to connection: NWConnection) {
        guard let data = try? MessageFraming.encode(message) else { return }
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { print("send error: \(error)") }
        })
    }

    private func send(_ message: CalibrationMessage) {
        guard let connection = activeConnection else { return }
        send(message, to: connection)
    }

    private func after(_ seconds: Double, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block)
    }
}
#endif
