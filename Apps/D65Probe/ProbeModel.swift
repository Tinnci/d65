import D65Core
import D65Link
import D65Measurement
import D65ProbeSupport
import SwiftUI
import UIKit

/// The probe's whole UI state. The phone is face-down while it works, so the states before and after
/// matter most, and haptics carry the moments in between.
@MainActor final class ProbeModel: ObservableObject {
    enum Phase: Equatable {
        case noSensor
        case searching
        case localNetworkOff(String)
        case ready
        case placing
        case measuring(phase: String, fraction: Double?)
        case result(verdict: CalibrationVerdict, before: Double, after: Double)
        case refused(String)
        case failed(String)
        case cancelled
        case measurementComplete
    }

    @Published private(set) var phase: Phase = .searching
    @Published private(set) var sensorName = "No sensor"
    @Published private(set) var isSimulated = false
    @Published private(set) var lastReading: Double?
    @Published private(set) var alignmentReading: DepthAlignmentReading?
    /// TrueDepth approach guide. Off by default: it doesn't change the measurement (taken flat on the
    /// glass), switches on an infrared emitter next to the light sensor, and holds the Mac's start.
    @Published var approachGuide = UserDefaults.standard.bool(forKey: "probeApproachGuide") {
        didSet {
            UserDefaults.standard.set(approachGuide, forKey: "probeApproachGuide")
            if !approachGuide { alignment.stop() }
        }
    }
    @Published var showingSettings = false
    /// The first-run guide; also reachable from Settings.
    @Published var showingGuide = false
    var guideStartPage = 0
    static var hasSeenGuide: Bool {
        get { UserDefaults.standard.bool(forKey: "probeGuideSeen") }
        set { UserDefaults.standard.set(newValue, forKey: "probeGuideSeen") }
    }

    /// The link starts only after the guide, so the Local Network prompt follows its explanation.
    func finishGuide() {
        #if DEBUG
        if demo { showingGuide = false; runDemoSession(); return }
        #endif
        Self.hasSeenGuide = true
        showingGuide = false
        start()
    }

    /// Seconds per guide page when the guide pages itself; only the Debug demo sets it.
    var autoAdvance: Double? {
        #if DEBUG
        demo ? 3.4 : nil
        #else
        nil
        #endif
    }

    func showGuide() {
        showingSettings = false
        guideStartPage = 0
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450)) // let the settings sheet leave first
            showingGuide = true
        }
    }
    @Published var hapticStrength: ProbeHapticStrength {
        didSet {
            guard hapticStrength != oldValue else { return }
            UserDefaults.standard.set(hapticStrength.rawValue, forKey: "probeHapticStrength")
            haptics.setStrength(hapticStrength)
        }
    }

    private let link = LinkClient()
    private let stillness = StillnessMonitor()
    private let alignment = TrueDepthAlignmentAssist()
    private var sensor: ProbeSensor?
    private let haptics: ProbeHaptics

    init() {
        let strength = UserDefaults.standard.string(forKey: "probeHapticStrength").flatMap(ProbeHapticStrength.init(rawValue:)) ?? .subtle
        hapticStrength = strength
        haptics = ProbeHaptics(strength: strength)
    }
    func previewHaptics() { haptics.preview() }
    func didBecomeActive() { haptics.setActive(true) }

    func start() {
        guard self.sensor == nil else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        haptics.setActive(true)
        alignment.onReading = { [weak self] reading in
            self?.haptics.alignment(reading)
            self?.alignmentReading = reading
            self?.link.sendAlignment(reading)
        }
        guard let sensor = SensorRegistry.make() else { phase = .noSensor; haptics.play(.refused); return }
        self.sensor = sensor
        sensorName = sensor.name; isSimulated = sensor.isSimulated
        stillness.start()
        link.onEvent = { [weak self] in self?.handle($0) }
        sensor.start { [weak self] sample in
            guard let self else { return }
            self.lastReading = sample.xyz.y
            self.link.sendSample(sample, stable: self.stillness.isStable && self.alignment.permitsColourSamples && self.haptics.permitsColourSamples)
        }
        link.start()
    }

    /// Leaving the foreground must never leave the screen at 1 % brightness.
    func didLeaveForeground() { haptics.setActive(false); link.restoreBrightness() }

    func didEnterBackground() { alignment.stop() }

    func startAlignment() {
        guard approachGuide else { return }
        switch phase {
        case .searching, .ready, .placing: alignment.start()
        default: break
        }
    }
    func finishAlignment() { alignment.stop() }

    func stop() {
        haptics.stop()
        alignment.stop()
        sensor?.stop(); stillness.stop(); link.stop()
        sensor = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func handle(_ event: LinkEvent) {
        switch event {
        case .searching: if !isTerminal { phase = .searching }
        case .browseFailed(let text):
            if phase != .localNetworkOff(text) { haptics.play(.refused) }
            phase = .localNetworkOff(text)
        case .connected: phase = .ready; haptics.connectionOpened()
        case .disconnected: alignment.stop(); haptics.connectionClosed(); phase = .searching
        case .placementStarted:
            phase = .placing; haptics.placementStarted()
            if let alignmentReading { link.sendAlignment(alignmentReading) }
        case .placementEnded:
            alignment.stop()
            if phase == .placing { phase = .ready }
        case .measuring(let name, let fraction):
            alignment.stop()
            haptics.progress(name)
            phase = .measuring(phase: name, fraction: fraction)
        case .sampleWindowOpened(let request):
            haptics.windowOpened(request)
        case .sampleWindowClosed(let request):
            haptics.windowClosed(request)
        case .result(let verdict, let before, let after):
            phase = .result(verdict: verdict, before: before, after: after)
            haptics.completed(verdict == .rejected ? .rejected : (verdict == .confirmed ? .confirmed : .success))
        case .sessionEnded:
            haptics.sessionEnded()
            alignment.stop()
            if case .measuring = phase { phase = .ready }
            if phase == .placing { phase = .ready }
        case .failure(let code, let message):
            alignment.stop()
            switch LinkFailure(rawValue: code) {
            case .cancelled:
                phase = .cancelled; haptics.completed(.cancelled)
            case .measurementComplete:
                phase = .measurementComplete; haptics.completed(.measurementComplete)
            case .busy, .incompatible:
                phase = .refused(message); haptics.completed(.refused)
            default:
                phase = .failed(message); haptics.completed(.failure)
            }
        }
    }

    private var isTerminal: Bool {
        switch phase { case .refused, .noSensor: true; default: false }
    }

    #if DEBUG
    /// Plays the start cue at each strength, two seconds apart, logging each to the console.
    func hapticCheck() {
        let saved = hapticStrength
        Task { @MainActor in
            for strength in [ProbeHapticStrength.subtle, .clear] {
                hapticStrength = strength
                try? await Task.sleep(for: .seconds(2))
                previewHaptics()
            }
            try? await Task.sleep(for: .seconds(1))
            hapticStrength = saved
        }
    }

    /// A scripted walk for README recordings (`-demo [guide|session]`): the guide pages itself, then a
    /// session runs through its screens on fixed timings. No sensor, link or gamma table is touched.
    private(set) var demo = false
    private var demoSession = true
    func startDemo(guide: Bool, session: Bool) {
        demo = true; demoSession = session; guideStartPage = 0; phase = .searching
        if guide { showingGuide = true } else { runDemoSession() }
    }
    private func runDemoSession() {
        guard demoSession else { return }
        Task { @MainActor in
            func hold(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            phase = .searching; await hold(3.4)
            phase = .ready; await hold(2)
            phase = .placing; await hold(2.4)
            let patches = ["black", "white", "red", "green", "blue", "grey 1", "grey 2", "grey 3", "grey 4", "pass 1", "pass 2", "pass 3"]
            for (index, name) in patches.enumerated() {
                phase = .measuring(phase: name, fraction: Double(index + 1) / Double(patches.count)); await hold(0.32)
            }
            phase = .result(verdict: .improved, before: 4.18, after: 1.69)
        }
    }

    /// Debug-only screenshot states: launch with `-showcase <searching|ready|placing|measuring|result|settings>`.
    func showcase(_ name: String) {
        switch name {
        case "ready", "settings": phase = .ready
        case "placing": phase = .placing
        case "measuring": phase = .measuring(phase: "blue", fraction: 4.0 / 12)
        case "result": phase = .result(verdict: .improved, before: 4.18, after: 1.69)
        default: phase = .searching
        }
        if name.hasPrefix("guide"), let page = Int(name.dropFirst(5)) {
            guideStartPage = page - 1; showingGuide = true
        }
        showingSettings = name == "settings"
    }
    #endif

    /// Results stay until the Mac starts the next placement.
    func dismissResult() { haptics.play(.selection); phase = link.isConnected ? .ready : .searching }
}
