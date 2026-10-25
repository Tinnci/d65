import D65Measurement
import Foundation

public enum PlacementState: String, Sendable, Equatable {
    /// No preview reading has arrived yet.
    case waiting
    /// Readings arrive but are too dim to be the phone lying on a lit patch.
    case tooDark
    /// The probe reports motion, or readings stopped arriving (the probe drops moving samples).
    case moving
    /// Consistent readings, not yet for long enough.
    case settling
    case settled
}

public struct PlacementReading: Sendable, Equatable {
    public var state: PlacementState
    public var luminance: Double?
    /// 0…1 towards `requiredSteadySeconds`.
    public var alignment: DepthAlignmentReading?
    public var steadyFraction: Double
    public init(state: PlacementState, luminance: Double? = nil, steadyFraction: Double = 0, alignment: DepthAlignmentReading? = nil) {
        self.state = state; self.luminance = luminance; self.steadyFraction = steadyFraction; self.alignment = alignment
    }
}

/// Decides when the phone is resting on the placement patch, from the probe's preview stream.
/// Measurement starts from stillness instead of from the moment the probe connects.
public struct PlacementMonitor: Sendable {
    public var requiredSteadySeconds = 1.5
    public var minimumLuminance = 5.0
    /// Largest relative deviation from the run's median that still counts as the same placement.
    public var maximumVariation = 0.03
    /// The probe stops sending while it moves; silence this long is treated as movement.
    public var silenceSeconds = 1.0
    public var minimumSamples = 3

    private var run: [Double] = []
    private var steadySince: Date?
    private var lastSampleAt: Date?
    private var lastLuminance: Double?

    public init() {}

    public mutating func add(_ sample: MeasurementSample, stable: Bool, at now: Date) -> PlacementReading {
        lastSampleAt = now
        let y = sample.xyz.y
        lastLuminance = y.isFinite ? y : nil
        guard y.isFinite, stable else { reset(); return PlacementReading(state: .moving, luminance: lastLuminance) }
        guard y >= minimumLuminance else { reset(); return PlacementReading(state: .tooDark, luminance: y) }
        if let reference = median(run), abs(y / reference - 1) > maximumVariation {
            reset()
        }
        if run.isEmpty { steadySince = now }
        run.append(y)
        if run.count > 32 { run.removeFirst(run.count - 32) }
        return reading(at: now)
    }

    /// Re-evaluate without a new sample, so silence is noticed.
    public mutating func tick(at now: Date) -> PlacementReading {
        guard let lastSampleAt else { return PlacementReading(state: .waiting) }
        if now.timeIntervalSince(lastSampleAt) > silenceSeconds {
            reset()
            return PlacementReading(state: .moving, luminance: lastLuminance)
        }
        return run.isEmpty ? PlacementReading(state: .moving, luminance: lastLuminance) : reading(at: now)
    }

    public mutating func reset() { run.removeAll(); steadySince = nil }

    private func reading(at now: Date) -> PlacementReading {
        guard let steadySince else { return PlacementReading(state: .moving, luminance: lastLuminance) }
        let fraction = min(1, max(0, now.timeIntervalSince(steadySince) / requiredSteadySeconds))
        let settled = fraction >= 1 && run.count >= minimumSamples
        return PlacementReading(state: settled ? .settled : .settling, luminance: median(run), steadyFraction: fraction)
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

/// Stale estimates disappear, but a silent camera never becomes permission to sample colour.
public struct DepthAlignmentFeedback: Sendable {
    private var latest: DepthAlignmentReading?
    private var receivedAt: Date?
    public init() {}
    public var blocksColourSampling: Bool { latest?.blocksColourSampling == true }
    public mutating func receive(_ reading: DepthAlignmentReading, at now: Date) {
        latest = reading; receivedAt = now
    }
    public mutating func reset() { latest = nil; receivedAt = nil }
    public func visible(at now: Date) -> DepthAlignmentReading? {
        guard let latest, let receivedAt else { return nil }
        if now.timeIntervalSince(receivedAt) <= 1 { return latest }
        if blocksColourSampling {
            return .init(status: .noReliableDepth, message: "Depth feedback paused. Finish alignment on the iPhone before measuring.")
        }
        return nil
    }
}
