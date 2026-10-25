import D65Calibration
import D65Core
import D65Display
import D65MacRuntime
import SwiftUI

struct SessionView: View {
    @ObservedObject var model: SessionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            StepBar(current: model.step).animation(Motion.change(reduceMotion), value: model.step)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let notice = model.notice {
                        Banner(tone: .warning, title: notice).transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    // Each step arrives from the side it advances toward.
                    VStack(alignment: .leading, spacing: 14) { content }
                        .id(model.step)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 18)), removal: .opacity))
                }
                .animation(Motion.change(reduceMotion), value: model.step)
                .animation(Motion.change(reduceMotion), value: model.notice)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            footer.padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(width: 540)
        .frame(minHeight: 440)
        .background(Theme.surface)
        .tint(Theme.accent)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .prepare: PrepareStep(model: model)
        case .connect: ConnectStep(model: model)
        case .place: PlaceStep(model: model)
        case .measure: MeasureStep(model: model)
        case .review: ReviewStep(model: model)
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 8) {
            switch model.step {
            case .prepare:
                Hint("Built-in displays are listed but not suggested")
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button("Continue") { model.continueFromPrepare() }
                    .keyboardShortcut(.defaultAction).disabled(model.selected == nil || model.whiteTarget == nil)
            case .connect:
                Hint("Connects on its own when the app opens")
                Button("Back") { model.back() }.keyboardShortcut(.cancelAction)
            case .place:
                Hint(model.placement.alignment?.blocksColourSampling == true ? "Finish depth alignment on the iPhone" : "Return starts now · Esc goes back")
                Button("Back") { model.back() }.keyboardShortcut(.cancelAction)
                Button("Start Now") { model.startNow() }.keyboardShortcut(.defaultAction)
                    .disabled(model.placement.alignment?.blocksColourSampling == true)
            case .measure:
                Hint("Esc cancels and restores the display")
                Button("Cancel") { model.back() }.keyboardShortcut(.cancelAction)
            case .review:
                if model.summary?.tone == .critical {
                    Spacer()
                    Button("Reset Display Colours") { model.agent.resetDisplayColours(); model.discard() }
                        .keyboardShortcut(.defaultAction)
                } else if model.summary?.canKeep == true {
                    Hint("Hold Space to see the original")
                    Button("Discard") { model.discard() }.keyboardShortcut(.cancelAction)
                    Button("Keep Correction") { model.keep() }.keyboardShortcut(.defaultAction)
                } else {
                    Spacer()
                    if model.summary?.canRetry == true { Button("Try Again") { model.tryAgain() } }
                    Button("Done") { model.discard() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .controlSize(.large)
    }
}

// MARK: Steps

private struct PrepareStep: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        Text("Calibrate a display").font(.title2.weight(.semibold))
        Picker("Display", selection: $model.selectedID) {
            ForEach(model.displays) { display in
                Text("\(display.name) — \(display.width) × \(display.height) · \(Int(display.refreshRate.rounded())) Hz\(display.isBuiltin ? " · built-in" : "")")
                    .tag(Optional(display.id))
            }
        }
        .onChange(of: model.selectedID) { model.readMonitorSettings() }
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                Text("Monitor controls").foregroundStyle(.secondary)
                Text(model.monitorSettings.isEmpty
                     ? "Not readable over DDC — D65 can’t warn if contrast changes later"
                     : MCCS.guardedSettings.compactMap { setting in
                         model.monitorSettings[setting.name].map { value in
                             setting.code == MCCS.colorPreset
                                 ? "preset \(MCCS.presetName(value) ?? String(value))"
                                 : "\(MCCS.name(of: setting.code).lowercased()) \(value)"
                         }
                     }.joined(separator: ", "))
            }
            GridRow { Text("Takes").foregroundStyle(.secondary); Text("About 40 seconds") }
        }
        .font(.callout).monospacedDigit()
        VStack(alignment: .leading, spacing: 8) {
            Guide("Dim the room. Strong ambient light makes the blue patch unmeasurable.")
            Guide("Leave contrast and the picture preset as they are. D65 records them, and changing either later makes the correction stale.")
            Guide("You’ll press the iPhone face-down against the screen, inside an outline. Its own screen goes dark while it measures.")
        }
        VStack(alignment: .leading, spacing: 6) {
            Picker("Colour difference", selection: $model.metric) {
                Text("CIEDE2000").tag(WhiteErrorMetric.ciede2000)
                Text("CAM16-UCS").tag(WhiteErrorMetric.cam16ucs)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Text(model.metric == .ciede2000
                 ? "Scores the white against D65 for the quality gate and the stopping rule. Review shows both metrics."
                 : "CAM16-UCS, viewed adapted to D65. The gate keeps its thresholds, which were chosen on CIEDE2000; Review shows both metrics.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        WhiteTargetSection(model: model)
        Toggle("Measure only, without correcting", isOn: $model.measureOnly)
    }
}

private struct ConnectStep: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        Text("Open D65 Probe on your iPhone").font(.title2.weight(.semibold))
        Text("Your Mac is advertising on the local network as “D65”. The iPhone connects as soon as the app is open.")
            .foregroundStyle(.secondary)
        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Waiting for the probe…") }
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let since = model.waitingSince, context.date.timeIntervalSince(since) > 15 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Still looking. Check these on the iPhone:").font(.headline)
                    Guide("D65 Probe is open and in the foreground.")
                    Guide("Both devices are on the same Wi-Fi network.")
                    Guide("Settings → Privacy & Security → Local Network allows D65 Probe.")
                    Guide("If the app won’t open, its 7-day development signature has expired. Run it again from Xcode.")
                }
                .card()
            }
        }
    }
}

private struct PlaceStep: View {
    @ObservedObject var model: SessionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Text("Place the phone on the outline").font(.title2.weight(.semibold))
        Text("Press the front of the iPhone flat against \(model.selected?.name ?? "the display"), inside the outline, top edge up. Measuring starts when the readings settle.")
            .foregroundStyle(.secondary)
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow { Text("Probe").foregroundStyle(.secondary); Text(model.probe.map { "\($0.model) · \($0.build)" } ?? "–") }
            GridRow {
                Text("Reading").foregroundStyle(.secondary)
                Text(model.placement.luminance.map { String(format: "Y %.1f", $0) } ?? "No reading yet")
            }
        }
        .font(.callout).monospacedDigit()
        if let alignment = model.placement.alignment {
            Text(alignment.summary).font(.callout.monospacedDigit())
            Text(alignment.blocksColourSampling
                ? "Depth alignment is advisory. Finish it on the iPhone before measuring."
                : "Depth camera off; finish placement by contact.")
                .font(.caption).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: model.placement.steadyFraction)
                .animation(Motion.follow(reduceMotion), value: model.placement.steadyFraction)
                .tint(model.placement.state == .settled ? Theme.ok : .secondary)
            Text(placementText).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
    private var placementText: String {
        if model.placement.alignment?.blocksColourSampling == true { return "Waiting for depth alignment to finish" }
        return descriptionForPlacement
    }
    private var descriptionForPlacement: String {
        switch model.placement.state {
        case .waiting: return "Waiting for the first reading"
        case .tooDark: return "Too dark — the sensor, at the top edge, must sit inside the outline"
        case .moving: return "Hold the phone still"
        case .settling: return String(format: "Steady for %.1f of 1.5 s", model.placement.steadyFraction * 1.5)
        case .settled: return "Steady — starting"
        }
    }
}

private struct MeasureStep: View {
    @ObservedObject var model: SessionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Text(title).font(.title2.weight(.semibold)).monospacedDigit()
            .contentTransition(.numericText())
            .animation(Motion.change(reduceMotion), value: title)
        PatchStrip(current: model.patchIndex).animation(Motion.change(reduceMotion), value: model.patchIndex)
        if !model.passes.isEmpty || model.verifyingPass != nil {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow { Text("Pass"); Text("White"); Text(model.metric.label) }.foregroundStyle(.secondary)
                ForEach(model.passes, id: \.number) { pass in
                    GridRow {
                        Text("\(pass.number)")
                        Text(Format.cct(pass.measured.chromaticity?.correlatedColorTemperature()))
                        Text(String(format: "%.2f", pass.deltaE))
                    }
                }
                if let pass = model.verifyingPass {
                    GridRow { Text("\(pass)"); HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("measuring white…") }; Text("") }
                }
            }
            .font(.callout).monospacedDigit()
            .card()
        }
        Text(model.patchIndex < model.patchCount
             ? "About \(model.secondsRemaining) s left. Keep the phone still; readings taken while it moves are discarded."
             : "Applying the correction and measuring white again.")
            .font(.callout).foregroundStyle(.secondary)
    }
    private var title: String {
        if let pass = model.verifyingPass { return "Correcting · pass \(pass) of up to 3" }
        if model.patchIndex >= model.patchCount { return "Correcting" }
        return "Measuring · \(model.patchIndex + 1) of \(model.patchCount) · \(model.phase)"
    }
}

private struct ReviewStep: View {
    @ObservedObject var model: SessionModel
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The trajectory draws and the ΔE counts down together, once, when Review appears.
    @State private var reveal = 0.0
    var body: some View {
        if let summary = model.summary, let record = model.record {
            Banner(tone: summary.toneKind, title: summary.title,
                   detail: summary.canKeep ? "Now showing on \(record.display.name). " + summary.detail : summary.detail)
            if let saveError = model.saveError {
                Banner(tone: .warning, title: "The session record couldn’t be saved", detail: saveError)
            }
            let trajectory = record.whiteTrajectory
            if trajectory.count > 0, summary.tone != .critical {
                HStack(alignment: .top, spacing: 14) {
                    ChromaticityPlot(points: trajectory, metric: record.configuration.metric, reveal: reveal)
                        .frame(width: 220, height: 220)
                        .onAppear {
                            guard !reduceMotion else { reveal = 1; return }
                            // One 700 ms ease per pass, so each measured step reads as its own move.
                            withAnimation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.7 * Double(max(trajectory.count - 1, 1)))) { reveal = 1 }
                        }
                    VStack(alignment: .leading, spacing: 8) {
                        if let before = record.baselineDeltaE, let best = record.bestDeltaE, record.bestGains?.isIdentity == false {
                            CountingFigure(label: "\(record.configuration.metric.label) to D65\(record.viewerObserver.map { " (\($0.rawValue))" } ?? "")",
                                           before: before, after: before + (best - before) * reveal)
                        } else {
                            Figure(label: "\(record.configuration.metric.label) to D65\(record.viewerObserver.map { " (\($0.rawValue))" } ?? "")",
                                   before: Format.deltaE(record.baselineDeltaE),
                                   after: record.bestGains?.isIdentity == false ? Format.deltaE(record.bestDeltaE) : nil)
                        }
                        Figure(label: "White (approx.)", before: Format.cct(trajectory.first?.correlatedColorTemperature()),
                               after: trajectory.count > 1 ? Format.cct(bestChromaticity(record)?.correlatedColorTemperature()) : nil)
                        if let gains = record.bestGains, !gains.isIdentity {
                            Figure(label: "Brightness", before: nil,
                                   after: String(format: "%+.0f %%", (gains.luminanceScale - 1) * 100))
                        }
                        Text("Measured in this session with the phone in place. Absolute kelvin from this sensor is approximate.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let suggestion = summary.suggestion { Guide(suggestion) }
            DisclosureGroup("Details") {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    if let gains = record.bestGains {
                        GridRow { Text("Gains").foregroundStyle(.secondary); Text(String(format: "R %.3f  G %.3f  B %.3f", gains.r, gains.g, gains.b)) }
                    }
                    GridRow { Text("Gamma (fitted)").foregroundStyle(.secondary); Text(String(format: "%.2f", record.gamma)) }
                    GridRow { Text("Outcome").foregroundStyle(.secondary); Text("\(record.outcome.rawValue) — \(record.terminationReason)") }
                    GridRow { Text("Metric").foregroundStyle(.secondary); Text(record.whiteErrorMetric) }
                    GridRow { Text("Observer").foregroundStyle(.secondary); Text((record.observer ?? .cie1931TwoDegree).rawValue) }
                    if let viewer = record.viewerObserver, let target = record.whiteTarget {
                        GridRow {
                            Text("Target").foregroundStyle(.secondary)
                            Text(String(format: "D65 for %@ = x %.5f y %.5f measured (%@)", viewer.rawValue, target.x, target.y,
                                        record.primarySpectraSource ?? "spectra"))
                        }
                    }
                    ForEach(record.metricReports ?? [], id: \.metric) { report in
                        GridRow {
                            Text(report.metric.label).foregroundStyle(.secondary)
                            Text(String(format: "%.2f → %.2f", report.baseline, report.best))
                        }
                    }
                    GridRow {
                        Text("Record").foregroundStyle(.secondary)
                        Button(record.id.uuidString.prefix(8) + "….json") {
                            NSWorkspace.shared.activateFileViewerSelecting([model.agent.recordDirectory.appendingPathComponent(record.id.uuidString + ".json")])
                        }.buttonStyle(.link)
                    }
                }
                .font(.caption).monospacedDigit().textSelection(.enabled).padding(.top, 4)
            }
            .font(.callout)
            Color.clear.frame(height: 0)
                .focusable().focused($focused).focusEffectDisabled()
                .onAppear { focused = summary.canKeep }
                .onKeyPress(.space, phases: [.down, .up]) { press in
                    guard summary.canKeep else { return .ignored }
                    model.comparing = press.phase == .down
                    return .handled
                }
        }
    }
    private func bestChromaticity(_ record: ExperimentRecord) -> Chromaticity? {
        record.passes.min { $0.deltaE < $1.deltaE }?.measured.chromaticity
    }
}

/// Who should see D65, and the display spectra that make a non-1931 viewer possible.
private struct WhiteTargetSection: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("White target", selection: $model.viewer) {
                ForEach(Observer.allCases, id: \.self) { observer in
                    Text("D65 for \(observer.rawValue)").tag(observer)
                }
            }
            .fixedSize()
            HStack(spacing: 8) {
                if let spectra = model.spectra {
                    Text("Primary spectra: \(spectra.source) · \(Int(spectra.range.lowerBound))–\(Int(spectra.range.upperBound)) nm")
                    Button("Remove") { model.removeSpectra() }.buttonStyle(.link)
                } else {
                    Text("No primary spectra for this display")
                }
                Button("Import…") { pickFile() }
            }
            .font(.callout).foregroundStyle(.secondary)
            if let error = model.spectraError {
                Text(error).font(.caption).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
            } else if model.viewer != .cie1931TwoDegree {
                if let target = model.whiteTarget {
                    Text(String(format: "On this display, D65 for %@ is x %.4f y %.4f to the iPhone’s CIE 1931 sensor, ΔE00 %.1f from standard D65.",
                                model.viewer.rawValue, target.x, target.y, CalibrationEngine.whiteError(target.xyz())))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Import the display’s primary spectra (CSV of wavelength, red, green, blue from a spectroradiometer) to use this target.")
                        .font(.caption).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.message = "Choose a CSV of wavelength, red, green, blue measured on full-drive primary patches."
        if panel.runModal() == .OK, let url = panel.url { model.importSpectra(from: url) }
    }
}

// MARK: Components

private struct StepBar: View {
    let current: SessionModel.Step
    var body: some View {
        HStack(spacing: 14) {
            ForEach(SessionModel.Step.allCases, id: \.rawValue) { step in
                HStack(spacing: 5) {
                    ZStack {
                        Circle().fill(step.rawValue <= current.rawValue ? Color.primary.opacity(step == current ? 1 : 0.45) : .clear)
                        Circle().strokeBorder(step.rawValue <= current.rawValue ? Color.clear : Theme.rule)
                        if step.rawValue < current.rawValue { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.surface) }
                        else { Text("\(step.rawValue + 1)").font(.system(size: 9, weight: .semibold)).foregroundStyle(step == current ? Theme.surface : .secondary) }
                    }
                    .frame(width: 16, height: 16)
                    Text(step.title).font(.caption.weight(step == current ? .semibold : .regular))
                        .foregroundStyle(step == current ? .primary : .secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current.rawValue + 1) of 5, \(current.title)")
    }
}

struct PatchStrip: View {
    let current: Int
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(CalibrationPatch.sequence.enumerated()), id: \.offset) { index, patch in
                RoundedRectangle(cornerRadius: 3)
                    .fill(index < current ? Color(.sRGB, red: patch.red, green: patch.green, blue: patch.blue) : Color.clear)
                    .scaleEffect(index < current ? 1 : 0.82)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(index == current ? Color.primary : Theme.rule,
                                                                            lineWidth: index == current ? 2 : 1))
                    .aspectRatio(1, contentMode: .fit)
                    .help(patch.name)
            }
        }
        .accessibilityHidden(true)
    }
}

struct Banner: View {
    let tone: ToneKind
    let title: String
    var detail: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(Theme.tone(tone))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(Theme.tone(tone))
                if let detail { Text(detail).font(.callout).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.tone(tone).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
    private var icon: String {
        switch tone {
        case .success: "checkmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        }
    }
}

/// The before value and an after value that counts down as the Review trajectory draws.
private struct CountingFigure: View {
    let label: String
    let before: Double
    let after: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(Format.deltaE(before) + " →").foregroundStyle(.secondary)
                CountingText(value: after)
            }
            .font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct Figure: View {
    let label: String
    let before: String?
    let after: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                if let before { Text(after == nil ? before : before + " →").foregroundStyle(after == nil ? .primary : .secondary) }
                if let after { Text(after) }
            }
            .font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct Guide: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(.secondary).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary); Spacer() }
}

extension SessionSummary {
    var toneKind: ToneKind {
        switch tone {
        case .success: .success
        case .partial: .partial
        case .info: .info
        case .warning: .warning
        case .critical: .critical
        }
    }
}
