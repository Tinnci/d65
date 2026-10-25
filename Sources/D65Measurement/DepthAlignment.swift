import Foundation

/// Advisory geometry, never a colour observer, screen identity, or contact detector.
public struct DepthAlignmentReading: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case starting, estimate, noReliableDepth, stopping, cooldown, finished, unavailable
    }
    public let status: Status
    public let distanceMeters: Double?
    public let tiltDegrees: Double?
    public let residualMeters: Double?
    public let message: String

    public init(status: Status, distanceMeters: Double? = nil, tiltDegrees: Double? = nil,
                residualMeters: Double? = nil, message: String) {
        self.status = status; self.distanceMeters = distanceMeters; self.tiltDegrees = tiltDegrees
        self.residualMeters = residualMeters; self.message = message
    }
    /// The infrared camera must be confirmed off before any colour samples are accepted.
    public var blocksColourSampling: Bool {
        switch status { case .finished, .unavailable: false; default: true }
    }
    public var summary: String {
        if status == .estimate, let distanceMeters, let tiltDegrees,
           distanceMeters.isFinite, tiltDegrees.isFinite {
            return String(format: "TrueDepth estimate: %.0f cm · tilt %.0f°", distanceMeters * 100, tiltDegrees)
        }
        return message
    }
}

public struct DepthCameraIntrinsics: Sendable {
    public let fx: Double, fy: Double, cx: Double, cy: Double
    public init(fx: Double, fy: Double, cx: Double, cy: Double) {
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
    }
}
public struct DepthPixel: Sendable {
    public let x: Double, y: Double, meters: Double
    public init(x: Double, y: Double, meters: Double) { self.x = x; self.y = y; self.meters = meters }
}

/// Plane fit over a central depth ROI. Heuristic quality gates are not a sensor-accuracy guarantee.
public enum DepthAlignmentEstimator {
    public static func estimate(_ pixels: [DepthPixel], intrinsics k: DepthCameraIntrinsics) -> DepthAlignmentReading {
        let unavailable = DepthAlignmentReading(status: .noReliableDepth,
            message: "No reliable flat-surface depth. Use the outline and finish by contact.")
        guard [k.fx, k.fy, k.cx, k.cy].allSatisfy(\.isFinite), k.fx > 0, k.fy > 0, pixels.count >= 16 else { return unavailable }
        // A chosen advisory working window, not a claim about the hardware's minimum range.
        let usable = pixels.filter { $0.x.isFinite && $0.y.isFinite && $0.meters.isFinite && (0.15...1.5).contains($0.meters) }
        guard usable.count >= 16, Double(usable.count) / Double(pixels.count) >= 0.6 else { return unavailable }
        let sorted = usable.map(\.meters).sorted()
        let median = sorted[sorted.count / 2]
        let kept = usable.filter { abs($0.meters - median) <= max(0.03, median * 0.12) }
        guard kept.count >= 16, Double(kept.count) / Double(pixels.count) >= 0.6 else { return unavailable }
        let points = kept.map { SIMD3(($0.x - k.cx) / k.fx * $0.meters, ($0.y - k.cy) / k.fy * $0.meters, $0.meters) }
        let mean = points.reduce(SIMD3<Double>.zero, +) / Double(points.count)
        var xx = 0.0, xy = 0.0, yy = 0.0, xz = 0.0, yz = 0.0
        for point in points {
            let d = point - mean
            xx += d.x * d.x; xy += d.x * d.y; yy += d.y * d.y
            xz += d.x * d.z; yz += d.y * d.z
        }
        let determinant = xx * yy - xy * xy
        guard determinant.isFinite, determinant > 1e-12 else { return unavailable }
        let a = (xz * yy - yz * xy) / determinant
        let b = (yz * xx - xz * xy) / determinant
        let distance = mean.z - a * mean.x - b * mean.y // Intersection with the camera's optical axis.
        let normalLength = sqrt(1 + a * a + b * b)
        let tilt = atan(hypot(a, b)) * 180 / .pi
        let residual = sqrt(points.reduce(0) {
            $0 + pow(($1.z - a * $1.x - b * $1.y - distance) / normalLength, 2)
        } / Double(points.count))
        guard [distance, tilt, residual].allSatisfy(\.isFinite), (0.15...1.5).contains(distance),
              tilt <= 65, residual <= max(0.003, distance * 0.01) else { return unavailable }
        return DepthAlignmentReading(status: .estimate, distanceMeters: distance, tiltDegrees: tilt,
            residualMeters: residual, message: "Approximate surface geometry only; finish placement by contact.")
    }
}

/// Retains the block through asynchronous capture shutdown and an ALS settling interval.
public struct AlignmentSamplingGate: Sendable {
    public private(set) var awaitingCameraStop = false
    private var resumeAt: Date?
    public init() {}
    public mutating func begin() { awaitingCameraStop = true; resumeAt = nil }
    public mutating func cameraDidStop(at now: Date) {
        awaitingCameraStop = false
        resumeAt = now.addingTimeInterval(0.5)
    }
    public func permitsColourSample(at now: Date) -> Bool {
        guard !awaitingCameraStop else { return false }
        return resumeAt.map { now >= $0 } ?? true
    }
}
