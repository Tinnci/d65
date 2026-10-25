import Foundation

/// Per-channel display gains, plus the blend factor used by the reference
/// implementation to partially apply a correction.
///
/// A gain of 1 is the identity. Values below 1 attenuate a channel; the
/// reference implementation clamps to `(0, 1]` because a white-point
/// correction that needs to *boost* a channel is better expressed by
/// attenuating the other two.
public struct RGBGains: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    /// 0 = untouched display, 1 = fully applied correction.
    public var alpha: Double

    public init(r: Double, g: Double, b: Double, alpha: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.alpha = alpha
    }

    public static let identity = RGBGains(r: 1, g: 1, b: 1, alpha: 1)

    public var isIdentity: Bool {
        abs(r - 1) < 1e-9 && abs(g - 1) < 1e-9 && abs(b - 1) < 1e-9
    }

    /// Blend toward the identity by `alpha`: `1 + (gain - 1) * alpha`.
    public func blended(alpha: Double? = nil) -> RGBGains {
        let a = min(max(alpha ?? self.alpha, 0), 1)
        return RGBGains(
            r: 1 + (r - 1) * a,
            g: 1 + (g - 1) * a,
            b: 1 + (b - 1) * a,
            alpha: a
        )
    }

    /// Scale so the largest channel is exactly 1 and every channel is in `(0, 1]`.
    public func attenuated() -> RGBGains {
        let peak = max(r, g, b, 1e-6)
        return RGBGains(
            r: clampPositive(r / peak),
            g: clampPositive(g / peak),
            b: clampPositive(b / peak),
            alpha: alpha
        )
    }

    /// Column-major 4×4 matrix with the gains on the diagonal, matching what a
    /// render-server colour matrix expects.
    public var diagonalMatrix: [Float] {
        [
            Float(r), 0, 0, 0,
            0, Float(g), 0, 0,
            0, 0, Float(b), 0,
            0, 0, 0, 1,
        ]
    }

    /// Relative luminance change implied by the gains (Rec.709 weights).
    public var luminanceScale: Double {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private func clampPositive(_ value: Double) -> Double {
        min(max(value, 1e-4), 1)
    }
}
