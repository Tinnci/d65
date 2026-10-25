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
    var onClose: (() -> Void)?

    init(agent: AgentModel) { self.agent = agent; reloadDisplays() }

    var selected: DisplayInfo? { displays.first { $0.id == selectedID } }
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
            } catch {
                notice = "D65 can’t listen on the local network: \(error.localizedDescription)"
                return
            }
        }
        service?.showsProgressOnPatches = agent.showsProgressOnPatches
        if probe != nil { enterPlacement() } else { step = .connect; waitingSince = Date() }
    }

    func startNow() {
        guard step == .place, let display = selected, let service else { return }
        agent.prepareForCalibration(identity: display.identity)
        patchIndex = 0; passes = []; verifyingPass = nil; record = nil; summary = nil; saveError = nil
        phase = CalibrationPatch.sequence[0].name
        step = .measure
        service.run(configuration: CalibrationConfiguration(mode: measureOnly ? .measureOnly : .calibrate), displayID: display.id)
    }

    func back() {
        switch step {
        case .connect: step = .prepare
        case .place: service?.endPlacement(); step = .prepare
        case .measure: service?.cancelRun()
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
        let service = self.service
        self.service = nil
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
