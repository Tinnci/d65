import D65Calibration
import SwiftUI

/// The menu-bar popover: one row per display, its validity, and the A/B switch.
struct MenuPanel: View {
    @ObservedObject var agent: AgentModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(agent.rows) { row in DisplayRow(agent: agent, row: row) }
            if agent.rows.isEmpty {
                Text("No displays found").foregroundStyle(.secondary).padding(8)
            }
            Divider().padding(.vertical, 4)
            MenuButton(title: "Calibrate Display…", shortcut: "⇧⌘D") {
                openWindow(id: SessionWindowPlacement.identifier)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            MenuButton(title: "History & Settings…", shortcut: "⌘,") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider().padding(.vertical, 4)
            MenuButton(title: "Quit D65", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
            Text("Quitting removes all corrections until D65 runs again.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 4)
        }
        .padding(6)
        .frame(width: 340)
        .tint(Theme.accent)
    }
}

private struct DisplayRow: View {
    @ObservedObject var agent: AgentModel
    let row: AgentModel.Row
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            WhitePointGlyph(mode: row.glyph)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.display.name).fontWeight(.semibold)
                Text(row.statusLine).font(.caption).monospacedDigit()
                    .foregroundStyle(row.error != nil ? Theme.critical : row.stale != nil ? Theme.warn : .secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if row.correction != nil {
                Toggle("", isOn: Binding(get: { row.hold == .held || row.hold == .previewing },
                                         set: { agent.setEnabled($0, for: row) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .accessibilityLabel("Correction for \(row.display.name)")
                    .disabled(row.hold == .previewing)
            }
        }
        .padding(8)
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .contextMenu {
            if row.correction != nil {
                Button("Remove Correction") { agent.removeCorrection(for: row) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MenuButton: View {
    let title: String
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack { Text(title); Spacer(); Text(shortcut).foregroundStyle(.secondary) }
                .contentShape(Rectangle())
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
