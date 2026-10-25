import D65Core
import D65Link
import SwiftUI

@main
struct D65ProbeApp: App {
    @StateObject private var model = ProbeModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ProbeView(model: model)
                .onAppear { model.start() }
                .onChange(of: scenePhase) { _, phase in if phase != .active { model.didLeaveForeground() } }
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

struct ProbeView: View {
    @ObservedObject var model: ProbeModel

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                content.frame(maxWidth: 340).padding(.horizontal, 28)
                Spacer()
                footer.padding(.bottom, 12)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.phase)
        .tint(ProbeTheme.accent)
    }

    /// While sampling, the screen faces the monitor at 1 % brightness: render (almost) nothing.
    private var faceDown: Bool {
        switch model.phase { case .placing, .measuring: true; default: false }
    }

    private var background: Color { faceDown ? .black : Color(.systemBackground) }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .noSensor:
            Message(mark: .critical, title: "No light sensor in this build",
                    text: "D65 Probe needs a sensor source. The private ambient-light reader lives in local/als-probe and is compiled in only on your own machine.")
        case .searching:
            Message(mark: .none, title: "Looking for your Mac…",
                    text: "Open Calibrate Display… on the Mac. Both devices must be on the same Wi-Fi.", busy: true)
        case .localNetworkOff(let text):
            Message(mark: .critical, title: "Local Network is off", text: text + " Turn it on to find your Mac.") {
                Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                    .buttonStyle(.borderedProminent)
            }
        case .ready:
            Message(mark: .held, title: "Connected to D65",
                    text: "When the Mac shows the outline, press this phone face-down inside it, top edge up. You’ll feel a tap when measuring starts.")
        case .placing:
            DimMessage(title: "Face-down on the outline", text: "Hold still")
        case .measuring(let phase, let fraction):
            DimMessage(title: "Measuring \(phase)", text: fraction.map { "\(Int($0 * 100)) %" } ?? "Keep still")
        case .result(let verdict, let before, let after):
            Message(mark: verdict == .rejected ? .stale : .held, title: title(for: verdict),
                    text: verdict == .improved
                        ? String(format: "ΔE00 %.1f → %.1f. Keep or discard it on your Mac.", before, after)
                        : verdict == .confirmed ? "Your display was already close to D65." : "See your Mac for the reason.") {
                Button("OK") { model.dismissResult() }.buttonStyle(.bordered)
            }
        case .refused(let text):
            Message(mark: .critical, title: "The Mac refused this probe", text: text)
        case .failed(let text):
            Message(mark: .stale, title: "Session stopped", text: text) {
                Button("OK") { model.dismissResult() }.buttonStyle(.bordered)
            }
        }
    }

    private func title(for verdict: CalibrationVerdict) -> String {
        switch verdict { case .improved: "Done"; case .confirmed: "Already good"; case .rejected: "No change" }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if model.isSimulated { Image(systemName: "exclamationmark.triangle") }
            Text("\(model.sensorName) · protocol v\(Link.protocolVersion)")
            if let y = model.lastReading, !faceDown { Text(String(format: "· Y %.0f", y)).monospacedDigit() }
        }
        .font(.caption2)
        .foregroundStyle(faceDown ? Color(white: 0.18) : (model.isSimulated ? ProbeTheme.warn : .secondary))
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
            ProbeMark(mode: mark).frame(width: 56, height: 56)
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
