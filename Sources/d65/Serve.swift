#if os(macOS)
import D65Core
import D65Display
import D65Link
import D65Measurement
import Foundation
import Network

/// Bonjour service that receives measurements from the probe and solves gains.
final class CalibrationServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "d65.serve")
    private let applyToDisplay: Bool
    private let output = MacDisplayOutput()
    private let normalizer = MeasurementNormalizer(minimumLux: 8)
    private var buffers: [ObjectIdentifier: Data] = [:]
    private var samples: [MeasurementSample] = []
    private var lastSolve = Date.distantPast

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
            for message in messages {
                handle(message, connection: connection)
            }
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

        case .sample(let sample):
            samples.append(sample)
            if samples.count > 40 { samples.removeFirst(samples.count - 40) }
            if let cct = sample.cct {
                print(String(format: "sample  lux=%6.1f  X=%7.2f Y=%7.2f Z=%7.2f  CCT=%4.0f K",
                             sample.lux, sample.xyz.x, sample.xyz.y, sample.xyz.z, cct))
            }
            solveIfPossible(connection: connection)

        case .ready, .progress, .result, .failure, .sensorCalibration:
            break
        }
    }

    private func solveIfPossible(connection: NWConnection) {
        guard samples.count >= 8, Date().timeIntervalSince(lastSolve) > 2 else { return }
        guard let mean = try? normalizer.robustMean(samples, minimumCount: 8) else { return }

        let gains = WhitePointSolver.gains(measuredWhite: mean.xyz)
        let corrected = WhitePointSolver.predictedWhite(after: gains, measuredWhite: mean.xyz)
        let deltaE = ColorDifference.deltaE00(mean.xyz, corrected)

        lastSolve = Date()
        samples.removeAll(keepingCapacity: true)

        print(String(format: "SOLVE  gains R=%.4f G=%.4f B=%.4f   ΔE00 %.2f → %.2f",
                     gains.r, gains.g, gains.b,
                     ColorDifference.deltaE00(mean.xyz, Chromaticity.d65.xyz(luminance: mean.xyz.y)),
                     ColorDifference.deltaE00(corrected, Chromaticity.d65.xyz(luminance: mean.xyz.y))))

        if applyToDisplay {
            do {
                try output.apply(gains)
                print("       applied to display (held while this process runs)")
            } catch {
                print("       apply failed: \(error)")
            }
        }

        send(.result(gains: gains,
                     preDeltaE: deltaE,
                     postDeltaE: 0,
                     verdict: .improved),
             to: connection)
    }

    private func send(_ message: CalibrationMessage, to connection: NWConnection) {
        guard let data = try? MessageFraming.encode(message) else { return }
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { print("send error: \(error)") }
        })
    }
}
#endif
