import D65Core
import Foundation

/// One ambient-light reading, already normalised to tristimulus values.
///
/// The phone is treated as a probe: it reports XYZ (or the raw channels needed
/// to derive them), and nothing about the display's correction is decided here.
public struct MeasurementSample: Codable, Hashable, Sendable {
    public var xyz: XYZ
    public var lux: Double
    /// Raw sensor channels, kept for diagnostics and for per-module calibration.
    public var channels: [Double]
    /// CCT as reported by the sensor, if it reports one.
    public var reportedCCT: Double?
    public var capturedAt: Date
    public var deviceModel: String?

    public init(
        xyz: XYZ,
        lux: Double,
        channels: [Double] = [],
        reportedCCT: Double? = nil,
        capturedAt: Date = Date(),
        deviceModel: String? = nil
    ) {
        self.xyz = xyz
        self.lux = lux
        self.channels = channels
        self.reportedCCT = reportedCCT
        self.capturedAt = capturedAt
        self.deviceModel = deviceModel
    }

    public var chromaticity: Chromaticity? { xyz.chromaticity }

    public var cct: Double? {
        reportedCCT ?? chromaticity?.correlatedColorTemperature()
    }
}

/// Something that can produce a stream of measurements — an iPhone probe today,
/// a colourimeter or a Mac ambient sensor later.
public protocol MeasurementSource: Sendable {
    func stream() -> AsyncThrowingStream<MeasurementSample, Error>
}

public enum MeasurementError: Error, Equatable {
    case insufficientSamples(have: Int, need: Int)
    case noConsensus
    case outOfRange
}

/// Rejects implausible readings and averages the rest.
public struct MeasurementNormalizer: Sendable {
    public var minimumLux: Double
    public var maximumLux: Double
    /// Maximum chromaticity distance from the median before a sample is dropped.
    public var maximumChromaticityDeviation: Double

    public init(
        minimumLux: Double = 5,
        maximumLux: Double = 20_000,
        maximumChromaticityDeviation: Double = 0.02
    ) {
        self.minimumLux = minimumLux
        self.maximumLux = maximumLux
        self.maximumChromaticityDeviation = maximumChromaticityDeviation
    }

    public func accepts(_ sample: MeasurementSample) -> Bool {
        sample.lux >= minimumLux
            && sample.lux <= maximumLux
            && sample.xyz.y > 0
            && sample.chromaticity != nil
    }

    public func robustMean(_ samples: [MeasurementSample], minimumCount: Int = 3) throws -> MeasurementSample {
        let usable = samples.filter(accepts)
        guard usable.count >= minimumCount else {
            throw MeasurementError.insufficientSamples(have: usable.count, need: minimumCount)
        }

        let medianX = median(usable.map(\.xyz.x))
        let medianY = median(usable.map(\.xyz.y))
        let medianZ = median(usable.map(\.xyz.z))
        let medianWhite = XYZ(x: medianX, y: medianY, z: medianZ)
        guard let medianChromaticity = medianWhite.chromaticity else {
            throw MeasurementError.noConsensus
        }

        let kept = usable.filter { sample in
            guard let c = sample.chromaticity else { return false }
            let dx = c.x - medianChromaticity.x
            let dy = c.y - medianChromaticity.y
            return (dx * dx + dy * dy).squareRoot() <= maximumChromaticityDeviation
        }
        guard kept.count >= minimumCount else { throw MeasurementError.noConsensus }

        let n = Double(kept.count)
        let sum = kept.reduce(into: XYZ.zero) { partial, sample in
            partial.x += sample.xyz.x
            partial.y += sample.xyz.y
            partial.z += sample.xyz.z
        }
        let mean = XYZ(x: sum.x / n, y: sum.y / n, z: sum.z / n)

        return MeasurementSample(
            xyz: mean,
            lux: kept.map(\.lux).reduce(0, +) / n,
            channels: averageChannels(kept),
            reportedCCT: nil,
            capturedAt: kept.map(\.capturedAt).max() ?? Date(),
            deviceModel: kept.last?.deviceModel
        )
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private func averageChannels(_ samples: [MeasurementSample]) -> [Double] {
        guard let count = samples.map(\.channels.count).max(), count > 0 else { return [] }
        var totals = [Double](repeating: 0, count: count)
        var contributors = [Int](repeating: 0, count: count)
        for sample in samples where sample.channels.count == count {
            for index in 0..<count {
                totals[index] += sample.channels[index]
                contributors[index] += 1
            }
        }
        return zip(totals, contributors).map { $1 > 0 ? $0 / Double($1) : 0 }
    }
}
