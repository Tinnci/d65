import AppKit
import D65Calibration
import SwiftUI

/// Debug-only screenshot mode: `D65Mac --showcase <menu|prepare|place|measure|review|history> [--appearance dark]`.
/// Opens one screen in an ordinary window, filled from the real store, monitors and session records,
/// and prints its window number for `screencapture -l`. It never writes a gamma table.
enum Showcase {
    @MainActor static var models: (AgentModel, SessionModel)?
    @MainActor private static var window: NSWindow?

    static var isActive: Bool {
        #if DEBUG
        scene != nil
        #else
        false
        #endif
    }

    static var scene: String? { argument(after: "--showcase") }
    private static var dark: Bool { argument(after: "--appearance") == "dark" }

    private static func argument(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    @MainActor static func present(agent: AgentModel, session: SessionModel) {
        #if DEBUG
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let latest = latestRecord(in: agent.recordDirectory)
        let content: AnyView
        var title = "Calibrate"
        var chrome: NSWindow.StyleMask = [.titled, .closable]
        switch scene {
        case "menu":
            title = ""
            chrome = [.borderless]
            content = AnyView(MenuPanel(agent: agent)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.rule))
                .padding(24))
        case "history":
            title = "History & Settings"
            content = AnyView(SettingsView(agent: agent, tab: .history))
        case "place":
            session.showcase(step: .place, probe: latest?.probe,
                             placement: PlacementReading(state: .settling, luminance: 141.9, steadyFraction: 0.7))
            content = AnyView(SessionView(model: session))
        case "measure":
            session.showcase(step: .measure, probe: latest?.probe, patchIndex: 4)
            content = AnyView(SessionView(model: session))
        case "review":
            session.showcase(step: .review, probe: latest?.probe, record: latest)
            content = AnyView(SessionView(model: session))
        default:
            content = AnyView(SessionView(model: session))
        }
        let hosting = NSHostingView(rootView: content)
        let size = hosting.fittingSize
        let created = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: chrome, backing: .buffered, defer: false)
        created.title = title
        created.contentView = hosting
        if chrome.contains(.borderless) { created.isOpaque = false; created.backgroundColor = .clear; created.hasShadow = false }
        created.center()
        created.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = created
        print("SHOWCASE_WINDOW \(created.windowNumber)")
        fflush(stdout)
        // Draw the window into a PNG from inside the process; needs no screen-recording permission.
        if let output = argument(after: "--output") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.5))   // let async reads (DDC, records) settle
                let ok = snapshot(created, to: URL(fileURLWithPath: output))
                print(ok ? "SHOWCASE_SAVED \(output)" : "SHOWCASE_FAILED")
                fflush(stdout)
                exit(0)   // skip the agent's shutdown path entirely
            }
        }
        #endif
    }

    /// Content view only: the title bar's vibrancy doesn't survive an offscreen draw (dark windows get a light bar).
    @MainActor private static func snapshot(_ window: NSWindow, to url: URL) -> Bool {
        guard let view = window.contentView else { return false }
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    private static func latestRecord(in directory: URL) -> ExperimentRecord? {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? ExperimentRecord.decode(Data(contentsOf: $0)) }
            .filter { $0.outcome == .converged }
            .max { $0.startedAt < $1.startedAt }
    }
}
