import AppKit
import D65MacRuntime
import SwiftUI

@main
struct D65MacApp: App {
    @NSApplicationDelegateAdaptor(D65AppDelegate.self) private var delegate
    @StateObject private var agent: AgentModel
    @StateObject private var session: SessionModel

    init() {
        let agent = AgentModel(holdsDisplays: !Showcase.isActive)
        _agent = StateObject(wrappedValue: agent)
        let session = SessionModel(agent: agent)
        _session = StateObject(wrappedValue: session)
        Showcase.models = (agent, session)
    }

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(!Showcase.isActive)) {
            MenuPanel(agent: agent)
                .onAppear { delegate.agent = agent; delegate.session = session }
        } label: {
            Image(systemName: agent.menuBarSymbol)
                .accessibilityLabel("D65")
        }
        .menuBarExtraStyle(.window)

        Window("Calibrate", id: SessionWindowPlacement.identifier) {
            SessionWindow(session: session)
                .onAppear { delegate.agent = agent; delegate.session = session; session.reloadDisplays() }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView(agent: agent)
        }
    }
}

@MainActor final class D65AppDelegate: NSObject, NSApplicationDelegate {
    weak var agent: AgentModel?
    weak var session: SessionModel?
    private var launchedAsLoginItem = false
    private var terminationSignal: DispatchSourceSignal?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The open-application event is only readable here; it says whether launchd started D65 at login.
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAsLoginItem = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The menu panel's onAppear may never run (the user can quit without opening it).
        if agent == nil, let (agent, session) = Showcase.models { self.agent = agent; self.session = session }
        guard !Showcase.isActive else {
            Log.lifecycle.debug("showcase launch: \(Showcase.scene ?? "", privacy: .public)")
            // The menu panel's onAppear never runs in the showcase, so hand the models over here.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                if let (agent, session) = Showcase.models { Showcase.present(agent: agent, session: session) }
            }
            return
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let revision = info["D65SoftwareRevision"] as? String ?? "unknown"
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        Log.lifecycle.notice("""
            launched D65 \(version, privacy: .public) (\(build, privacy: .public), \(revision, privacy: .public)) \
            on macOS \(system, privacy: .public)\(self.launchedAsLoginItem ? " as a login item" : "", privacy: .public); \
            launch at login \(self.agent?.launchAtLogin == true ? "on" : "off", privacy: .public)
            """)
        // D65 is resident by design: an idle menu-bar app with no windows must not be reclaimed by
        // automatic termination, which would drop every correction without a word.
        ProcessInfo.processInfo.disableAutomaticTermination("D65 holds display corrections")
        // SIGTERM (an installer, `killall`, launchd) goes through the same restore-and-quit path.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            QuitReason.requested = "SIGTERM"
            // Not from inside this main-queue block: terminate waits for a main-actor task that
            // could never run until the block returned.
            RunLoop.main.perform(inModes: [.common]) { NSApp.terminate(nil) }
        }
        source.resume()
        terminationSignal = source
    }

    /// Restore every display before exiting: cancel a running session (the engine restores), then release holds.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let agent = self.agent ?? Showcase.models?.0
        let session = self.session ?? Showcase.models?.1
        let reason = QuitReason.describe()
        let held = agent?.heldCount ?? 0
        Log.lifecycle.notice("quit requested (\(reason, privacy: .public)); \(held) correction(s) held")
        let started = ContinuousClock.now
        Task {
            await session?.shutdown()
            let failures = agent?.releaseAll() ?? 0
            let elapsed = (ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds]))
            if failures == 0 {
                Log.lifecycle.notice("restored \(held) display(s) in \(elapsed, privacy: .public); exiting")
            } else {
                Log.lifecycle.fault("\(failures) display(s) could not be restored before exiting")
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Why the app is quitting, for the lifecycle log.
@MainActor enum QuitReason {
    /// Set by D65's own quit paths just before `NSApp.terminate`.
    static var requested: String?

    static func describe() -> String {
        if let requested { return requested }
        // Anything else arrives as a quit Apple event: logout, restart, shutdown, or another app.
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication) else {
            return "terminate from \(inputEvent()); called by \(caller())"
        }
        let why = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        let kind = switch why {
        case OSType(kAELogOut), OSType(kAEReallyLogOut): "log out"
        case OSType(kAERestart), OSType(kAEShowRestartDialog): "restart"
        case OSType(kAEShutDown), OSType(kAEShowShutdownDialog): "shut down"
        default: "quit event"
        }
        guard let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value, pid > 0 else { return kind }
        let sender = NSRunningApplication(processIdentifier: pid)
        return "\(kind) from \(sender?.localizedName ?? sender?.bundleIdentifier ?? "pid \(pid)")"
    }

    /// The input event AppKit was handling when terminate was called: a key equivalent or a click.
    private static func inputEvent() -> String {
        guard let event = NSApp.currentEvent else { return "no input event" }
        let window = event.window.map { String(describing: type(of: $0)) } ?? "no window"
        switch event.type {
        case .keyDown, .keyUp:
            var keys = ""
            if event.modifierFlags.contains(.control) { keys += "⌃" }
            if event.modifierFlags.contains(.option) { keys += "⌥" }
            if event.modifierFlags.contains(.shift) { keys += "⇧" }
            if event.modifierFlags.contains(.command) { keys += "⌘" }
            return "key \(keys)\(event.charactersIgnoringModifiers?.uppercased() ?? "?") in \(window)"
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            return "click in \(window)"
        default:
            return "event type \(event.type.rawValue) in \(window)"
        }
    }

    /// The first frames above AppKit's terminate, so an unexpected caller names itself.
    private static func caller() -> String {
        let frames = Thread.callStackSymbols.dropFirst(3).prefix(12).map { line in
            // "12  AppKit  0x0001… -[NSApplication terminate:] + 40" → "AppKit -[NSApplication terminate:]"
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4 else { return line }
            return "\(parts[1]) \(parts[3...].prefix { $0 != "+" }.joined(separator: " "))"
        }
        return frames.joined(separator: " ← ")
    }
}

/// Closing the window ends the session, and ending the session closes the window.
private struct SessionWindow: View {
    @ObservedObject var session: SessionModel
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        SessionView(model: session)
            .onAppear { session.onClose = { dismissWindow(id: SessionWindowPlacement.identifier) } }
            .onDisappear { Task { await session.shutdown() } }
    }
}
