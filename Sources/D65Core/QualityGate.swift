import Foundation

public enum CalibrationVerdict: String, Codable, Sendable {
    /// Display was already close enough; install identity gains.
    case confirmed
    /// Correction measurably improved the white point.
    case improved
    /// Correction did not help enough; do not apply it.
    case rejected
}

/// Acceptance thresholds for a white-point correction.
///
/// Defaults mirror the gates observed in Apple's implementation: below 2.5
/// ΔE00 there is nothing worth doing, and above 5.0 ΔE00 after correction the
/// result is not worth keeping. See `docs/apple-color-balance.md`.
public struct QualityGate: Codable, Sendable {
    /// If the display is already better than this, report `confirmed`.
    public var minimumPreCorrectionDeltaE: Double
    /// If the corrected result is worse than this, report `rejected`.
    public var maximumPostCorrectionDeltaE: Double
    /// Refuse corrections that dim the display by more than this fraction.
    public var maximumLuminanceLoss: Double

    public init(
        minimumPreCorrectionDeltaE: Double = 2.5,
        maximumPostCorrectionDeltaE: Double = 5.0,
        maximumLuminanceLoss: Double = 0.20
    ) {
        self.minimumPreCorrectionDeltaE = minimumPreCorrectionDeltaE
        self.maximumPostCorrectionDeltaE = maximumPostCorrectionDeltaE
        self.maximumLuminanceLoss = maximumLuminanceLoss
    }

    public func verdict(preDeltaE: Double, postDeltaE: Double, luminanceScale: Double = 1) -> CalibrationVerdict {
        if preDeltaE <= minimumPreCorrectionDeltaE {
            return .confirmed
        }
        if luminanceScale < 1 - maximumLuminanceLoss {
            return .rejected
        }
        if postDeltaE > maximumPostCorrectionDeltaE || postDeltaE >= preDeltaE {
            return .rejected
        }
        return .improved
    }
}
