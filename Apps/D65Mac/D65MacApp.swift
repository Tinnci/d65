import SwiftUI

@main
struct D65MacApp: App {
    @NSApplicationDelegateAdaptor(D65AppDelegate.self) private var delegate
    @StateObject private var agent: AgentModel
    @StateObject private var session: SessionModel

    init() {
        let agent = AgentModel()
        _agent = StateObject(wrappedValue: agent)
        _session = StateObject(wrappedValue: SessionModel(agent: agent))
    }

    var body: some Scene {
        MenuBarExtra {
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

    /// Restore every display before exiting: cancel a running session (the engine restores), then release holds.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await session?.shutdown()
            agent?.releaseAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
