import Foundation

/// Resolved linear-light channel gains. Blending is resolved before output or prediction.
public struct RGBGains: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let identity = RGBGains(r: 1, g: 1, b: 1)

    public var isIdentity: Bool {
        abs(r - 1) < 1e-9 && abs(g - 1) < 1e-9 && abs(b - 1) < 1e-9
    }

    /// Blend toward the identity by `alpha`: `1 + (gain - 1) * alpha`.
    public func blended(alpha: Double) -> RGBGains {
        let a = min(max(alpha, 0), 1)
        return RGBGains(
            r: 1 + (r - 1) * a,
            g: 1 + (g - 1) * a,
            b: 1 + (b - 1) * a
        )
    }

    /// Scale so the largest channel is exactly 1 and every channel is in `(0, 1]`.
    public func attenuated() -> RGBGains {
        let peak = max(r, g, b, 1e-6)
        return RGBGains(
            r: clampPositive(r / peak),
            g: clampPositive(g / peak),
            b: clampPositive(b / peak)
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

/// A requested blend is distinct from the effective gains consumed by all adapters.
public struct CorrectionRequest: Codable, Hashable, Sendable {
    public var gains: RGBGains
    public var alpha: Double

    public init(gains: RGBGains, alpha: Double = 1) {
        self.gains = gains
        self.alpha = alpha
    }

    public func resolved() -> RGBGains { gains.blended(alpha: alpha) }
}
