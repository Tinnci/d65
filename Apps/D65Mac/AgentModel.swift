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
        var statusLine: String {
            if let error { return error }
            guard let correction else { return display.isBuiltin ? "Not calibrated · built-in" : "Not calibrated" }
            if let stale { return "Stale · \(stale.description)" }
            switch hold {
            case .paused: return "Correction off · ΔE00 \(Format.deltaE(correction.deltaE)) when on"
            case .previewing: return "Previewing"
            default:
                let line = "Corrected · ΔE00 \(Format.deltaE(correction.deltaE)) · \(Format.relative(correction.createdAt))"
                return unverified.map { line + "\nCan’t verify monitor settings: \($0.lowercased())" } ?? line
            }
        }
    }

    @Published private(set) var rows: [Row] = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginItemError: String?
    @AppStorage("showsProgressOnPatches") var showsProgressOnPatches = true

    let store: CorrectionStore
    let recordDirectory: URL
    private var holds: [String: (displayID: UInt32, hold: CorrectionHold)] = [:]
    private var readings: [String: MonitorReading] = [:]
    /// DDC endpoints often answer only a few seconds after wake; polls wait until then.
    private var pollPausedUntil = Date.distantPast
    /// Displays whose correction the user turned off; survives reconfiguration, not relaunch.
    private var userPaused: Set<String> = []
    private var calibrating: String?
    private var poll: Timer?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("D65", isDirectory: true)
        store = CorrectionStore(url: support.appendingPathComponent("Corrections.json"))
        recordDirectory = support.appendingPathComponent("Experiments", isDirectory: true)
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
        let online = DisplayDirectory.online()
        // A display that left or changed ID has lost its table already; forget the hold without restoring.
        for (identity, entry) in holds where !online.contains(where: { $0.identity == identity && $0.id == entry.displayID }) {
            holds[identity] = nil
        }
        for display in online where display.identity != calibrating {
            guard let correction = store.correction(for: display.identity, modeSignature: display.modeSignature) else { continue }
            let hold = self.hold(for: display)
            do {
                if userPaused.contains(display.identity) { continue }
                if hold.gains == correction.gains, hold.state == .held { if reapply { try hold.reassert() } }
                else if hold.state != .previewing, hold.state != .paused { try hold.hold(correction.gains, gamma: correction.gamma) }
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
    }

    /// Read guarded settings for displays whose correction records any. Skipped during a session
    /// (the engine owns the bus), for sleeping displays, and briefly after wake.
    private func pollMonitorSettings() {
        guard calibrating == nil, Date() >= pollPausedUntil else { return }
        let targets = rows.filter { $0.correction.map { !$0.guardedSettings.isEmpty } == true && CGDisplayIsAsleep($0.display.id) == 0 }
            .map { ($0.display.identity, $0.display.id) }
        guard !targets.isEmpty else { return }
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
        DisplayDirectory.refreshMonitorControl()
        pollPausedUntil = Date().addingTimeInterval(5)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            self.pollMonitorSettings()
        }
    }

    private func hold(for display: DisplayInfo) -> CorrectionHold {
        if let entry = holds[display.identity], entry.displayID == display.id { return entry.hold }
        let hold = CorrectionHold(backend: MacDisplayOutput(displayID: display.id))
        holds[display.identity] = (display.id, hold)
        return hold
    }

    private func setError(_ text: String?, for identity: String) {
        if let index = rows.firstIndex(where: { $0.id == identity }) { rows[index].error = text }
    }

    // MARK: User actions

    func setEnabled(_ enabled: Bool, for row: Row) {
        guard let entry = holds[row.id] else { refresh(); return }
        do {
            try entry.hold.setPaused(!enabled)
            if enabled { userPaused.remove(row.id) } else { userPaused.insert(row.id) }
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
        try? store.remove(displayIdentity: row.id)
        refresh()
    }

    /// Reset the system ColorSync tables, for the one state where D65 can't vouch for the display.
    func resetDisplayColours() {
        for entry in holds.values { try? entry.hold.release() }
        holds.removeAll()
        CGDisplayRestoreColorSyncSettings()
        for index in rows.indices { rows[index].error = nil }
        refresh()
    }

    // MARK: Session hand-off

    /// The engine must capture the display's original table, so any held correction steps aside.
    func prepareForCalibration(identity: String) {
        calibrating = identity
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
        readings.removeAll()
        refresh()
        pollMonitorSettings()
    }

    func releaseAll() {
        for entry in holds.values { try? entry.hold.release() }
        holds.removeAll()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch { loginItemError = "macOS refused: \(error.localizedDescription)" }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
