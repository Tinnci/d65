import AppKit
import D65Calibration
import D65Core
import D65Display
import D65MacRuntime
import ServiceManagement
import SwiftUI

/// The long-lived half of D65: holds each display's correction for as long as the app runs,
/// reapplies it when a display returns, and flags it when the monitor's state no longer matches.
@MainActor final class AgentModel: ObservableObject {
    struct Row: Identifiable {
        let display: DisplayInfo
        var correction: StoredCorrection?
        var hold: CorrectionHold.State
        /// Nil until the first poll has read the monitor.
        var verdict: GuardVerdict?
        var error: String?
        var id: String { display.identity }

        var stale: StaleReason? { if case .changed(let reason)? = verdict { reason } else { nil } }
        var unverified: String? { if case .unverified(let reason)? = verdict { reason } else { nil } }

        var glyph: WhitePointGlyph.Mode {
            if error != nil { return .critical }
            switch hold {
            case .held, .previewing: return stale == nil ? .held : .stale
            case .paused: return .paused
            case .none: return .none
            }
        }
        /// A caution under the status line, when the guard can't confirm the monitor's settings.
        var note: String? {
            guard error == nil, stale == nil, hold == .held, let unverified else { return nil }
            return "Can’t verify monitor settings: \(unverified.lowercased())"
        }
        var statusLine: String {
            if let error { return error }
            guard let correction else { return display.isBuiltin ? "Not calibrated · built-in" : "Not calibrated" }
            if let stale { return "Stale · \(stale.description)" }
            switch hold {
            case .paused: return "Correction off · \((correction.metric ?? .ciede2000).label) \(Format.deltaE(correction.deltaE)) when on"
            case .previewing: return "Previewing"
            default:
                let viewer = correction.viewerObserver.map { " for \($0.rawValue)" } ?? ""
                return "Corrected\(viewer) · \((correction.metric ?? .ciede2000).label) \(Format.deltaE(correction.deltaE)) · \(Format.relative(correction.createdAt))"
            }
        }
    }

    @Published private(set) var rows: [Row] = []
    struct HardwareControls {
        var values: [MonitorAdjustment: DDCValue] = [:]
        var loading = false
        var writing = false
        var message: String?
    }
    @Published private(set) var hardwareControls: [String: HardwareControls] = [:]
    @Published private(set) var controlsPaused = false
    private let monitorControl = TrayMonitorControl()
    @Published private(set) var controlGeneration = UUID()

    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginItemError: String?
    @AppStorage("showsProgressOnPatches") var showsProgressOnPatches = true

    let store: CorrectionStore
    /// Imported primary spectra per display, for targets seen by a viewer other than the probe's observer.
    let spectraStore: PrimarySpectraStore
    let recordDirectory: URL
    /// False only in the debug showcase: nothing may write a gamma table.
    let holdsDisplays: Bool
    private var holds: [String: (displayID: UInt32, hold: CorrectionHold)] = [:]
    private var readings: [String: MonitorReading] = [:]
    /// DDC endpoints often answer only a few seconds after wake; polls wait until then.
    private var pollPausedUntil = Date.distantPast
    /// Displays whose correction the user turned off; survives reconfiguration, not relaunch.
    private var userPaused: Set<String> = []
    private var calibrating: String?
    private var poll: Timer?
    /// The last stale reason logged per display, so the log records changes rather than every poll.
    private var loggedStale: [String: String] = [:]

    /// Displays whose correction is on the screen right now (held or previewed).
    var heldCount: Int { holds.values.filter { $0.hold.state == .held || $0.hold.state == .previewing }.count }

    /// `holdsDisplays: false` reads the store and the monitors but never writes a gamma table
    /// (used by the debug showcase, which may run beside the real agent).
    init(holdsDisplays: Bool = true) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("D65", isDirectory: true)
        store = CorrectionStore(url: support.appendingPathComponent("Corrections.json"))
        spectraStore = PrimarySpectraStore(url: support.appendingPathComponent("PrimarySpectra.json"))
        recordDirectory = support.appendingPathComponent("Experiments", isDirectory: true)
        self.holdsDisplays = holdsDisplays
        guard holdsDisplays else {
            rows = DisplayDirectory.online().map { display in
                let correction = store.correction(for: display.identity, modeSignature: display.modeSignature)
                let verdict = correction.map {
                    $0.check(modeSignature: display.modeSignature, monitor: DisplayDirectory.monitorReading(displayID: display.id))
                }
                return Row(display: display, correction: correction, hold: correction == nil ? .none : .held,
                           verdict: verdict, error: nil)
            }
            return
        }
        refresh()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh(reapply: true) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didWake() }
        }
        poll = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMonitorSettings() }
        }
        pollMonitorSettings()
    }

    var menuBarSymbol: String {
        if rows.contains(where: { $0.error != nil }) { return "exclamationmark.circle" }
        if rows.contains(where: { $0.stale != nil && $0.hold == .held }) { return "circle.dotted" }
        return rows.contains(where: { $0.hold == .held }) ? "circle.inset.filled" : "circle"
    }

    // MARK: Display changes

    /// `reapply` rewrites held tables; only display reconfiguration needs that, since the system may have reset them.
    func refresh(reapply: Bool = false) {
        guard holdsDisplays else { return }
        let online = DisplayDirectory.online()
        if Set(online) != Set(rows.map(\.display)) {
            controlGeneration = UUID()
            hardwareControls = [:]
            for display in online where !rows.contains(where: { $0.display == display }) {
                Log.display.notice("""
                    display online: \(display.name, privacy: .public) [\(display.id)] \
                    \(display.width)×\(display.height) @ \(Int(display.refreshRate.rounded())) Hz\(display.isBuiltin ? ", built-in" : "", privacy: .public)
                    """)
            }
            for row in rows where !online.contains(row.display) {
                Log.display.notice("display offline: \(row.display.name, privacy: .public) [\(row.display.id)]")
            }
        }
        // A display that left or changed ID has lost its table already; forget the hold without restoring.
        for (identity, entry) in holds where !online.contains(where: { $0.identity == identity && $0.id == entry.displayID }) {
            holds[identity] = nil
        }
        for display in online where display.identity != calibrating {
            guard let correction = store.correction(for: display.identity, modeSignature: display.modeSignature) else { continue }
            let hold = self.hold(for: display)
            do {
                if userPaused.contains(display.identity) { continue }
                if hold.gains == correction.gains, hold.state == .held {
                    if reapply {
                        try hold.reassert()
                        Log.correction.info("reasserted correction on \(display.name, privacy: .public) after reconfiguration")
                    }
                } else if hold.state != .previewing, hold.state != .paused {
                    try hold.hold(correction.gains, gamma: correction.gamma)
                    Log.correction.notice("""
                        holding correction on \(display.name, privacy: .public): \
                        gains \(Self.describe(correction.gains), privacy: .public), gamma \(correction.gamma, format: .fixed(precision: 3))
                        """)
                }
            } catch { setError("Couldn’t apply the correction: \(error)", for: display.identity) }
        }
        rows = online.map { display in
            let correction = store.correction(for: display.identity, modeSignature: display.modeSignature)
            // Mode is known without DDC, so a mode change shows before the first poll.
            let verdict = correction.flatMap { correction -> GuardVerdict? in
                if let reading = readings[display.identity] {
                    return correction.check(modeSignature: display.modeSignature, monitor: reading)
                }
                let modeOnly = correction.check(modeSignature: display.modeSignature, monitor: .values([:]))
                if case .changed = modeOnly { return modeOnly }
                return correction.guardedSettings.isEmpty ? .unguarded : nil
            }
            return Row(display: display, correction: correction, hold: holds[display.identity]?.hold.state ?? .none,
                       verdict: verdict, error: rows.first { $0.id == display.identity }?.error)
        }
        .sorted { !$0.display.isBuiltin && $1.display.isBuiltin }
        logStaleChanges()
    }

    /// One line when a correction becomes stale, changes reason, or matches the monitor again.
    private func logStaleChanges() {
        for row in rows where row.correction != nil {
            let reason = row.stale?.description
            guard loggedStale[row.id] != reason else { continue }
            if let reason {
                Log.correction.notice("correction on \(row.display.name, privacy: .public) is stale: \(reason, privacy: .public)")
            } else if loggedStale[row.id] != nil {
                Log.correction.notice("correction on \(row.display.name, privacy: .public) matches the monitor again")
            }
            loggedStale[row.id] = reason
        }
    }

    private static func describe(_ gains: RGBGains) -> String {
        String(format: "R %.4f G %.4f B %.4f", gains.r, gains.g, gains.b)
    }

    /// Read guarded settings for displays whose correction records any. Skipped during a session
    /// (the engine owns the bus), for sleeping displays, and briefly after wake.
    private func pollMonitorSettings() {
        guard calibrating == nil, Date() >= pollPausedUntil else { return }
        let targets = rows.filter { $0.correction.map { !$0.guardedSettings.isEmpty } == true && CGDisplayIsAsleep($0.display.id) == 0 }
            .map { ($0.display.identity, $0.display.id) }
        guard !targets.isEmpty else { return }
        Log.ddc.debug("polling guarded settings on \(targets.count) display(s)")
        Task.detached(priority: .utility) {
            var results: [String: MonitorReading] = [:]
            for (identity, id) in targets { results[identity] = DisplayDirectory.monitorReading(displayID: id) }
            await MainActor.run { [results] in
                self.readings.merge(results) { $1 }
                self.refresh()
            }
        }
    }

    private func didWake() {
        Log.lifecycle.notice("system woke; DDC polls wait 5 s, \(self.heldCount) correction(s) held")
        controlGeneration = UUID()
        hardwareControls = [:]
        DisplayDirectory.refreshMonitorControl()
        pollPausedUntil = Date().addingTimeInterval(5)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            self.hardwareControls = [:]
            self.controlGeneration = UUID()
            self.pollMonitorSettings()
        }
    }

    private func hold(for display: DisplayInfo) -> CorrectionHold {
        precondition(holdsDisplays, "the showcase must never hold a display")
        if let entry = holds[display.identity], entry.displayID == display.id { return entry.hold }
        let hold = CorrectionHold(backend: MacDisplayOutput(displayID: display.id))
        holds[display.identity] = (display.id, hold)
        return hold
    }

    private func setError(_ text: String?, for identity: String) {
        if let text {
            let name = rows.first { $0.id == identity }?.display.name ?? identity
            Log.correction.error("\(name, privacy: .public): \(text, privacy: .public)")
        }
        if let index = rows.firstIndex(where: { $0.id == identity }) { rows[index].error = text }
    }

    // MARK: User actions

    func loadHardwareControls(for display: DisplayInfo) async {
        guard !display.isBuiltin, !controlsPaused,
              hardwareControls[display.identity]?.loading != true,
              hardwareControls[display.identity]?.writing != true else { return }
        let generation = controlGeneration
        hardwareControls[display.identity, default: HardwareControls()].loading = true
        let values = await monitorControl.read(displayID: display.id, identity: display.identity)
        guard generation == controlGeneration, !controlsPaused,
              rows.contains(where: { $0.display == display }) else { return }
        if values.isEmpty {
            Log.ddc.info("no DDC/CI controls answered on \(display.name, privacy: .public)")
        } else {
            let summary = values.sorted { $0.key.title < $1.key.title }
                .map { "\($0.key.title) \($0.value.current)/\($0.value.maximum)" }.joined(separator: ", ")
            Log.ddc.info("read \(display.name, privacy: .public): \(summary, privacy: .public)")
        }
        hardwareControls[display.identity] = HardwareControls(values: values)
    }

    func adjust(_ control: MonitorAdjustment, to value: UInt16, for display: DisplayInfo) async {
        guard holdsDisplays, !controlsPaused,
              var state = hardwareControls[display.identity], !state.writing, !state.loading,
              let previous = state.values[control] else { return }
        let generation = controlGeneration
        state.writing = true
        state.message = nil
        hardwareControls[display.identity] = state
        do {
            let actual = try await monitorControl.set(control, value: value, maximum: previous.maximum,
                                                       displayID: display.id, identity: display.identity)
            state.values[control] = actual
            Log.ddc.notice("""
                set \(control.title, privacy: .public) on \(display.name, privacy: .public) \
                to \(actual.current)/\(actual.maximum) (requested \(value))
                """)
        } catch {
            Log.ddc.error("""
                \(control.title, privacy: .public) write to \(value) on \(display.name, privacy: .public) \
                failed: \(String(describing: error), privacy: .public)
                """)
            switch error {
            case AdjustmentError.notAccepted(let actual):
                state.values[control] = actual
                state.message = "The monitor did not accept the \(control.title.lowercased()) setting."
            case AdjustmentError.unverified:
                state.values[control] = nil
                state.message = "Couldn’t verify \(control.title.lowercased()). Refresh to read the monitor."
            default:
                state.message = "Couldn’t change \(control.title.lowercased()). Check that DDC/CI is enabled in the monitor’s menu."
            }
        }
        guard generation == controlGeneration, !controlsPaused,
              rows.contains(where: { $0.display == display }) else { return }
        state.writing = false
        hardwareControls[display.identity] = state
        // Contrast is a guarded calibration setting; reflect the new verdict immediately.
        if control == .contrast { pollMonitorSettings() }
    }

    func setEnabled(_ enabled: Bool, for row: Row) {
        guard let entry = holds[row.id] else { refresh(); return }
        do {
            try entry.hold.setPaused(!enabled)
            if enabled { userPaused.remove(row.id) } else { userPaused.insert(row.id) }
            Log.correction.notice("correction on \(row.display.name, privacy: .public) turned \(enabled ? "on" : "off", privacy: .public)")
            setError(nil, for: row.id)
        } catch { setError("Couldn’t change the correction: \(error)", for: row.id) }
        refresh()
    }

    func compare(original: Bool, identity: String) {
        try? holds[identity]?.hold.showOriginal(original)
    }

    func removeCorrection(for row: Row) {
        try? holds[row.id]?.hold.release()
        holds[row.id] = nil
        userPaused.remove(row.id)
        do {
            try store.remove(displayIdentity: row.id)
            Log.correction.notice("removed the stored correction for \(row.display.name, privacy: .public)")
        } catch {
            Log.store.error("couldn’t remove the correction for \(row.display.name, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        refresh()
    }

    /// Reset the system ColorSync tables, for the one state where D65 can't vouch for the display.
    func resetDisplayColours() {
        Log.correction.notice("resetting ColorSync tables on every display; releasing \(self.holds.count) hold(s)")
        for entry in holds.values { try? entry.hold.release() }
        holds.removeAll()
        CGDisplayRestoreColorSyncSettings()
        for index in rows.indices { rows[index].error = nil }
        refresh()
    }

    // MARK: Session hand-off

    /// The engine must capture the display's original table, so any held correction steps aside.
    func prepareForCalibration(identity: String) async {
        calibrating = identity
        controlsPaused = true
        controlGeneration = UUID()
        // Await the worker so an already-running adjustment finishes before patch measurement.
        await monitorControl.setSuspended(true)
        guard calibrating == identity, !Task.isCancelled else { return }
        if holds[identity] != nil {
            let name = rows.first { $0.id == identity }?.display.name ?? identity
            Log.correction.info("released the correction on \(name, privacy: .public) for calibration")
        }
        try? holds[identity]?.hold.release()
        holds[identity] = nil
        refresh()
    }

    func preview(_ record: ExperimentRecord) {
        guard let gains = record.bestGains, let display = rows.first(where: { $0.id == record.display.identity })?.display else { return }
        do { try hold(for: display).preview(gains, gamma: record.gamma) }
        catch { setError("Couldn’t preview the correction: \(error)", for: display.identity) }
        refresh()
    }

    func compareDuringReview(original: Bool, identity: String) { compare(original: original, identity: identity) }

    func keep(_ record: ExperimentRecord) {
        guard let gains = record.bestGains else { return }
        do {
            try store.save(StoredCorrection(record: record, gains: gains))
            holds[record.display.identity]?.hold.keep()
            userPaused.remove(record.display.identity)
            Log.correction.notice("""
                kept correction for \(record.display.name, privacy: .public) from session \(record.id.uuidString, privacy: .public): \
                gains \(Self.describe(gains), privacy: .public)
                """)
        } catch { setError("Couldn’t save the correction: \(error)", for: record.display.identity) }
        finishCalibration()
    }

    /// Drop any preview and return the display to its stored correction, if it has one.
    func finishCalibration() {
        if let identity = calibrating, holds[identity]?.hold.state == .previewing {
            try? holds[identity]?.hold.release()
            holds[identity] = nil
        }
        calibrating = nil
        hardwareControls = [:]
        controlGeneration = UUID()
        Task {
            guard calibrating == nil else { return }
            await monitorControl.setSuspended(false)
            guard calibrating == nil else { return }
            controlsPaused = false
            controlGeneration = UUID()
        }
        readings.removeAll()
        refresh()
        pollMonitorSettings()
    }

    /// Returns how many displays could not be restored.
    @discardableResult func releaseAll() -> Int {
        var failures = 0
        for (identity, entry) in holds {
            do { try entry.hold.release() } catch {
                failures += 1
                let name = rows.first { $0.id == identity }?.display.name ?? identity
                Log.correction.error("couldn’t restore \(name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        holds.removeAll()
        return failures
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = "macOS refused: \(error.localizedDescription)"
            Log.lifecycle.error("launch at login \(enabled ? "register" : "unregister", privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        Log.lifecycle.notice("launch at login is \(self.launchAtLogin ? "on" : "off", privacy: .public) (status \(SMAppService.mainApp.status.rawValue))")
    }
}
