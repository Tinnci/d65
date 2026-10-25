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
    private let output = MacDisplayOutput()
    private let normalizer = MeasurementNormalizer(minimumLux: 1)
    private var buffers: [ObjectIdentifier: Data] = [:]
    private var samples: [String: [MeasurementSample]] = [:]
    private var sessionRunning = false
    private var activeConnection: NWConnection?
    private let patch = PatchWindow()

    init(port: UInt16, applyToDisplay: Bool) throws {
        self.applyToDisplay = applyToDisplay
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

    private func startSession() {
        guard !sessionRunning else { return }
        sessionRunning = true
        samples.removeAll()
        print("session: black patch")
        DispatchQueue.main.async { self.patch.show(.black) }
        send(.progress(phase: "black", fraction: 0))

        after(2.5) {
            self.send(.progress(phase: "done", fraction: 0))
            print("session: white patch")
            DispatchQueue.main.async { self.patch.show(.white) }
            self.send(.progress(phase: "white", fraction: 0))
        }

        after(5.5) {
            self.send(.progress(phase: "done", fraction: 0))
            DispatchQueue.main.async { self.patch.close() }
            self.finishSession()
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

    /// Drop readings whose luminance is far from the median, then average.
    private func filtered(_ list: [MeasurementSample]) -> [MeasurementSample] {
        guard list.count >= 3 else { return list }
        let sorted = list.map(\.xyz.y).sorted()
        let median = sorted[sorted.count / 2]
        let tolerance = max(0.5, median * 0.35)
        return list.filter { abs($0.xyz.y - median) <= tolerance }
    }

    private func finishSession() {
        defer { sessionRunning = false }
        activeConnection = nil

        let blackSamples = samples["black"] ?? []
        let whiteSamples = samples["white"] ?? []
        print("session: black=\(blackSamples.count) white=\(whiteSamples.count) samples")

        guard let black = mean(filtered(blackSamples)), let white = mean(filtered(whiteSamples)) else {
            print("session: no samples — is the probe pointed at the screen?")
            return
        }

        print(String(format: "       black Y=%.2f   white Y=%.2f", black.y, white.y))

        let emitted = XYZ(
            x: max(white.x - black.x, 0),
            y: max(white.y - black.y, 0),
            z: max(white.z - black.z, 0)
        )
        guard emitted.y > 1 else {
            print("session: emitted luminance too low (\(emitted.y)) — raise display brightness or bring the phone closer")
            return
        }

        let gains = WhitePointSolver.gains(measuredWhite: emitted)
        let target = Chromaticity.d65.xyz(luminance: emitted.y)
        let predicted = WhitePointSolver.predictedWhite(after: gains, measuredWhite: emitted)
        let pre = ColorDifference.deltaE00(emitted, target)
        let post = ColorDifference.deltaE00(predicted, target)
        let verdict = QualityGate().verdict(
            preDeltaE: pre,
            postDeltaE: post,
            luminanceScale: gains.luminanceScale
        )

        let cct = emitted.chromaticity?.correlatedColorTemperature() ?? 0
        print(String(format: "       emitted X=%.2f Y=%.2f Z=%.2f", emitted.x, emitted.y, emitted.z))
        if let chroma = emitted.chromaticity {
            print(String(format: "       chromaticity x=%.4f y=%.4f", chroma.x, chroma.y))
        }
        print(String(format: "PATCH  emitted Y=%.2f  CCT≈%.0f K", emitted.y, cct))
        print(String(format: "       gains R=%.4f G=%.4f B=%.4f  ΔE00 %.2f → %.2f  verdict=%@",
                     gains.r, gains.g, gains.b, pre, post, verdict.rawValue))

        switch verdict {
        case .improved:
            if applyToDisplay {
                do {
                    try output.apply(gains)
                    print("       applied (held while this process runs)")
                } catch {
                    print("       apply failed: \(error)")
                }
            } else {
                print("       would apply (use --apply)")
            }
        case .confirmed:
            print("       display already within tolerance — nothing applied")
        case .rejected:
            print("       rejected by quality gate — nothing applied")
        }
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
