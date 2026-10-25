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
    private let brightnessTest: Bool
    private let effectTest: Bool
    private var output = MacDisplayOutput()
    private let normalizer = MeasurementNormalizer(minimumLux: 1)
    private var buffers: [ObjectIdentifier: Data] = [:]
    private var samples: [String: [MeasurementSample]] = [:]
    private var sessionRunning = false
    private var activeConnection: NWConnection?
    private let patch = PatchWindow()

    // Convergence state (one session, phone stationary).
    private var pass = 0
    private var cumulativeGains = RGBGains.identity
    private var previousDeltaE = Double.infinity
    private var bestDeltaE = Double.infinity
    private var bestGains = RGBGains.identity
    private var convergenceAmbient = XYZ.zero
    private let maximumPasses = 3
    private let targetDeltaE = 2.0

    init(port: UInt16, applyToDisplay: Bool, ddcTest: Bool = false, gammaTest: Bool = false, brightnessTest: Bool = false, effectTest: Bool = false) throws {
        self.applyToDisplay = applyToDisplay
        self.ddcTest = ddcTest
        self.gammaTest = gammaTest
        self.brightnessTest = brightnessTest
        self.effectTest = effectTest
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
        Patch(name: "grey20", color: NSColor(white: 0.20, alpha: 1)),
        Patch(name: "grey40", color: NSColor(white: 0.40, alpha: 1)),
        Patch(name: "grey60", color: NSColor(white: 0.60, alpha: 1)),
        Patch(name: "grey80", color: NSColor(white: 0.80, alpha: 1)),
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

        for name in ["white", "red", "green", "blue", "yellow", "cyan", "magenta",
                     "grey20", "grey40", "grey60", "grey80"] {
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

        // Fit the panel gamma from the grey ramp: Y_grey / Y_white = level^gamma.
        if let whiteValue = emitted["white"], whiteValue.y > 1 {
            let ramp: [(String, Double)] = [("grey20", 0.20), ("grey40", 0.40), ("grey60", 0.60), ("grey80", 0.80)]
            var sumXY = 0.0
            var sumXX = 0.0
            var points: [String] = []
            for (name, level) in ramp {
                guard let y = emitted[name]?.y, y > 0.5 else { continue }
                let x = log(level)
                let yValue = log(y / whiteValue.y)
                sumXY += x * yValue
                sumXX += x * x
                points.append(String(format: "%@ %.3f→%.3f", name, level, y / whiteValue.y))
            }
            if sumXX > 0 {
                let fitted = min(max(sumXY / sumXX, 1.6), 2.8)
                output.gamma = fitted
                print(String(format: "gamma fit %.2f from %@", fitted, points.joined(separator: " ")))
            } else {
                print("gamma fit: not enough grey samples, keeping \(output.gamma)")
            }
        }

        if effectTest {
            convergenceAmbient = ambient
            effectQueue = [("contrast", 0x12, 80), ("vcp6C", 0x6C, 100)]
            print("effect test: \(effectQueue.count) candidates")
            runNextEffectTest()
            return
        }

        if brightnessTest {
            convergenceAmbient = ambient
            let baseline = white.y
            guard let display = DDCDisplay.external(), let value = display.read(DDCDisplay.luminance) else {
                print("       DDC unavailable")
                sessionRunning = false
                return
            }
            print(String(format: "brightness test: baseline Y=%.2f, 0x10=%d -> 100", baseline, value.current))
            _ = display.write(DDCDisplay.luminance, value: 100)
            measureWhite { at100 in
                print(String(format: "  at 0x10=100: Y=%.2f (%+.1f%%)", at100.y, (at100.y / baseline - 1) * 100))
                _ = display.write(DDCDisplay.luminance, value: value.current)
                self.measureWhite { restored in
                    print(String(format: "  restored to %d: Y=%.2f (%+.1f%%)", value.current, restored.y, (restored.y / baseline - 1) * 100))
                    print(restored.y / baseline > 0.9 ? "  brightness restore looks safe" : "  WARNING: luminance did not return — check the monitor OSD")
                    DispatchQueue.main.async { self.patch.close() }
                    self.sessionRunning = false
                }
            }
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
            print(String(format: "       pass 1 applied R=%.4f G=%.4f B=%.4f", gains.r, gains.g, gains.b))
        } catch {
            print("       apply failed: \(error)")
            sessionRunning = false
            return
        }

        convergenceAmbient = ambient
        cumulativeGains = gains
        previousDeltaE = pre
        pass = 1
        requestConvergenceMeasurement()
    }

    private var effectQueue: [(name: String, vcp: UInt8, test: UInt16)] = []

    private func runNextEffectTest() {
        guard !effectQueue.isEmpty else {
            print("effect test: done")
            DispatchQueue.main.async { self.patch.close() }
            sessionRunning = false
            return
        }
        let item = effectQueue.removeFirst()
        guard let display = DDCDisplay.external(), let original = display.read(item.vcp) else {
            print("effect test: \(item.name) unavailable")
            runNextEffectTest()
            return
        }

        measureWhite { baseline in
            _ = display.write(item.vcp, value: item.test)
            let readback = display.read(item.vcp)?.current ?? 0
            self.measureWhite { after in
                _ = display.write(item.vcp, value: original.current)
                self.measureWhite { restored in
                    let deltaY = (after.y / baseline.y - 1) * 100
                    let baselineXY = baseline.chromaticity
                    let afterXY = after.chromaticity
                    let deltaXY = hypot((afterXY?.x ?? 0) - (baselineXY?.x ?? 0),
                                        (afterXY?.y ?? 0) - (baselineXY?.y ?? 0))
                    let effective = abs(deltaY) > 5 || deltaXY > 0.002
                    print(String(
                        format: "effect %@ 0x%02X: %d->%d  ΔY=%+.1f%%  Δxy=%.4f  readback=%d  → %@",
                        item.name, item.vcp, original.current, item.test,
                        deltaY, deltaXY, readback, effective ? "EFFECTIVE" : "no measurable effect"
                    ))
                    if abs(restored.y / baseline.y - 1) > 0.05 {
                        print("  WARNING: restore drifted \(String(format: "%.1f", (restored.y / baseline.y - 1) * 100))%")
                    }
                    self.runNextEffectTest()
                }
            }
        }
    }

    private func measureWhite(then completion: @escaping (XYZ) -> Void) {
        samples.removeAll()
        DispatchQueue.main.async { self.patch.show(.white) }
        send(.progress(phase: "verify", fraction: 1))
        after(2.5) {
            self.send(.progress(phase: "done", fraction: 0))
            guard let raw = self.mean(self.filtered(self.samples["verify"] ?? [])), raw.y > 1 else {
                print("       white measurement failed")
                DispatchQueue.main.async { self.patch.close() }
                self.sessionRunning = false
                return
            }
            completion(self.subtract(raw, self.convergenceAmbient))
        }
    }

    // MARK: - Convergence

    private func requestConvergenceMeasurement() {
        samples.removeAll()
        DispatchQueue.main.async { self.patch.show(.white) }
        send(.progress(phase: "verify", fraction: 1))
        after(2.5) {
            self.send(.progress(phase: "done", fraction: 0))
            self.finishConvergenceMeasurement()
        }
    }

    private func finishConvergenceMeasurement() {
        guard let raw = mean(filtered(samples["verify"] ?? [])), raw.y > convergenceAmbient.y else {
            print("       pass \(pass): no samples")
            endConvergence()
            return
        }
        let measured = subtract(raw, convergenceAmbient)
        let target = Chromaticity.d65.xyz(luminance: measured.y)
        let deltaE = ColorDifference.deltaE00(measured, target)
        let cct = measured.chromaticity?.correlatedColorTemperature() ?? 0
        print(String(format: "       pass %d: CCT≈%.0f K  ΔE00 %.2f  (previous %.2f)", pass, cct, deltaE, previousDeltaE))

        if deltaE < bestDeltaE {
            bestDeltaE = deltaE
            bestGains = cumulativeGains
        }
        let improved = deltaE < previousDeltaE - 0.3
        previousDeltaE = deltaE
        if deltaE <= targetDeltaE || !improved || pass >= maximumPasses {
            endConvergence()
            return
        }

        let residual = WhitePointSolver.gains(measuredWhite: measured)
        do {
            try output.apply(residual)
        } catch {
            print("       pass \(pass + 1) apply failed: \(error)")
            endConvergence()
            return
        }

        cumulativeGains = RGBGains(
            r: cumulativeGains.r * residual.r,
            g: cumulativeGains.g * residual.g,
            b: cumulativeGains.b * residual.b,
            alpha: 1
        )
        previousDeltaE = deltaE
        pass += 1
        print(String(format: "       pass %d applied residual R=%.4f G=%.4f B=%.4f",
                     pass, residual.r, residual.g, residual.b))
        requestConvergenceMeasurement()
    }

    private func endConvergence() {
        defer { sessionRunning = false }
        try? output.reset()
        DispatchQueue.main.async { self.patch.close() }

        // Report the best pass, not necessarily the last one: the final
        // measurement can drift within noise.
        let useBest = bestDeltaE + 0.2 < previousDeltaE
        let gains = useBest ? bestGains : cumulativeGains
        let deltaE = useBest ? bestDeltaE : previousDeltaE
        print(String(format: "CONVERGED after %d pass(es): gains R=%.4f G=%.4f B=%.4f  best ΔE00 %.2f%@  (gamma restored)",
                     pass, gains.r, gains.g, gains.b, deltaE, useBest ? ", earlier pass" : ""))
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
