import Foundation

/// Helpers for per-channel gain applied to an existing display transfer table.
///
/// The gains multiply the *encoded* table entries rather than linear light. That
/// keeps the display's existing calibration curve intact — an identity gain is
/// then exactly a no-op — at the cost of not being colorimetrically pure. It is
/// the same trade-off the reference implementation makes with a diagonal matrix.
public enum GammaTable {
    /// Multiply every entry by `gain`, clamping to `0...1`.
    public static func scaled(_ base: [Double], by gain: Double) -> [Double] {
        let clamped = min(max(gain, 0), 1)
        return base.map { min(max($0 * clamped, 0), 1) }
    }

    /// Scale a table so that **linear light** changes by `gain`.
    ///
    /// A display applies its own transfer function on top of the table, so
    /// multiplying the encoded value by `gain` changes luminance by
    /// `gain^gamma`. To get a linear-light gain, multiply the encoded value by
    /// `gain^(1/gamma)` instead.
    public static func scaledLinear(_ base: [Double], by gain: Double, gamma: Double = 2.2) -> [Double] {
        guard gamma > 0 else { return scaled(base, by: gain) }
        return scaled(base, by: pow(min(max(gain, 0), 1), 1 / gamma))
    }

    /// Linear ramp, useful for tests and for displays with no calibration table.
    public static func ramp(count: Int) -> [Double] {
        guard count > 1 else { return [0] }
        return (0..<count).map { Double($0) / Double(count - 1) }
    }
}
