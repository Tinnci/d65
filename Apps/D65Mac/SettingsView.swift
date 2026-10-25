import D65Calibration
import SwiftUI

struct SettingsView: View {
    @ObservedObject var agent: AgentModel
    var body: some View {
        TabView {
            GeneralSettings(agent: agent).tabItem { Label("General", systemImage: "gearshape") }
            HistoryView(agent: agent).tabItem { Label("History", systemImage: "clock") }
        }
        .frame(width: 560, height: 420)
        .tint(Theme.accent)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var agent: AgentModel
    var body: some View {
        Form {
            Section {
                Toggle("Open D65 at login", isOn: Binding(get: { agent.launchAtLogin }, set: { agent.setLaunchAtLogin($0) }))
                Text("macOS removes a correction when D65 quits. Opening at login reapplies it after a restart.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = agent.loginItemError { Text(error).font(.caption).foregroundStyle(Theme.warn) }
            }
            Section {
                Toggle("Show progress at the bottom of the patches", isOn: $agent.showsProgressOnPatches)
                Text("A thin line and a short label in the bottom edge of the display being measured, away from the sensor.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Data") {
                LabeledContent("Session records") {
                    Button("Show in Finder") { NSWorkspace.shared.open(agent.recordDirectory) }
                }
                LabeledContent("Kept corrections") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([agent.store.url]) }
                }
            }
            Section {
                Text("Diagnostic tests that write to the monitor over DDC (brightness, contrast, gain) are only available from the command line: d65 serve --effect-test.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct HistoryView: View {
    @ObservedObject var agent: AgentModel
    @State private var records: [ExperimentRecord] = []
    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView("No sessions yet", systemImage: "circle.dotted",
                    description: Text("Each calibration, including failed ones, is recorded here."))
            } else {
                Table(records) {
                    TableColumn("Date") { Text($0.startedAt.formatted(date: .abbreviated, time: .shortened)) }
                    TableColumn("Display") { Text($0.display.name) }
                    TableColumn("Result") { record in
                        Text(SessionSummary(record: record).title).foregroundStyle(record.outcome == .failed ? Theme.warn : .primary)
                    }
                    TableColumn("ΔE00") { record in
                        Text(record.bestGains?.isIdentity == false
                             ? "\(Format.deltaE(record.baselineDeltaE)) → \(Format.deltaE(record.bestDeltaE))"
                             : Format.deltaE(record.baselineDeltaE))
                            .monospacedDigit()
                    }
                    .width(90)
                }
                .contextMenu(forSelectionType: ExperimentRecord.ID.self) { ids in
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(ids.map { agent.recordDirectory.appendingPathComponent($0.uuidString + ".json") })
                    }
                }
            }
        }
        .onAppear(perform: load)
    }
    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: agent.recordDirectory, includingPropertiesForKeys: nil)) ?? []
        records = files.filter { $0.pathExtension == "json" }
            .compactMap { try? ExperimentRecord.decode(Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
    }
}

extension ExperimentRecord: Identifiable {}
