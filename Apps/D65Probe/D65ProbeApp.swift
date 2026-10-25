import D65Core
import D65Link
import D65ProbeSupport
import SwiftUI

@main
struct D65ProbeApp: App {
    @StateObject private var model = ProbeModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ProbeView(model: model)
                .onAppear {
                    #if DEBUG
                    let arguments = ProcessInfo.processInfo.arguments
                    if let index = arguments.firstIndex(of: "-showcase"), index + 1 < arguments.count {
                        model.showcase(arguments[index + 1]); return
                    }
                    #endif
                    if ProbeModel.hasSeenGuide { model.start() } else { model.showingGuide = true }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.didBecomeActive() } else { model.didLeaveForeground() }
                    if phase == .background { model.didEnterBackground() }
                }
                .onDisappear { model.stop() }
        }
    }
}

/// Same visual language as the Mac: neutral surfaces, one accent, the ring-and-dot mark.
enum ProbeTheme {
    static let accent = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.55, green: 0.71, blue: 0.93, alpha: 1) : UIColor(red: 0.12, green: 0.34, blue: 0.66, alpha: 1) })
    static let ok = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.42, green: 0.78, blue: 0.56, alpha: 1) : UIColor(red: 0.17, green: 0.48, blue: 0.29, alpha: 1) })
    static let warn = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.89, green: 0.66, blue: 0.28, alpha: 1) : UIColor(red: 0.60, green: 0.36, blue: 0.0, alpha: 1) })
}

/// The same motion vocabulary as the Mac app and the guide: a 700 ms (.32, .72, 0, 1) ease for a
/// discrete change, a k100/c18 spring for anything following live input, nothing under Reduce Motion.
enum Motion {
    static func change(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .timingCurve(0.32, 0.72, 0, 1, duration: 0.7)
    }
    static func follow(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .interpolatingSpring(mass: 1, stiffness: 100, damping: 18)
    }
}

struct ProbeView: View {
    @ObservedObject var model: ProbeModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Spacer(minLength: 24)
                // A new state arrives with the discrete-change ease; progress inside a state doesn't re-run it.
                content.frame(maxWidth: 340).padding(.horizontal, 28)
                    .id(phaseKey)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12)), removal: .opacity))
                Spacer(minLength: 24)
                if !faceDown {
                    StepStrip(current: step).padding(.horizontal, 28)
                    if model.isSimulated { simulatedWarning.padding(.top, 14) }
                }
            }
            .padding(.bottom, 16)
        }
        .animation(Motion.change(reduceMotion), value: phaseKey)
        .tint(ProbeTheme.accent)
        .sheet(isPresented: $model.showingSettings) { ProbeSettings(model: model) }
        .fullScreenCover(isPresented: $model.showingGuide) {
            OnboardingView(startPage: model.guideStartPage) { model.finishGuide() }
        }
    }

    /// While sampling, the screen faces the monitor at 1 % brightness: render (almost) nothing.
    private var faceDown: Bool {
        switch model.phase { case .placing, .measuring: true; default: false }
    }

    private var background: Color { faceDown ? .black : Color(.systemBackground) }

    private var header: some View {
        HStack {
            Text("D65 Probe").font(.headline).foregroundStyle(faceDown ? Color(white: 0.2) : .secondary)
            Spacer()
            if !faceDown {
                Button { model.showingSettings = true } label: {
                    Image(systemName: "gearshape").font(.title3)
                }
                .accessibilityLabel("Settings")
            }
        }
        .padding(.horizontal, 24).padding(.top, 8)
    }

    private var phaseKey: String {
        switch model.phase {
        case .noSensor: "noSensor"
        case .searching: "searching"
        case .localNetworkOff: "localNetworkOff"
        case .ready: "ready"
        case .placing: "placing"
        case .measuring: "measuring"
        case .result: "result"
        case .refused: "refused"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .measurementComplete: "measurementComplete"
        }
    }

    /// Where the session is: 0 connect, 1 place, 2 measure, 3 review on the Mac.
    private var step: Int {
        switch model.phase {
        case .noSensor, .searching, .localNetworkOff, .refused: 0
        case .ready: 1
        case .placing, .measuring: 2
        case .result, .cancelled, .measurementComplete, .failed: 3
        }
    }

    private var tapPromise: String {
        model.hapticStrength == .off ? "" : " You’ll feel a tap when measuring starts."
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .noSensor:
            Message(mark: .critical, title: "No light sensor in this build",
                    text: "D65 Probe needs a sensor source. The private ambient-light reader lives in local/ and is compiled in only on your own machine.")
        case .searching:
            Message(mark: .none, title: "Looking for your Mac…",
                    text: "On the Mac, choose Calibrate Display… in the D65 menu. Both devices need the same Wi-Fi.", busy: true)
        case .localNetworkOff(let text):
            Message(mark: .critical, title: "Local Network is off", text: text + " Turn it on so the probe can find your Mac.") {
                Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                    .buttonStyle(.borderedProminent)
            }
        case .ready:
            Message(mark: .held, title: "Connected",
                    text: "When the Mac shows an outline, press the front of this phone flat inside it, top edge up, and let go of any pressure." + tapPromise) {
                if model.approachGuide { ApproachGuide(model: model, dimmed: false) }
            }
        case .placing:
            VStack(spacing: 16) {
                DimMessage(title: "Face-down on the outline", text: "Hold still")
                if model.approachGuide { ApproachGuide(model: model, dimmed: true) }
            }
        case .measuring(let phase, let fraction):
            DimMessage(title: "Measuring \(phase)", text: fraction.map { "\(Int($0 * 100)) %" } ?? "Keep still")
        case .result(let verdict, let before, let after):
            Message(mark: verdict == .rejected ? .stale : .held, title: title(for: verdict),
                    text: verdict == .improved
                        ? "Review it on your Mac, then keep or discard it."
                        : verdict == .confirmed ? "Your display was already close to D65." : "See your Mac for the reason.") {
                if verdict == .improved {
                    ResultCount(before: before, after: after)
                    Text("ΔE00 to D65").font(.caption).foregroundStyle(.secondary)
                }
                Button("Done") { model.dismissResult() }.buttonStyle(.bordered).padding(.top, 4)
            }
        case .cancelled:
            Message(mark: .none, title: "Session cancelled", text: "Nothing was kept. Start again on your Mac when you’re ready.") {
                Button("Done") { model.dismissResult() }.buttonStyle(.bordered)
            }
        case .measurementComplete:
            Message(mark: .none, title: "Measurement complete", text: "The readings are on your Mac. The display was restored.") {
                Button("Done") { model.dismissResult() }.buttonStyle(.bordered)
            }
        case .refused(let text):
            Message(mark: .critical, title: "The Mac refused this probe", text: text)
        case .failed(let text):
            Message(mark: .stale, title: "Session stopped", text: text) {
                Button("Done") { model.dismissResult() }.buttonStyle(.bordered)
            }
        }
    }

    private func title(for verdict: CalibrationVerdict) -> String {
        switch verdict { case .improved: "Measured and corrected"; case .confirmed: "Already good"; case .rejected: "No change" }
    }

    private var simulatedWarning: some View {
        Label("Simulated sensor: not a real measurement", systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(ProbeTheme.warn)
    }
}

/// Connect, place, measure, then review on the Mac. Shown only while the screen faces the user.
private struct StepStrip: View {
    let current: Int
    @Namespace private var marker
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let titles = ["Connect", "Place", "Measure", "Review on Mac"]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(titles.indices, id: \.self) { index in
                VStack(spacing: 6) {
                    Circle()
                        .fill(index <= current ? Color.primary : Color.clear)
                        .overlay(Circle().strokeBorder(index <= current ? Color.clear : Color.secondary.opacity(0.5), lineWidth: 1.5))
                        .frame(width: 9, height: 9)
                        .background {
                            if index == current {
                                Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
                                    .frame(width: 19, height: 19)
                                    .matchedGeometryEffect(id: "current", in: marker)
                            }
                        }
                    Text(titles[index])
                        .font(.caption2.weight(index == current ? .semibold : .regular))
                        .foregroundStyle(index == current ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .animation(Motion.change(reduceMotion), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of 4, \(titles[current])")
    }
}

/// The optional TrueDepth approach guide: distance and tilt before contact, never during sampling.
private struct ApproachGuide: View {
    @ObservedObject var model: ProbeModel
    let dimmed: Bool
    var body: some View {
        VStack(spacing: 8) {
            if let reading = model.alignmentReading { Text(reading.summary).font(.callout.monospacedDigit()) }
            if model.alignmentReading?.blocksColourSampling == true {
                Button("Turn off depth camera") { model.finishAlignment() }
                    .buttonStyle(.bordered)
                    .disabled(model.alignmentReading?.status == .stopping || model.alignmentReading?.status == .cooldown)
            } else {
                Button("Guide my approach") { model.startAlignment() }.buttonStyle(.bordered)
            }
        }
        .foregroundStyle(dimmed ? Color(white: 0.28) : .secondary)
    }
}

/// Everything that isn't the current instruction: haptics, the approach guide, and the sensor.
private struct ProbeSettings: View {
    @ObservedObject var model: ProbeModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Strength", selection: $model.hapticStrength) {
                        ForEach(ProbeHapticStrength.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Button("Feel the start cue") { model.previewHaptics() }.disabled(model.hapticStrength == .off)
                } header: { Text("Haptics") } footer: {
                    Text("Taps mark the connection, the start of measuring, each verification pass and the result. None play while a reading is being taken.")
                }
                Section {
                    Toggle("TrueDepth approach guide", isOn: $model.approachGuide)
                } header: { Text("Approach guide") } footer: {
                    Text("Shows distance and tilt while you bring the phone to the screen. It doesn’t change the measurement, which is taken with the phone flat on the glass, so it’s off by default. The Mac waits for the depth camera to switch off before it samples.")
                }
                Section("Help") {
                    Button("Show the guide") { model.showGuide() }
                }
                Section("Sensor") {
                    LabeledContent("Source", value: model.sensorName)
                    LabeledContent("Live reading", value: model.lastReading.map { String(format: "Y %.1f", $0) } ?? "–")
                    LabeledContent("Protocol", value: "v\(Link.protocolVersion)")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct Message<Actions: View>: View {
    let mark: ProbeMark.Mode
    let title: String
    let text: String
    var busy = false
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            StatusMark(mode: mark).frame(width: 64, height: 64)
            Text(title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if busy { ProgressView() }
            actions
        }
        .accessibilityElement(children: .combine)
    }
}

extension Message where Actions == EmptyView {
    init(mark: ProbeMark.Mode, title: String, text: String, busy: Bool = false) {
        self.init(mark: mark, title: title, text: text, busy: busy) { EmptyView() }
    }
}

/// Barely visible: the screen is at 1 % brightness and pressed against the monitor.
private struct DimMessage: View {
    let title: String
    let text: String
    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(text).font(.caption).monospacedDigit()
        }
        .foregroundStyle(Color(white: 0.22))
        .accessibilityElement(children: .combine)
    }
}

/// The ring-and-dot mark shared with the Mac.
struct ProbeMark: View {
    enum Mode { case held, stale, none, critical }
    let mode: Mode
    var body: some View {
        Canvas { context, size in
            let r = min(size.width, size.height) / 2 - 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let ring = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            context.stroke(Path(ellipseIn: ring), with: .color(mode == .critical ? ProbeTheme.warn : .secondary), lineWidth: 2.5)
            let d = r * 0.4
            let dot = CGRect(x: c.x - d, y: c.y - d, width: d * 2, height: d * 2)
            switch mode {
            case .held: context.fill(Path(ellipseIn: dot), with: .color(.primary))
            case .stale: context.stroke(Path(ellipseIn: dot), with: .color(ProbeTheme.warn), lineWidth: 2.5)
            case .critical: context.fill(Path(ellipseIn: dot.insetBy(dx: d * 0.4, dy: d * 0.4)), with: .color(ProbeTheme.warn))
            case .none: context.fill(Path(ellipseIn: dot.insetBy(dx: d * 0.45, dy: d * 0.45)), with: .color(.secondary))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The icon's mark as the status: while searching its dot drifts along the locus; when the probe
/// connects or a result is good it settles onto the centre and the ring lights; a stopped session
/// leaves it off-centre. A critical state keeps the plain warning mark.
struct StatusMark: View {
    let mode: ProbeMark.Mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if mode == .critical {
            ProbeMark(mode: .critical)
        } else {
            // One clock, paused unless searching: an ambient drift only while it means "looking".
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: mode != .none || reduceMotion)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                MarkCanvas(held: target(at: t), ink: LineInk(scheme: scheme))
                    .animation(Motion.change(reduceMotion), value: mode)
            }
            .accessibilityHidden(true)
        }
    }

    private func target(at t: Double) -> Double {
        switch mode {
        case .held: 1
        case .stale: 0.45
        default: reduceMotion ? 0.3 : 0.3 + 0.16 * sin(t * 1.1)
        }
    }

    private struct MarkCanvas: View, Animatable {
        var held: Double
        let ink: LineInk
        var animatableData: Double { get { held } set { held = newValue } }
        var body: some View {
            Canvas { context, size in drawFrontMark(context, ink: ink, size: size, held: held, fill: 0.42) }
        }
    }
}

/// ΔE before → after, the after value counting down from the before value when it appears.
private struct ResultCount: View {
    let before: Double, after: Double
    @State private var shown: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 10) {
            Text(String(format: "%.1f", before)).foregroundStyle(.secondary)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Counting(value: shown ?? before)
        }
        .font(.system(size: 34, weight: .semibold).monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: "ΔE from %.1f to %.1f", before, after))
        .onAppear { withAnimation(Motion.change(reduceMotion).map { $0.delay(0.25) }) { shown = after } }
    }
    private struct Counting: View, Animatable {
        var value: Double
        var animatableData: Double { get { value } set { value = newValue } }
        var body: some View { Text(String(format: "%.1f", value)) }
    }
}
