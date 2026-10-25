import D65Core
import Foundation

public struct MeasurementRequest: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let patchID: UUID
    public let phase: String
    public let startedAt: Date
    public let settlingSeconds: Double
    public let samplingSeconds: Double

    public init(sessionID: UUID, patchID: UUID = UUID(), phase: String, startedAt: Date,
                settlingSeconds: Double, samplingSeconds: Double) {
        self.sessionID = sessionID
        self.patchID = patchID
        self.phase = phase
        self.startedAt = startedAt
        self.settlingSeconds = settlingSeconds
        self.samplingSeconds = samplingSeconds
    }
}

public struct TaggedMeasurement: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let patchID: UUID
    public let sample: MeasurementSample
    /// Receiver-local timestamp: filtering does not depend on synchronized phone/Mac clocks.
    public let receivedAt: Date

    public init(sessionID: UUID, patchID: UUID, sample: MeasurementSample, receivedAt: Date) {
        self.sessionID = sessionID
        self.patchID = patchID
        self.sample = sample
        self.receivedAt = receivedAt
    }
}

public struct PatchMeasurement: Codable, Sendable {
    public let request: MeasurementRequest
    public let samples: [MeasurementSample]
    public let mean: XYZ
    public let standardError: XYZ
    public let rejectedCount: Int

    public func subtracting(_ ambient: XYZ) -> XYZ {
        XYZ(x: max(0, mean.x - ambient.x), y: max(0, mean.y - ambient.y), z: max(0, mean.z - ambient.z))
    }
}

/// Validates one sampling window. Black patches allow zero lux/XYZ for ambient subtraction.
public struct MeasurementCollector: Sendable {
    public let minimumCount: Int
    public init(minimumCount: Int = 3) { self.minimumCount = max(2, minimumCount) }

    public func collect(_ input: [TaggedMeasurement], for request: MeasurementRequest) throws -> PatchMeasurement {
        let start = request.startedAt.addingTimeInterval(request.settlingSeconds)
        let end = start.addingTimeInterval(request.samplingSeconds)
        let usable = input.filter {
            let s = $0.sample
            return $0.sessionID == request.sessionID && $0.patchID == request.patchID
                && $0.receivedAt >= start && $0.receivedAt <= end
                && [s.xyz.x, s.xyz.y, s.xyz.z, s.lux].allSatisfy { $0.isFinite && $0 >= 0 }
                && s.lux <= 20_000
        }.map(\.sample)
        guard usable.count >= minimumCount else {
            throw MeasurementError.insufficientSamples(have: usable.count, need: minimumCount)
        }
        let ys = usable.map(\.xyz.y).sorted()
        let medianY = ys[ys.count / 2]
        let tolerance = max(0.5, medianY * 0.35)
        var kept = usable.filter { abs($0.xyz.y - medianY) <= tolerance }
        // For emitted patches also reject chromaticity outliers. Near-black xy is undefined/noisy.
        if medianY > 2 {
            let xs = kept.compactMap { $0.chromaticity?.x }.sorted()
            let cs = kept.compactMap { $0.chromaticity?.y }.sorted()
            if !xs.isEmpty, !cs.isEmpty {
                let x = xs[xs.count / 2], y = cs[cs.count / 2]
                kept = kept.filter {
                    guard let c = $0.chromaticity else { return false }
                    return hypot(c.x - x, c.y - y) <= 0.02
                }
            }
        }
        guard kept.count >= minimumCount else { throw MeasurementError.noConsensus }
        let n = Double(kept.count)
        func stats(_ values: [Double]) -> (Double, Double) {
            let mean = values.reduce(0, +) / n
            let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / (n - 1)
            return (mean, sqrt(variance / n))
        }
        let x = stats(kept.map(\.xyz.x)), y = stats(kept.map(\.xyz.y)), z = stats(kept.map(\.xyz.z))
        return PatchMeasurement(request: request, samples: kept,
            mean: XYZ(x: x.0, y: y.0, z: z.0), standardError: XYZ(x: x.1, y: y.1, z: z.1),
            rejectedCount: input.count - kept.count)
    }
}
