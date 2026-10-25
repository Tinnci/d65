#if os(macOS)
import AppKit
import D65Calibration
import D65Core
import D65Link
import D65Measurement
import Foundation
import Network

@MainActor final class NetworkProbe: CalibrationProbe {
    let identity: ProbeIdentity
    private let connection: NWConnection
    private var request: MeasurementRequest?
    private var samples: [TaggedMeasurement] = []
    var connected = true
    init(identity: ProbeIdentity, connection: NWConnection) { self.identity = identity; self.connection = connection }
    func start(_ request: MeasurementRequest) throws {
        guard connected else { throw CalibrationError.disconnected }
        self.request = request; samples.removeAll()
        send(.measurementRequest(request))
    }
    func append(sessionID: UUID, patchID: UUID, sample: MeasurementSample) {
        guard connected, let request, request.sessionID == sessionID, request.patchID == patchID,
              samples.count < 256 else { return }
        samples.append(TaggedMeasurement(sessionID: sessionID, patchID: patchID, sample: sample, receivedAt: Date()))
    }
    func finish(_ request: MeasurementRequest) throws -> [TaggedMeasurement] {
        guard connected else { throw CalibrationError.disconnected }
        guard self.request == request else { throw CalibrationError.invalidMeasurement }
        let result = samples
        stop()
        return result
    }
    @discardableResult func stop() -> [TaggedMeasurement] {
        let pending = samples
        if let request { send(.measurementEnd(sessionID: request.sessionID, patchID: request.patchID)) }
        request = nil; samples.removeAll()
        return pending
    }
    func sendFinal(_ message: CalibrationMessage) async {
        guard connected, let data = try? MessageFraming.encode(message) else { return }
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
    }
    func send(_ message: CalibrationMessage) {
        guard let data = try? MessageFraming.encode(message) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}

public enum SessionEvent {
    case listening
    case listenerFailed(String)
    case probeConnected(ProbeIdentity)
    case probeDisconnected
    /// A probe was refused; the reason has also been sent to the phone.
    case probeRejected(String)
    case placement(PlacementReading)
    /// Space on the overlay, or Esc. The client decides what each means in its current step.
    case startRequested
    case cancelRequested
    case progress(CalibrationProgress)
    case finished(ExperimentRecord, saveError: String?)
    /// The run could not start (display gone, engine busy). Nothing was changed.
    case runFailed(String)
}

/// Network host for one probe at a time. The connection outlives a session so a retry needs no
/// trip back to the phone; the engine only runs when the client asks, after placement.
@MainActor public final class CalibrationService {
    private let listener: NWListener
    private let recordDirectory: URL
    private let revision: String
    private let engine = CalibrationEngine()
    private var connection: NWConnection?
    private var lease = ProbeConnectionLease()
    private var buffer = Data()
    private var probe: NetworkProbe?
    private var task: Task<Void, Never>?
    private var presenter: ScreenPatchPresenter?
    private var placementID: UUID?
    private var placement = PlacementMonitor()
    private var placementTimer: Timer?
    public var onEvent: ((SessionEvent) -> Void)?
    public var showsProgressOnPatches = true
    public private(set) var probeIdentity: ProbeIdentity?
    public var isRunning: Bool { task != nil }
    public var isPlacing: Bool { placementID != nil }

    public init(port: UInt16 = 50515, recordDirectory: URL, softwareRevision: String) throws {
        guard let port = NWEndpoint.Port(rawValue: port) else { throw CalibrationError.invalidConfiguration }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        listener = try NWListener(using: parameters, on: port)
        listener.service = NWListener.Service(name: "D65", type: Link.serviceType)
        self.recordDirectory = recordDirectory; revision = softwareRevision
    }

    public func start() {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.onEvent?(.listening)
                case .failed(let error):
                    let text: String
                    if case .posix(let code) = error, code == .EADDRINUSE {
                        text = "Port \(self?.listener.port?.rawValue ?? 50515) is in use, possibly by d65 serve. Quit it and try again."
                    } else { text = "D65 can’t listen on the local network: \(error)" }
                    self?.onEvent?(.listenerFailed(text))
                default: break
                }
            }
        }
        listener.start(queue: .main)
    }

    /// Cancels any run, waits for the engine's restoration, then releases the probe.
    public func stop() async {
        endPlacement()
        listener.cancel()
        task?.cancel()
        await task?.value
        if let probe { await probe.sendFinal(.sessionEnded(sessionID: UUID())) }
        connection?.cancel()
        probe?.connected = false
        connection = nil; probe = nil; probeIdentity = nil
        presenter?.close(); presenter = nil
    }

    // MARK: Placement

    /// Show the placement patch on `displayID` and stream preview readings until a run starts.
    public func beginPlacement(displayID: UInt32) {
        guard let probe, task == nil, let presenter = presenter(for: displayID) else { return }
        let id = UUID()
        placementID = id; placement = PlacementMonitor()
        presenter.showPlacement(probeModel: probe.identity.model, hint: Self.hint(for: .waiting))
        probe.send(.placementRequest(sessionID: id))
        placementTimer?.invalidate()
        placementTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.placementID != nil else { return }
                self.report(self.placement.tick(at: Date()))
            }
        }
        onEvent?(.placement(PlacementReading(state: .waiting)))
    }

    public func endPlacement(closeOverlay: Bool = true) {
        placementTimer?.invalidate(); placementTimer = nil
        if let id = placementID { probe?.send(.placementEnd(sessionID: id)) }
        placementID = nil
        if closeOverlay, task == nil { presenter?.close() }
    }

    private func report(_ reading: PlacementReading) {
        presenter?.setHint(Self.hint(for: reading.state))
        onEvent?(.placement(reading))
    }

    static func hint(for state: PlacementState) -> String {
        switch state {
        case .waiting: return "Press the front of the iPhone flat against the outline"
        case .tooDark: return "Too dark — the sensor must sit inside the outline"
        case .moving: return "Hold the phone still"
        case .settling: return "Hold still…"
        case .settled: return "Starting"
        }
    }

    // MARK: Runs

    public func run(configuration: CalibrationConfiguration, displayID: UInt32) {
        guard let probe, let candidate = connection, task == nil else {
            onEvent?(.runFailed(probe == nil ? "No probe is connected." : "A session is already running.")); return
        }
        endPlacement(closeOverlay: false)
        let selected: SelectedDisplay
        do { selected = try SelectedDisplay(displayID: displayID) }
        catch { presenter?.close(); onEvent?(.runFailed("The display is no longer available.")); return }
        guard let presenter = presenter(for: displayID) else { onEvent?(.runFailed("The display is no longer available.")); return }
        presenter.showsProgress = showsProgressOnPatches

        engine.onProgress = { [weak self, weak presenter] progress in
            self?.onEvent?(.progress(progress))
            switch progress {
            case .patch(let index, let total, let patch):
                presenter?.setProgress("Measuring \(patch.name) · \(index + 1) of \(total)", fraction: Double(index) / Double(total))
                probe.send(.progress(phase: patch.name, fraction: Double(index) / Double(total)))
            case .verifying(let pass):
                presenter?.setProgress("Verifying white · pass \(pass)", fraction: nil)
                probe.send(.progress(phase: "pass \(pass)", fraction: 1))
            default: break
            }
        }

        task = Task { @MainActor [self] in
            defer { task = nil; if connection == nil { releaseProbe(candidate) } }
            var finished: ExperimentRecord?
            var saveError: String?
            do {
                finished = try await engine.run(configuration: configuration, display: selected, probe: probe,
                    presenter: presenter, clock: SystemCalibrationClock(),
                    recorder: JSONExperimentRecorder(directory: recordDirectory), softwareRevision: revision)
            } catch let error as RecordSaveError {
                finished = error.record; saveError = error.underlying
            } catch {
                presenter.close()
                onEvent?(.runFailed(String(describing: error)))
                return
            }
            guard let record = finished else { return }
            if let gains = record.bestGains, let before = record.baselineDeltaE, let after = record.bestDeltaE {
                probe.send(.result(gains: gains, preDeltaE: before, postDeltaE: after,
                                   verdict: SessionSummary.probeVerdict(for: record)))
            } else {
                probe.send(.failure(code: LinkFailure.session.rawValue, message: SessionSummary(record: record).title))
            }
            probe.send(.sessionEnded(sessionID: record.id))
            onEvent?(.finished(record, saveError: saveError))
        }
    }

    public func cancelRun() { task?.cancel() }

    private func presenter(for displayID: UInt32) -> ScreenPatchPresenter? {
        if let presenter, presenter.displayID == displayID { return presenter }
        presenter?.close()
        guard let screen = NSScreen.forDisplay(displayID) else { return nil }
        let created = ScreenPatchPresenter(screen: screen, displayID: displayID)
        created.onCancel = { [weak self] in
            guard let self else { return }
            if self.task != nil { self.cancelRun() } else { self.endPlacement() }
            self.onEvent?(.cancelRequested)
        }
        created.onStartNow = { [weak self] in self?.onEvent?(.startRequested) }
        presenter = created
        return created
    }

    // MARK: Connection

    private func accept(_ candidate: NWConnection) {
        guard lease.claim(ObjectIdentifier(candidate)) else {
            refuse(candidate, code: .busy, message: "This Mac is already measuring with another iPhone.")
            return
        }
        connection = candidate; buffer.removeAll()
        candidate.stateUpdateHandler = { [weak self, weak candidate] state in
            Task { @MainActor in
                guard let self, let candidate, self.connection === candidate else { return }
                switch state {
                case .failed, .cancelled: self.disconnect(candidate)
                default: break
                }
            }
        }
        candidate.start(queue: .main)
        receive(candidate)
        // Do not let a silent TCP connection reserve the sensor slot forever.
        Task { @MainActor [weak self, weak candidate] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, let candidate, self.connection === candidate, self.probe == nil else { return }
            self.disconnect(candidate)
        }
    }

    /// Tell the phone why before closing, so it never just sees a dropped connection.
    private func refuse(_ candidate: NWConnection, code: LinkFailure, message: String) {
        onEvent?(.probeRejected(message))
        let send = { (connection: NWConnection) in
            guard let data = try? MessageFraming.encode(.failure(code: code.rawValue, message: message)) else { connection.cancel(); return }
            connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
        }
        if candidate.state == .ready { send(candidate); return }
        candidate.stateUpdateHandler = { state in
            switch state {
            case .ready: send(candidate)
            case .failed, .cancelled: break
            default: break
            }
        }
        candidate.start(queue: .main)
        Task { try? await Task.sleep(for: .seconds(3)); candidate.cancel() }
    }

    private func receive(_ candidate: NWConnection) {
        candidate.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connection === candidate else { return }
                if let data {
                    self.buffer.append(data)
                    do {
                        let messages = try MessageFraming.drain(&self.buffer)
                        for message in messages { self.handle(message, from: candidate) }
                    } catch {
                        self.disconnect(candidate)
                        return
                    }
                }
                if complete || error != nil { self.disconnect(candidate) }
                else { self.receive(candidate) }
            }
        }
    }

    private func disconnect(_ candidate: NWConnection) {
        guard connection === candidate else { return }
        let hadProbe = probe != nil
        endPlacement()
        candidate.cancel()
        probe?.connected = false
        task?.cancel()
        connection = nil
        buffer.removeAll()
        if task == nil { releaseProbe(candidate) }
        if hadProbe { onEvent?(.probeDisconnected) }
    }

    /// The lease is held until restoration completes, even when the TCP connection has gone.
    private func releaseProbe(_ candidate: NWConnection) {
        probe = nil; probeIdentity = nil
        lease.release(ObjectIdentifier(candidate))
    }

    private func handle(_ message: CalibrationMessage, from candidate: NWConnection) {
        switch message {
        case .helloV2(let model, let build, let version):
            guard probe == nil else { return }
            guard version == Link.protocolVersion else {
                let text = "D65 Probe speaks protocol \(version); this Mac needs \(Link.protocolVersion). Rebuild the probe."
                onEvent?(.probeRejected(text))
                if let data = try? MessageFraming.encode(.failure(code: LinkFailure.incompatible.rawValue, message: text)) {
                    candidate.send(content: data, completion: .contentProcessed { [weak self] _ in
                        Task { @MainActor in self?.disconnect(candidate) }
                    })
                } else { disconnect(candidate) }
                return
            }
            let identity = ProbeIdentity(model: model, build: build)
            probe = NetworkProbe(identity: identity, connection: candidate)
            probeIdentity = identity
            onEvent?(.probeConnected(identity))
        case .taggedSample(let sessionID, let patchID, let sample):
            probe?.append(sessionID: sessionID, patchID: patchID, sample: sample)
        case .previewSample(let sessionID, let sample, let stable):
            guard sessionID == placementID else { return }
            report(placement.add(sample, stable: stable, at: Date()))
        case .hello:
            let text = "D65 Probe is out of date (protocol 1). Rebuild it for protocol \(Link.protocolVersion)."
            onEvent?(.probeRejected(text))
            disconnect(candidate)
        default: break
        }
    }
}
#endif
