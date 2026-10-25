import Foundation

/// Row-major 3×3 matrix.
public struct Matrix3x3: Equatable, Sendable {
    public var m: [Double] // 9 elements, row-major

    public init(_ m: [Double]) {
        precondition(m.count == 9, "Matrix3x3 needs 9 elements")
        self.m = m
    }

    public static let identity = Matrix3x3([1, 0, 0, 0, 1, 0, 0, 0, 1])

    public subscript(row: Int, column: Int) -> Double {
        get { m[row * 3 + column] }
        set { m[row * 3 + column] = newValue }
    }

    public func multiplied(by v: XYZ) -> XYZ {
        XYZ(
            x: m[0] * v.x + m[1] * v.y + m[2] * v.z,
            y: m[3] * v.x + m[4] * v.y + m[5] * v.z,
            z: m[6] * v.x + m[7] * v.y + m[8] * v.z
        )
    }

    public func multiplied(by other: Matrix3x3) -> Matrix3x3 {
        var result = [Double](repeating: 0, count: 9)
        for row in 0..<3 {
            for column in 0..<3 {
                var sum = 0.0
                for k in 0..<3 {
                    sum += self[row, k] * other[k, column]
                }
                result[row * 3 + column] = sum
            }
        }
        return Matrix3x3(result)
    }

    public var determinant: Double {
        m[0] * (m[4] * m[8] - m[5] * m[7])
            - m[1] * (m[3] * m[8] - m[5] * m[6])
            + m[2] * (m[3] * m[7] - m[4] * m[6])
    }

    public func inverted() -> Matrix3x3? {
        let det = determinant
        guard abs(det) > 1e-12 else { return nil }
        let inv = [
            (m[4] * m[8] - m[5] * m[7]) / det,
            (m[2] * m[7] - m[1] * m[8]) / det,
            (m[1] * m[5] - m[2] * m[4]) / det,
            (m[5] * m[6] - m[3] * m[8]) / det,
            (m[0] * m[8] - m[2] * m[6]) / det,
            (m[2] * m[3] - m[0] * m[5]) / det,
            (m[3] * m[7] - m[4] * m[6]) / det,
            (m[1] * m[6] - m[0] * m[7]) / det,
            (m[0] * m[4] - m[1] * m[3]) / det,
        ]
        return Matrix3x3(inv)
    }
}

/// Chromaticities of a display's primaries and its reference white.
public struct DisplayPrimaries: Sendable {
    public var red: Chromaticity
    public var green: Chromaticity
    public var blue: Chromaticity
    public var white: Chromaticity

    public init(red: Chromaticity, green: Chromaticity, blue: Chromaticity, white: Chromaticity) {
        self.red = red
        self.green = green
        self.blue = blue
        self.white = white
    }

    public static let sRGB = DisplayPrimaries(
        red: Chromaticity(x: 0.640, y: 0.330),
        green: Chromaticity(x: 0.300, y: 0.600),
        blue: Chromaticity(x: 0.150, y: 0.060),
        white: .d65
    )

    public static let displayP3 = DisplayPrimaries(
        red: Chromaticity(x: 0.680, y: 0.320),
        green: Chromaticity(x: 0.265, y: 0.690),
        blue: Chromaticity(x: 0.150, y: 0.060),
        white: .d65
    )

    /// Linear RGB → XYZ.
    public func rgbToXYZ() -> Matrix3x3 {
        let p = Matrix3x3([
            red.x / red.y, green.x / green.y, blue.x / blue.y,
            1, 1, 1,
            (1 - red.x - red.y) / red.y, (1 - green.x - green.y) / green.y, (1 - blue.x - blue.y) / blue.y,
        ])
        guard let inverse = p.inverted() else { return .identity }
        let w = white.xyz()
        let s = inverse.multiplied(by: w)
        let scale = Matrix3x3([
            s.x, 0, 0,
            0, s.y, 0,
            0, 0, s.z,
        ])
        return p.multiplied(by: scale)
    }

    public func xyzToRGB() -> Matrix3x3 {
        rgbToXYZ().inverted() ?? .identity
    }
}

public enum WhitePointSolver {
    /// Per-channel gains that move a measured white point onto `target`.
    ///
    /// The correction is computed in linear RGB space, because that is where
    /// the gains are applied: `XYZ = M · RGB`, so `gains = (M⁻¹·target) / (M⁻¹·measured)`
    /// componentwise. The result is attenuated so the brightest channel is 1
    /// and no channel exceeds it.
    public static func gains(
        measuredWhite: XYZ,
        target: Chromaticity = .d65,
        primaries: DisplayPrimaries = .sRGB
    ) -> RGBGains {
        guard measuredWhite.y > 0 else { return .identity }

        let toRGB = primaries.xyzToRGB()
        let measuredRGB = toRGB.multiplied(by: measuredWhite)
        let targetRGB = toRGB.multiplied(by: target.xyz(luminance: measuredWhite.y))

        func ratio(_ target: Double, _ measured: Double) -> Double {
            guard measured > 1e-9, target > 0 else { return 1 }
            return target / measured
        }

        let raw = RGBGains(
            r: ratio(targetRGB.x, measuredRGB.x),
            g: ratio(targetRGB.y, measuredRGB.y),
            b: ratio(targetRGB.z, measuredRGB.z)
        )
        return raw.attenuated()
    }

    /// Predicted white point after applying `gains` to a display whose white
    /// currently measures `measuredWhite`.
    public static func predictedWhite(
        after gains: RGBGains,
        measuredWhite: XYZ,
        primaries: DisplayPrimaries = .sRGB
    ) -> XYZ {
        let toRGB = primaries.xyzToRGB()
        let rgb = toRGB.multiplied(by: measuredWhite)
        let corrected = XYZ(x: rgb.x * gains.r, y: rgb.y * gains.g, z: rgb.z * gains.b)
        return primaries.rgbToXYZ().multiplied(by: corrected)
    }
}
