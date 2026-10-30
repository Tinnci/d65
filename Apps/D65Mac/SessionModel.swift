import AppKit
import D65Calibration
import D65Core
import D65MacRuntime
import SwiftUI

/// One calibration session: Prepare → Connect → Place → Measure → Review.
/// Reduces `SessionEvent`s into what the session window shows; the engine record stays the truth.
@MainActor final class SessionModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case prepare, connect, place, measure, review
        var title: String { ["Prepare", "Connect", "Place", "Measure", "Review"][rawValue] }
    }

    @Published private(set) var step: Step = .prepare
    @Published private(set) var displays: [DisplayInfo] = []
    @Published var selectedID: UInt32?
    @Published var measureOnly = false
    /// Remembered between sessions; CIEDE2000 unless the user picks otherwise.
    @Published var metric: WhiteErrorMetric = WhiteErrorMetric(rawValue: UserDefaults.standard.string(forKey: "metric") ?? "") ?? .ciede2000 {
        didSet { UserDefaults.standard.set(metric.rawValue, forKey: "metric") }
    }
    @Published private(set) var monitorSettings: [String: UInt16] = [:]
    @Published private(set) var probe: ProbeIdentity?
    @Published private(set) var notice: String?
    @Published private(set) var waitingSince: Date?
    @Published private(set) var placement = PlacementReading(state: .waiting)
    @Published private(set) var patchIndex = 0
    @Published private(set) var phase = ""
    @Published private(set) var passes: [CorrectionPass] = []
    @Published private(set) var verifyingPass: Int?
    @Published private(set) var record: ExperimentRecord?
    @Published private(set) var summary: SessionSummary?
    @Published private(set) var saveError: String?
    @Published var comparing = false { didSet { compareChanged() } }

    let agent: AgentModel
    private var service: CalibrationService?
    private var autoStartArmed = true
    private var calibrationStart: Task<Void, Never>?
    var onClose: (() -> Void)?

    init(agent: AgentModel) { self.agent = agent; reloadDisplays() }

    #if DEBUG
    /// Debug showcase only: put the window in a given step without a probe or a running engine.
    func showcase(step: Step, probe: ProbeIdentity? = nil, placement: PlacementReading? = nil,
                  patchIndex: Int = 0, record: ExperimentRecord? = nil) {
        self.step = step; self.probe = probe
        if let placement { self.placement = placement }
        self.patchIndex = patchIndex; phase = CalibrationPatch.sequence[min(patchIndex, patchCount - 1)].name
        self.record = record; summary = record.map(SessionSummary.init)
    }
    #endif

    var selected: DisplayInfo? { displays.first { $0.id == selectedID } }

    /// Who should see the result as D65. Anything but CIE 1931 2° needs the display's primary spectra.
    @Published var viewer: Observer = Observer(rawValue: UserDefaults.standard.string(forKey: "viewer") ?? "") ?? .cie1931TwoDegree {
        didSet { UserDefaults.standard.set(viewer.rawValue, forKey: "viewer") }
    }
    @Published private(set) var spectraError: String?
    var spectra: PrimarySpectra? { selected.flatMap { agent.spectraStore.spectra(for: $0.identity) } }

    /// The white this session will steer to, or why it can't.
    var targetConfiguration: CalibrationConfiguration {
        var configuration = CalibrationConfiguration(mode: measureOnly ? .measureOnly : .calibrate)
        configuration.metric = metric
        if viewer != configuration.observer {
            configuration.viewerObserver = viewer
            configuration.primarySpectra = spectra
        }
        return configuration
    }
    var whiteTarget: Chromaticity? { try? targetConfiguration.whiteTarget() }

    func importSpectra(from url: URL) {
        guard let display = selected else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let spectra = try PrimarySpectra(csv: text, source: url.lastPathComponent)
            _ = try ObserverTransform.primaryMatrix(spectra, observer: .cie1931TwoDegree)
            try agent.spectraStore.save(spectra, for: display.identity)
            spectraError = nil
            Log.store.notice("imported primary spectra for \(display.name, privacy: .public)")
        } catch let error as PrimarySpectra.ImportError {
            spectraError = error.description
        } catch is ObserverTransform.TransformError {
            spectraError = "The three primaries are too similar to tell apart; check the file's columns."
        } catch {
            spectraError = "Couldn’t read \(url.lastPathComponent): \(error.localizedDescription)"
        }
        if let spectraError { Log.store.error("primary spectra import failed: \(spectraError, privacy: .public)") }
        objectWillChange.send()
    }

    func removeSpectra() {
        guard let display = selected else { return }
        try? agent.spectraStore.remove(for: display.identity)
        objectWillChange.send()
    }
    var patchCount: Int { CalibrationPatch.sequence.count }
    var secondsRemaining: Int {
        let config = CalibrationConfiguration(mode: .calibrate)
        let per = config.settlingSeconds + config.samplingSeconds
        return Int((Double(patchCount - patchIndex) * per + (measureOnly ? 0 : 2 * per)).rounded())
    }

    func reloadDisplays() {
        displays = DisplayDirectory.online().sorted { !$0.isBuiltin && $1.isBuiltin }
        if selected == nil { selectedID = DisplayDirectory.preferred(in: displays)?.id }
        readMonitorSettings()
    }

    func readMonitorSettings() {
        guard let id = selectedID else { monitorSettings = [:]; return }
        Task.detached(priority: .userInitiated) {
            let settings = DisplayDirectory.monitorSettings(displayID: id)
            await MainActor.run { if self.selectedID == id { self.monitorSettings = settings } }
        }
    }

    // MARK: Steps

    func continueFromPrepare() {
        notice = nil
        if service == nil {
            do {
                let revision = Bundle.main.infoDictionary?["D65SoftwareRevision"] as? String ?? "unknown-app-build"
                let service = try CalibrationService(recordDirectory: agent.recordDirectory, softwareRevision: revision)
                service.onEvent = { [weak self] in self?.handle($0) }
                service.start()
                self.service = service
                Log.session.info("calibration service starting (revision \(revision, privacy: .public))")
            } catch {
                notice = "D65 can’t listen on the local network: \(error.localizedDescription)"
                Log.network.error("couldn’t create the listener: \(String(describing: error), privacy: .public)")
                return
            }
        }
        service?.showsProgressOnPatches = agent.showsProgressOnPatches
        if probe != nil { enterPlacement() } else { step = .connect; waitingSince = Date() }
    }

    func startNow() {
        guard placement.alignment?.blocksColourSampling != true else {
            notice = "Finish TrueDepth alignment on the iPhone first."
            return
        }
        guard step == .place, let display = selected, let service else { return }
        patchIndex = 0; passes = []; verifyingPass = nil; record = nil; summary = nil; saveError = nil
        phase = CalibrationPatch.sequence[0].name
        step = .measure
        let configuration = targetConfiguration
        Log.session.notice("""
            session starting on \(display.name, privacy: .public): \(configuration.mode.rawValue, privacy: .public), \
            \(configuration.metric.label, privacy: .public), viewer \(self.viewer.rawValue, privacy: .public)
            """)
        calibrationStart = Task {
            await agent.prepareForCalibration(identity: display.identity)
            guard !Task.isCancelled, step == .measure else { return }
            calibrationStart = nil
            service.run(configuration: targetConfiguration, displayID: display.id)
        }
    }

    func back() {
        switch step {
        case .connect: step = .prepare
        case .place: service?.endPlacement(announceCancellation: true); step = .prepare
        case .measure:
            Log.session.notice("session cancelled from the window")
            if let calibrationStart {
                calibrationStart.cancel()
                self.calibrationStart = nil
                agent.finishCalibration()
                step = .place
            } else { service?.cancelRun() }
        default: break
        }
    }

    func tryAgain() {
        agent.finishCalibration()
        if probe != nil { enterPlacement() } else { step = .connect; waitingSince = Date() }
    }

    func keep() {
        if let record { agent.keep(record) }
        close()
    }

    func discard() { agent.finishCalibration(); close() }

    /// Window closing: cancel a run (the engine restores), drop any preview, release the probe.
    func close() {
        Task { await shutdown() }
        onClose?()
    }

    func shutdown() async {
        calibrationStart?.cancel()
        calibrationStart = nil
        let service = self.service
        self.service = nil
        if service != nil { Log.session.info("calibration service stopping") }
        comparing = false
        step = .prepare; probe = nil; record = nil; summary = nil; notice = nil
        await service?.stop()
        // After the engine has restored: drop an undecided preview, give the display back its stored correction.
        agent.finishCalibration()
    }

    private func enterPlacement() {
        guard let display = selected else { step = .prepare; return }
        autoStartArmed = true
        placement = PlacementReading(state: .waiting)
        step = .place
        service?.beginPlacement(displayID: display.id)
        SessionWindowPlacement.moveAway(from: display.id)
    }

    private func compareChanged() {
        guard step == .review, let identity = record?.display.identity else { return }
        agent.compareDuringReview(original: comparing, identity: identity)
    }

    // MARK: Events

    private func handle(_ event: SessionEvent) {
        log(event)
        switch event {
        case .listening:
            break
        case .listenerFailed(let text):
            notice = text
        case .probeConnected(let identity):
            probe = identity; notice = nil
            if step == .connect { enterPlacement() }
        case .probeDisconnected:
            probe = nil
            if step == .place { step = .connect; waitingSince = Date() }
            if step == .connect { waitingSince = Date() }
        case .probeRejected(let text):
            notice = text
        case .placement(let reading):
            placement = reading
            if reading.state == .settled, autoStartArmed, step == .place {
                autoStartArmed = false
                startNow()
            }
        case .startRequested:
            if step == .place { startNow() }
        case .cancelRequested:
            if step == .place { step = .prepare; NSApp.activate(ignoringOtherApps: true) }
        case .progress(let progress):
            switch progress {
            case .patch(let index, _, let patch):
                patchIndex = index; phase = patch.name
                Accessibility.announce("Measuring \(patch.name), \(index + 1) of \(patchCount)")
            case .applying: patchIndex = patchCount
            case .verifying(let pass): verifyingPass = pass
            case .passMeasured(let pass): passes.append(pass); verifyingPass = nil
            case .restoring: break
            }
        case .finished(let record, let saveError):
            self.record = record; self.saveError = saveError
            let summary = SessionSummary(record: record)
            self.summary = summary
            if summary.canKeep { agent.preview(record) } else { agent.finishCalibration() }
            step = .review
            NSApp.activate(ignoringOtherApps: true)
            Accessibility.announce(summary.title)
        case .runFailed(let text):
            agent.finishCalibration()
            notice = text
            step = probe == nil ? .connect : .prepare
        }
    }
}

extension SessionModel {
    /// One log line per session event, at the level its consequence deserves.
    private func log(_ event: SessionEvent) {
        switch event {
        case .listening:
            Log.network.notice("listening on port 50515, advertising _d65._tcp")
        case .listenerFailed(let text):
            Log.network.error("listener failed: \(text, privacy: .public)")
        case .probeConnected(let identity):
            Log.network.notice("probe connected: \(identity.model, privacy: .public), build \(identity.build, privacy: .public)")
        case .probeDisconnected:
            Log.network.notice("probe disconnected")
        case .probeRejected(let text):
            Log.network.notice("probe refused: \(text, privacy: .public)")
        case .placement(let reading):
            Log.session.debug("placement \(reading.state.rawValue, privacy: .public)")
        case .startRequested:
            Log.session.info("start requested on the patch window")
        case .cancelRequested:
            Log.session.info("cancel requested on the patch window")
        case .progress(let progress):
            switch progress {
            case .patch(let index, let total, let patch):
                Log.session.debug("patch \(index + 1)/\(total): \(patch.name, privacy: .public)")
            case .applying(let pass, let gains):
                Log.session.info("applying pass \(pass): R \(gains.r) G \(gains.g) B \(gains.b)")
            case .verifying(let pass):
                Log.session.debug("verifying pass \(pass)")
            case .passMeasured(let pass):
                Log.session.info("pass \(pass.number) measured: ΔE \(pass.deltaE, format: .fixed(precision: 3))")
            case .restoring:
                Log.session.info("restoring the display")
            }
        case .finished(let record, let saveError):
            let baseline = record.baselineDeltaE.map { String(format: "%.3f", $0) } ?? "–"
            let best = record.bestDeltaE.map { String(format: "%.3f", $0) } ?? "–"
            Log.session.notice("""
                session \(record.id.uuidString, privacy: .public) on \(record.display.name, privacy: .public) \
                \(record.outcome.rawValue, privacy: .public): ΔE \(baseline, privacy: .public) → \(best, privacy: .public), \
                \(record.passes.count) pass(es); \(record.terminationReason, privacy: .public)
                """)
            for failure in record.restorationErrors {
                Log.session.fault("display not restored after session: \(failure, privacy: .public)")
            }
            if let saveError { Log.store.error("couldn’t save the session record: \(saveError, privacy: .public)") }
        case .runFailed(let text):
            Log.session.error("run failed to start: \(text, privacy: .public)")
        }
    }
}

enum Accessibility {
    static func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// Keep the session window off the display being measured, when there is another one.
enum SessionWindowPlacement {
    static let identifier = "session"
    @MainActor static func moveAway(from displayID: UInt32) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(identifier) == true }),
              let other = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value != displayID
              }) else { return }
        let frame = other.visibleFrame
        window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
    }
}
