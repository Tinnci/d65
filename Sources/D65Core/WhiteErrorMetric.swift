import Foundation

/// How far a measured white is from the target, compared at equal luminance so the result does not
/// depend on probe distance or exposure.
public enum WhiteErrorMetric: String, Codable, Sendable, CaseIterable {
    /// CIEDE2000 (ISO/CIE 11664-6), white normalised to Y = 1. The default, and what the quality
    /// gate's thresholds were chosen on.
    case ciede2000
    /// Euclidean ΔE' in CAM16-UCS (CIE 248:2022 model, Li et al. 2017 UCS), white at Y = 100 under
    /// `CAM16.ViewingConditions.displayD65`. Similar in scale to ΔE00 but not identical.
    case cam16ucs

    /// Short label for figures, e.g. "ΔE00".
    public var label: String {
        switch self {
        case .ciede2000: "ΔE00"
        case .cam16ucs: "ΔE CAM16-UCS"
        }
    }

    /// The exact definition, as stored in experiment records.
    public var definition: String {
        switch self {
        case .ciede2000: "CIEDE2000, white normalized to Y=1"
        case .cam16ucs: "CAM16-UCS ΔE', white at Y=100, adapted to D65 (D=1), L_A 64 cd/m², Y_b 20, average surround"
        }
    }

    public func whiteError(_ white: XYZ, target: Chromaticity = .d65) -> Double {
        guard white.y > 0 else { return .infinity }
        switch self {
        case .ciede2000:
            return ColorDifference.deltaE00(white.scaled(by: 1 / white.y), target.xyz(), white: target.xyz())
        case .cam16ucs:
            var conditions = CAM16.ViewingConditions.displayD65
            conditions.white = target.xyz(luminance: 100)
            return CAM16.deltaE(white.scaled(by: 100 / white.y), target.xyz(luminance: 100), in: conditions)
        }
    }
}

/// The colour-matching functions a set of XYZ values was computed with. Values from different
/// observers must not be compared, so a measurement's observer travels with it.
public enum Observer: String, Codable, Sendable, CaseIterable {
    case cie1931TwoDegree = "CIE 1931 2°"
    case cie2015TwoDegree = "CIE 2015 2°"
    case cie2015TenDegree = "CIE 2015 10°"

    /// D65 integrated against this observer's CMFs. CIE 2015 uses the bundled official 1 nm
    /// tables over 390...830 nm; 1931 retains the existing rounded sRGB/Rec.709 reference.
    /// Loading invalid/missing CIE resources returns nil, never another observer's white.
    public var d65: Chromaticity? {
        switch self {
        case .cie1931TwoDegree: .d65
        case .cie2015TwoDegree: CIESpectralData.twoDegreeD65?.chromaticity
        case .cie2015TenDegree: CIESpectralData.tenDegreeD65?.chromaticity
        }
    }
}
