import Foundation

/// Tristimulus values, relative or absolute. The observer is supplied by the measurement context.
public struct XYZ: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public init(chromaticity: Chromaticity, luminance: Double = 1) {
        self = chromaticity.xyz(luminance: luminance)
    }

    public static let zero = XYZ(x: 0, y: 0, z: 0)

    public var luminance: Double { y }

    /// Chromaticity of this stimulus. Returns `nil` for a black stimulus.
    public var chromaticity: Chromaticity? {
        let sum = x + y + z
        guard sum > 0 else { return nil }
        return Chromaticity(x: x / sum, y: y / sum)
    }

    public func scaled(by factor: Double) -> XYZ {
        XYZ(x: x * factor, y: y * factor, z: z * factor)
    }
}

/// CIE xy chromaticity.
public struct Chromaticity: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// D65 as used by sRGB / Rec.709 and by the reference white in this project.
    public static let d65 = Chromaticity(x: 0.3127, y: 0.3290)
    public static let d50 = Chromaticity(x: 0.3457, y: 0.3585)

    public func xyz(luminance: Double = 1) -> XYZ {
        guard y > 0 else { return .zero }
        return XYZ(
            x: (x / y) * luminance,
            y: luminance,
            z: ((1 - x - y) / y) * luminance
        )
    }

    /// Correlated colour temperature, McCamy's cubic approximation for CIE 1931 xy.
    /// CIE 2015 coordinates require an observer-specific CCT calculation.
    /// Good to roughly ±2 K near the Planckian locus for typical display whites.
    public func correlatedColorTemperature() -> Double {
        let n = (x - 0.3320) / (0.1858 - y)
        return 437 * pow(n, 3) + 3601 * pow(n, 2) + 6861 * n + 5517
    }
}
