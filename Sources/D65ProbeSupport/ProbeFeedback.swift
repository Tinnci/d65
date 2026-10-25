import D65Measurement
import Foundation

public enum ProbeHapticStrength: String, CaseIterable, Sendable {
    case off, subtle, clear
    public var label: String {
        switch self { case .off: "Off"; case .subtle: "Subtle"; case .clear: "Clear" }
    }
    var multiplier: Double { self == .off ? 0 : (self == .subtle ? 1 : 1.6) }
}

/// Discrete events, not a continuous distance/motion signal.
public enum ProbeHapticCue: Sendable, Hashable, CaseIterable {
    case connected, disconnected, placement
    case alignmentStarted, surfaceFound, surfaceLevel, alignmentNear, alignmentFinished, alignmentUnavailable
    case measurementStarted, patch, verification
    case success, confirmed, measurementComplete, rejected, failure, refused, cancelled, selection

    public var isTerminal: Bool {
        switch self { case .success, .confirmed, .measurementComplete, .rejected, .failure, .refused, .cancelled: true; default: false }
    }
    public func plan(strength: ProbeHapticStrength) -> ProbeHapticPlan {
        let values: [(Double, Double, Double)]
        switch self {
        case .connected: values = [(0, 0.08, 0.2), (0.075, 0.13, 0.25)]
        case .disconnected: values = [(0, 0.13, 0.2), (0.14, 0.08, 0.15)]
        case .placement: values = [(0, 0.09, 0.2)]
        case .alignmentStarted: values = [(0, 0.06, 0.15)]
        case .surfaceFound: values = [(0, 0.065, 0.12)]
        case .surfaceLevel: values = [(0, 0.07, 0.15), (0.055, 0.09, 0.2)]
        case .alignmentNear: values = [(0, 0.085, 0.2)]
        case .alignmentFinished: values = [(0, 0.12, 0.25)]
        case .alignmentUnavailable: values = [(0, 0.10, 0.12)]
        case .measurementStarted: values = [(0, 0.12, 0.22), (0.065, 0.14, 0.28)]
        case .patch: values = [(0, 0.045, 0.12)]
        case .verification: values = [(0, 0.08, 0.20), (0.055, 0.08, 0.20)]
        case .success: values = [(0, 0.16, 0.3), (0.11, 0.12, 0.22)]
        case .confirmed: values = [(0, 0.11, 0.22), (0.075, 0.11, 0.22)]
        case .measurementComplete: values = [(0, 0.10, 0.16)]
        case .rejected, .refused: values = [(0, 0.12, 0.18), (0.15, 0.08, 0.12)]
        case .failure: values = [(0, 0.14, 0.20), (0.10, 0.10, 0.16), (0.22, 0.08, 0.12)]
        case .cancelled: values = [(0, 0.08, 0.12)]
        case .selection: values = [(0, 0.055, 0.18)]
        }
        return ProbeHapticPlan(cue: self, pulses: values.map {
            .init(time: $0.0, intensity: $0.1 * strength.multiplier, sharpness: $0.2)
        })
    }
}

public struct ProbeHapticPlan: Sendable, Equatable {
    public struct Pulse: Sendable, Equatable {
        public let time: Double, intensity: Double, sharpness: Double
    }
    public let cue: ProbeHapticCue
    public let pulses: [Pulse]
    /// Conservative tail for transient playback, including the UIKit fallback.
    public var duration: Double { (pulses.last?.time ?? 0) + 0.08 }
}

/// Testable haptic timing/measurement policy. Times are monotonic seconds supplied by the adapter.
public struct ProbeFeedbackPolicy: Sendable {
    public var strength: ProbeHapticStrength
    public private(set) var active = true
    public private(set) var playbackInFlight = false
    private var quietUntil = -Double.infinity
    private var lastCueTime = -Double.infinity
    private var cueTimes: [ProbeHapticCue: Double] = [:]
    private var window: UUID?
    private var seenWindows: Set<UUID> = []
    private var terminalSent = false
    private var connectivityAlerted = false
    private var alignmentActive = false
    private var reliableSince: Double?
    private var levelSince: Double?
    private var nearSince: Double?
    private var missingSince: Double?
    private var alignmentCues: Set<ProbeHapticCue> = []
    public init(strength: ProbeHapticStrength = .subtle) { self.strength = strength }

    public mutating func setActive(_ value: Bool) { active = value }
    public mutating func beginPlacement() {
        window = nil; seenWindows.removeAll(); terminalSent = false; connectivityAlerted = false
    }
    public mutating func playbackBegan() { playbackInFlight = true }
    public mutating func playbackEnded(at now: Double) {
        guard playbackInFlight else { return }
        playbackInFlight = false
        quietUntil = max(quietUntil, now + 0.25)
    }
    public func permitsColourSample(at now: Double) -> Bool {
        active && !playbackInFlight && now >= quietUntil
    }

    public mutating func request(_ cue: ProbeHapticCue, at now: Double) -> ProbeHapticPlan? {
        guard window == nil else { return nil } // No delayed cues may leak into a sample window.
        return decide(cue, at: now)
    }
    public mutating func openWindow(id: UUID, first: Bool, verification: Bool,
                                    settlingSeconds: Double, at now: Double) -> ProbeHapticPlan? {
        guard seenWindows.insert(id).inserted else { return nil }
        window = id
        let cue: ProbeHapticCue = first ? .measurementStarted : (verification ? .verification : .patch)
        let duration = cue.plan(strength: strength).duration
        guard settlingSeconds.isFinite, settlingSeconds >= duration + 0.25 + 0.05 else { return nil }
        return decide(cue, at: now)
    }
    public mutating func closeWindow(id: UUID) { if window == id { window = nil } }
    public mutating func endWindows() { window = nil }

    private mutating func decide(_ cue: ProbeHapticCue, at now: Double) -> ProbeHapticPlan? {
        guard active, strength != .off, now.isFinite, !playbackInFlight else { return nil }
        if connectivityAlerted, cue == .connected || cue == .disconnected || cue == .refused { return nil }
        // Even a deduplicated terminal refusal starts a quiet reconnect episode.
        if cue == .disconnected || cue == .refused { connectivityAlerted = true }
        if cue.isTerminal, terminalSent { return nil }
        let repeatInterval = cue == .patch ? 0.35 : 1.5
        guard now - (cueTimes[cue] ?? -.infinity) >= repeatInterval else { return nil }
        guard cue.isTerminal || now - lastCueTime >= 0.35 else { return nil }
        if cue.isTerminal { terminalSent = true }
        cueTimes[cue] = now; lastCueTime = now
        return cue.plan(strength: strength)
    }

    public mutating func alignment(_ reading: DepthAlignmentReading, at now: Double) -> ProbeHapticPlan? {
        guard window == nil else { return nil }
        if reading.status == .starting {
            guard !alignmentActive else { return nil }
            alignmentActive = true; alignmentCues.removeAll()
            reliableSince = nil; levelSince = nil; nearSince = nil; missingSince = nil
            return request(.alignmentStarted, at: now)
        }
        if reading.status == .finished || reading.status == .unavailable {
            guard alignmentActive else { return nil }
            alignmentActive = false
            return request(reading.status == .finished ? .alignmentFinished : .alignmentUnavailable, at: now)
        }
        guard alignmentActive, active, strength != .off, !playbackInFlight, now >= quietUntil else { return nil }
        if reading.status == .estimate, let distance = reading.distanceMeters, let tilt = reading.tiltDegrees,
           distance.isFinite, tilt.isFinite, distance >= 0.20, distance <= 1.5, (0...65).contains(tilt) {
            missingSince = nil
            reliableSince = reliableSince ?? now
            if tilt <= 3 { levelSince = levelSince ?? now } else if tilt >= 6 { levelSince = nil }
            if distance <= 0.30 { nearSince = nearSince ?? now } else if distance >= 0.35 { nearSince = nil }
            let cue: ProbeHapticCue?
            if let levelSince, now - levelSince >= 0.6, !alignmentCues.contains(.surfaceLevel) { cue = .surfaceLevel }
            else if let nearSince, now - nearSince >= 0.6, !alignmentCues.contains(.alignmentNear) { cue = .alignmentNear }
            else if let reliableSince, now - reliableSince >= 0.6, !alignmentCues.contains(.surfaceFound) { cue = .surfaceFound }
            else { cue = nil }
            if let cue, let plan = request(cue, at: now) {
                alignmentCues.insert(cue)
                // A stronger milestone also conveys that a surface was found.
                if cue == .surfaceLevel || cue == .alignmentNear { alignmentCues.insert(.surfaceFound) }
                return plan
            }
        } else if reading.status == .noReliableDepth {
            reliableSince = nil; levelSince = nil; nearSince = nil
            missingSince = missingSince ?? now
            if let missingSince, now - missingSince >= 1, !alignmentCues.contains(.alignmentUnavailable),
               let plan = request(.alignmentUnavailable, at: now) {
                alignmentCues.insert(.alignmentUnavailable)
                return plan
            }
        }
        return nil
    }
}
