import CoreHaptics
import D65Measurement
import D65ProbeSupport
import Foundation
import UIKit

/// UIKit/Core Haptics adapter. The pure policy decides timing; playback completion releases sampling.
@MainActor final class ProbeHaptics {
    private var policy: ProbeFeedbackPolicy
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private let fallback = UIImpactFeedbackGenerator(style: .soft)
    private var fallbackTask: Task<Void, Never>?
    private var playbackToken: UUID?
    private var lastProgress = ""
    private var windowCount = 0
    private var hasConnected = false
    private var didEndSession = false
    var permitsColourSamples: Bool { policy.permitsColourSample(at: ProcessInfo.processInfo.systemUptime) }

    init(strength: ProbeHapticStrength) { policy = ProbeFeedbackPolicy(strength: strength) }
    func setStrength(_ strength: ProbeHapticStrength) {
        cancelPlayback()
        policy.strength = strength // The native picker supplies its own selection feedback.
    }
    func setActive(_ value: Bool) {
        policy.setActive(value)
        if !value {
            cancelPlayback()
            engine?.stop(completionHandler: nil)
        } else { fallback.prepare() }
    }
    func stop() {
        setActive(false); policy.beginPlacement()
        hasConnected = false; didEndSession = false; lastProgress = ""; windowCount = 0
    }
    func play(_ cue: ProbeHapticCue) {
        if cue.isTerminal { cancelPlayback() }
        if let plan = policy.request(cue, at: now) { render(plan) }
    }
    func connectionOpened() {
        guard !hasConnected else { return }
        hasConnected = true; didEndSession = false
        play(.connected)
    }
    func connectionClosed() {
        policy.endWindows()
        guard hasConnected else { return }
        hasConnected = false
        cancelPlayback()
        if !didEndSession { play(.disconnected) }
    }
    func placementStarted() {
        policy.beginPlacement()
        windowCount = 0; lastProgress = ""; didEndSession = false
        play(.placement)
    }
    func progress(_ phase: String) { lastProgress = phase }
    func windowOpened(_ request: MeasurementRequest) {
        if let plan = policy.openWindow(id: request.patchID, first: windowCount == 0,
            verification: lastProgress.hasPrefix("pass "), settlingSeconds: request.settlingSeconds, at: now) {
            render(plan)
        }
        windowCount += 1
    }
    func windowClosed(_ request: MeasurementRequest) { policy.closeWindow(id: request.patchID) }
    func completed(_ cue: ProbeHapticCue) {
        policy.endWindows(); didEndSession = true
        play(cue)
    }
    func sessionEnded() {
        policy.endWindows()
        if !didEndSession { play(.cancelled) }
        didEndSession = true
    }
    func alignment(_ reading: DepthAlignmentReading) {
        if reading.status == .starting { didEndSession = false }
        guard !didEndSession else { return }
        if let plan = policy.alignment(reading, at: now) { render(plan) }
    }
    func preview() { play(.measurementStarted) }
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    private func render(_ plan: ProbeHapticPlan) {
        let token = UUID()
        playbackToken = token
        policy.playbackBegan()
        do {
            let engine = try hapticEngine()
            try engine.start()
            let events = plan.pulses.map {
                CHHapticEvent(eventType: .hapticTransient, parameters: [
                    .init(parameterID: .hapticIntensity, value: Float($0.intensity)),
                    .init(parameterID: .hapticSharpness, value: Float($0.sharpness))
                ], relativeTime: $0.time)
            }
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            self.player = player
            player.completionHandler = { [weak self] _ in
                Task { @MainActor in self?.finished(token) }
            }
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            player = nil
            // UIKit fallback retains the quiet timings and mild intensity instead of a full alert.
            fallback.prepare()
            fallbackTask = Task { @MainActor [weak self] in
                let start = ProcessInfo.processInfo.systemUptime
                for pulse in plan.pulses {
                    let delay = pulse.time - (ProcessInfo.processInfo.systemUptime - start)
                    if delay > 0 {
                        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    }
                    guard let self, self.playbackToken == token, !Task.isCancelled else { return }
                    self.fallback.impactOccurred(intensity: CGFloat(pulse.intensity))
                }
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                self?.finished(token)
            }
        }
    }
    private func finished(_ token: UUID) {
        guard playbackToken == token else { return }
        playbackToken = nil; player = nil; fallbackTask = nil
        policy.playbackEnded(at: now)
    }
    private func cancelPlayback() {
        guard playbackToken != nil else { return }
        // Invalidate queued callbacks before stopping: an old completion cannot release a new cue.
        playbackToken = nil
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        fallbackTask?.cancel(); fallbackTask = nil
        // A UIKit transient cannot be recalled once issued; allow its conservative 80 ms tail.
        policy.playbackEnded(at: now + 0.08)
    }
    private func hapticEngine() throws -> CHHapticEngine {
        if let engine { return engine }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { throw HapticError.unsupported }
        let engine = try CHHapticEngine()
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = true
        engine.resetHandler = { [weak self, weak engine] in
            Task { @MainActor in
                guard let self, let engine, self.engine === engine else { return }
                self.cancelPlayback(); self.engine = nil
            }
        }
        engine.stoppedHandler = { [weak self, weak engine] _ in
            Task { @MainActor in
                guard let self, let engine, self.engine === engine else { return }
                self.cancelPlayback()
            }
        }
        self.engine = engine
        return engine
    }
    private enum HapticError: Error { case unsupported }
}
