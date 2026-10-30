import D65Calibration
import D65Core
import D65Link
import D65Measurement
import Foundation

@MainActor final class NetworkProbe: CalibrationProbe {
    let identity: ProbeIdentity
    private let connection: any ProbeConnection
    private var request: MeasurementRequest?
    private var samples: [TaggedMeasurement] = []
    var connected = true
    init(identity: ProbeIdentity, connection: any ProbeConnection) { self.identity = identity; self.connection = connection }
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
            connection.send(data) { continuation.resume() }
        }
    }
    func send(_ message: CalibrationMessage) {
        guard let data = try? MessageFraming.encode(message) else { return }
        connection.send(data, completion: nil)
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
    private let listener: any ProbeListener
    private let platform: HostPlatform
    private let recordDirectory: URL
    private let revision: String
    private let engine = CalibrationEngine()
    private var connection: (any ProbeConnection)?
    private var lease = ProbeConnectionLease()
    private var buffer = Data()
    private var probe: NetworkProbe?
    private var task: Task<Void, Never>?
    private var presenter: (any HostOverlay)?
    private var placementID: UUID?
    private var placement = PlacementMonitor()
    private var alignment = DepthAlignmentFeedback()
    private var placementTimer: Timer?
    public var onEvent: ((SessionEvent) -> Void)?
    public var showsProgressOnPatches = true
    public private(set) var probeIdentity: ProbeIdentity?
    public var isRunning: Bool { task != nil }
    public var isPlacing: Bool { placementID != nil }

    public init(listener: any ProbeListener, platform: HostPlatform, recordDirectory: URL, softwareRevision: String) {
        self.listener = listener; self.platform = platform
        self.recordDirectory = recordDirectory; revision = softwareRevision
    }

    public func start() {
        listener.start(onReady: { [weak self] in self?.onEvent?(.listening) },
                       onFailure: { [weak self] text in self?.onEvent?(.listenerFailed(text)) },
                       onConnection: { [weak self] connection in self?.accept(connection) })
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
        placementID = id; placement = PlacementMonitor(); alignment.reset()
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

    public func endPlacement(closeOverlay: Bool = true, announceCancellation: Bool = false) {
        placementTimer?.invalidate(); placementTimer = nil
        if let id = placementID {
            probe?.send(.placementEnd(sessionID: id))
            if announceCancellation {
                probe?.send(.failure(code: LinkFailure.cancelled.rawValue, message: "Placement cancelled. No correction was applied."))
            }
        }
        placementID = nil; alignment.reset()
        if closeOverlay, task == nil { presenter?.close() }
    }

    private func report(_ input: PlacementReading) {
        var reading = input
        reading.alignment = alignment.visible(at: Date())
        if alignment.blocksColourSampling { reading.state = .moving; reading.steadyFraction = 0 }
        let hint = reading.alignment.map { $0.summary + "\n" + ($0.blocksColourSampling
            ? "Finish depth alignment on the iPhone before measuring"
            : Self.hint(for: reading.state)) } ?? Self.hint(for: reading.state)
        presenter?.setHint(hint)
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
        guard !alignment.blocksColourSampling else {
            onEvent?(.runFailed("Finish TrueDepth alignment on the iPhone before starting colour measurement."))
            return
        }
        guard let probe, let candidate = connection, task == nil else {
            onEvent?(.runFailed(probe == nil ? "No probe is connected." : "A session is already running.")); return
        }
        endPlacement(closeOverlay: false)
        let selected: any CalibrationDisplay
        do { selected = try platform.makeDisplay(displayID) }
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
            probe.send(ProbeCompletionMessage.make(for: record))
            probe.send(.sessionEnded(sessionID: record.id))
            onEvent?(.finished(record, saveError: saveError))
        }
    }

    public func cancelRun() { task?.cancel() }

    private func presenter(for displayID: UInt32) -> (any HostOverlay)? {
        if let presenter, presenter.displayID == displayID { return presenter }
        presenter?.close()
        guard let created = platform.makeOverlay(displayID) else { return nil }
        created.onCancel = { [weak self] in
            guard let self else { return }
            if self.task != nil { self.cancelRun() } else { self.endPlacement(announceCancellation: true) }
            self.onEvent?(.cancelRequested)
        }
        created.onStartNow = { [weak self] in self?.onEvent?(.startRequested) }
        presenter = created
        return created
    }

    // MARK: Connection

    private func accept(_ candidate: any ProbeConnection) {
        guard lease.claim(ObjectIdentifier(candidate)) else {
            refuse(candidate, code: .busy, message: "This Mac is already measuring with another iPhone.")
            return
        }
        connection = candidate; buffer.removeAll()
        candidate.start(onData: { [weak self, weak candidate] data in
            guard let self, let candidate else { return }
            self.receive(data, from: candidate)
        }, onClose: { [weak self, weak candidate] in
            guard let self, let candidate else { return }
            self.disconnect(candidate)
        })
        // Do not let a silent TCP connection reserve the sensor slot forever.
        Task { @MainActor [weak self, weak candidate] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, let candidate, self.connection === candidate, self.probe == nil else { return }
            self.disconnect(candidate)
        }
    }

    /// Tell the phone why before closing, so it never just sees a dropped connection.
    private func refuse(_ candidate: any ProbeConnection, code: LinkFailure, message: String) {
        onEvent?(.probeRejected(message))
        candidate.start(onData: { _ in }, onClose: {})
        if let data = try? MessageFraming.encode(.failure(code: code.rawValue, message: message)) {
            candidate.send(data) { candidate.cancel() }
        } else { candidate.cancel() }
        Task { try? await Task.sleep(for: .seconds(3)); candidate.cancel() }
    }

    private func receive(_ data: Data, from candidate: any ProbeConnection) {
        guard connection === candidate else { return }
        buffer.append(data)
        do {
            let messages = try MessageFraming.drain(&buffer)
            for message in messages { handle(message, from: candidate) }
        } catch {
            disconnect(candidate)
        }
    }

    private func disconnect(_ candidate: any ProbeConnection) {
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
    private func releaseProbe(_ candidate: any ProbeConnection) {
        probe = nil; probeIdentity = nil
        lease.release(ObjectIdentifier(candidate))
    }

    private func handle(_ message: CalibrationMessage, from candidate: any ProbeConnection) {
        switch message {
        case .helloV2(let model, let build, let version):
            guard probe == nil else { return }
            guard version == Link.protocolVersion else {
                let text = "D65 Probe speaks protocol \(version); this Mac needs \(Link.protocolVersion). Rebuild the probe."
                onEvent?(.probeRejected(text))
                if let data = try? MessageFraming.encode(.failure(code: LinkFailure.incompatible.rawValue, message: text)) {
                    candidate.send(data) { [weak self] in self?.disconnect(candidate) }
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
            report(placement.add(sample, stable: stable && !alignment.blocksColourSampling, at: Date()))
        case .depthAlignment(let sessionID, let reading):
            guard sessionID == placementID, task == nil else { return }
            alignment.receive(reading, at: Date())
            if reading.blocksColourSampling { placement = PlacementMonitor() }
            report(placement.tick(at: Date()))
        case .hello:
            let text = "D65 Probe is out of date (protocol 1). Rebuild it for protocol \(Link.protocolVersion)."
            onEvent?(.probeRejected(text))
            disconnect(candidate)
        default: break
        }
    }
}
