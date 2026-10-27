import D65Calibration
import D65Display
import D65MacRuntime
import SwiftUI

/// The menu-bar popover: corrections and DDC/CI hardware controls for each display.
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                WhitePointGlyph(mode: row.glyph)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.display.name).fontWeight(.semibold)
                    Text(row.statusLine).font(.caption).monospacedDigit()
                        .foregroundStyle(row.error != nil ? Theme.critical : row.stale != nil ? Theme.warn : .secondary)
                        .lineLimit(2)
                    if let note = row.note {
                        Label(note, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(Theme.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
            if !row.display.isBuiltin {
                HardwareControlsView(agent: agent, display: row.display)
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
    }
}

private struct HardwareControlsView: View {
    @ObservedObject var agent: AgentModel
    let display: DisplayInfo

    private var state: AgentModel.HardwareControls? { agent.hardwareControls[display.identity] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if agent.controlsPaused {
                Text("Hardware controls paused during calibration")
                    .font(.caption).foregroundStyle(.secondary)
            } else if state == nil || state?.loading == true {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Reading DDC/CI controls…").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ForEach(MonitorAdjustment.allCases, id: \.self) { control in
                    if let value = state?.values[control] {
                        HardwareSlider(control: control, value: value, displayName: display.name) { requested in
                            await agent.adjust(control, to: requested, for: display)
                        }
                        .disabled(state?.writing == true)
                    }
                }
                HStack {
                    Text(state?.values.isEmpty == false ? "DDC/CI · Hardware" : "DDC/CI unavailable · Enable it in the monitor’s menu")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button {
                        Task { await agent.loadHardwareControls(for: display) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(state?.writing == true)
                    .help("Refresh monitor controls")
                    .accessibilityLabel("Refresh controls for \(display.name)")
                }
                .font(.caption2).foregroundStyle(.secondary)
                if let message = state?.message {
                    Text(message).font(.caption).foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if state?.values[.contrast] != nil, agent.rows.first(where: { $0.id == display.identity })?.correction != nil {
                    Text("Changing contrast may make the correction stale.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: agent.controlGeneration) { await agent.loadHardwareControls(for: display) }
    }
}

private struct HardwareSlider: View {
    let control: MonitorAdjustment
    let value: DDCValue
    let displayName: String
    let adjust: (UInt16) async -> Void
    @State private var draft: Double?

    private var current: Double { draft ?? Double(value.current) }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Label(control.title, systemImage: symbol).font(.caption)
                Spacer()
                Text("\(Int((current / Double(value.maximum) * 100).rounded()))%")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { current }, set: { draft = $0 }),
                   in: 0...Double(value.maximum))
                .controlSize(.small)
                .accessibilityLabel("\(control.title) for \(displayName)")
                .accessibilityValue("\(Int((current / Double(value.maximum) * 100).rounded())) percent")
        }
        // Coalesce dragging and keyboard repeats without blocking the menu or flooding the I2C bus.
        .task(id: draft) {
            guard let draft else { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled else { return }
            await adjust(UInt16(draft.rounded()))
            self.draft = nil
        }
    }

    private var symbol: String {
        switch control {
        case .brightness: "sun.max"
        case .contrast: "circle.lefthalf.filled"
        case .volume: "speaker.wave.2"
        }
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
