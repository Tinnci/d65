import Foundation

/// CAM16 colour appearance model and its uniform colour space CAM16-UCS.
///
/// References: Li, Li, Wang, Zu, Luo, Cui, Melgosa, Brill & Pointer (2017), "Comprehensive colour
/// solutions: CAM16, CAT16, and CAM16-UCS", Color Research & Application 42(6); CIE 248:2022.
public enum CAM16 {
    /// Viewing conditions. Tristimulus values use the Y = 100 scale.
    public struct ViewingConditions: Sendable, Equatable {
        public enum Surround: Sendable, Equatable {
            case average, dim, dark
            var parameters: (F: Double, c: Double, Nc: Double) {
                switch self {
                case .average: (1.0, 0.69, 1.0)
                case .dim: (0.9, 0.59, 0.9)
                case .dark: (0.8, 0.525, 0.8)
                }
            }
        }

        public var white: XYZ
        /// Adapting-field luminance in cd/m².
        public var adaptingLuminance: Double
        /// Relative luminance of the background, on the same scale as `white.y`.
        public var backgroundLuminance: Double
        public var surround: Surround
        /// Degree of adaptation; nil computes it from the adapting luminance and surround.
        public var adaptation: Double?

        public init(white: XYZ, adaptingLuminance: Double, backgroundLuminance: Double = 20,
                    surround: Surround = .average, adaptation: Double? = nil) {
            self.white = white; self.adaptingLuminance = adaptingLuminance
            self.backgroundLuminance = backgroundLuminance; self.surround = surround; self.adaptation = adaptation
        }

        /// A desktop display judged against D65: white at Y = 100, 64 cd/m² adapting field
        /// (20 % of a 320 cd/m² white), 20 % background, average surround. Adaptation is complete
        /// (D = 1): the question is how far a white is from D65 for a viewer adapted to D65, so the
        /// target itself must be neutral. CAM16's formula would give D ≈ 0.91 here and leave D65 with
        /// chroma 1.7.
        public static let displayD65 = ViewingConditions(white: Chromaticity.d65.xyz(luminance: 100), adaptingLuminance: 64,
                                                         adaptation: 1)
    }

    public struct Appearance: Sendable, Equatable {
        public let lightness: Double   // J
        public let chroma: Double      // C
        public let hue: Double         // h, degrees
        public let colourfulness: Double  // M
    }

    static let m16 = Matrix3x3([
        0.401288, 0.650173, -0.051461,
        -0.250268, 1.204414, 0.045854,
        -0.002079, 0.048952, 0.953127,
    ])

    /// XYZ (Y = 100 scale) to CAM16 J, C, h, M.
    public static func appearance(of xyz: XYZ, in conditions: ViewingConditions) -> Appearance {
        let (F, c, Nc) = conditions.surround.parameters
        let La = conditions.adaptingLuminance
        let k = 1 / (5 * La + 1)
        let k4 = pow(k, 4)
        let FL = 0.2 * k4 * (5 * La) + 0.1 * pow(1 - k4, 2) * cbrt(5 * La)
        let Yw = conditions.white.y
        let n = conditions.backgroundLuminance / Yw
        let z = 1.48 + sqrt(n)
        let Nbb = 0.725 * pow(1 / n, 0.2)
        let D = conditions.adaptation ?? min(1, max(0, F * (1 - (1 / 3.6) * exp((-La - 42) / 92))))

        let rgbW = m16.multiplied(by: conditions.white)
        let dR = D * Yw / rgbW.x + 1 - D, dG = D * Yw / rgbW.y + 1 - D, dB = D * Yw / rgbW.z + 1 - D

        func compress(_ value: Double) -> Double {
            let p = pow(FL * abs(value) / 100, 0.42)
            return (value < 0 ? -1 : 1) * 400 * p / (p + 27.13) + 0.1
        }
        let rgbAw = (compress(dR * rgbW.x), compress(dG * rgbW.y), compress(dB * rgbW.z))
        let Aw = (2 * rgbAw.0 + rgbAw.1 + 0.05 * rgbAw.2 - 0.305) * Nbb

        let rgb = m16.multiplied(by: xyz)
        let Ra = compress(dR * rgb.x), Ga = compress(dG * rgb.y), Ba = compress(dB * rgb.z)
        let a = Ra - 12 * Ga / 11 + Ba / 11
        let b = (Ra + Ga - 2 * Ba) / 9
        var h = atan2(b, a) * 180 / .pi
        if h < 0 { h += 360 }
        let et = 0.25 * (cos(h * .pi / 180 + 2) + 3.8)
        let A = (2 * Ra + Ga + 0.05 * Ba - 0.305) * Nbb
        let J = 100 * pow(max(0, A / Aw), c * z)
        let t = (50000 / 13 * Nc * Nbb * et * hypot(a, b)) / (Ra + Ga + 21 / 20 * Ba)
        let C = pow(t, 0.9) * sqrt(J / 100) * pow(1.64 - pow(0.29, n), 0.73)
        return Appearance(lightness: J, chroma: C, hue: h, colourfulness: C * pow(FL, 0.25))
    }

    /// CAM16-UCS coordinates J', a', b' (Li et al. 2017, c1 = 0.007, c2 = 0.0228).
    public static func ucs(_ appearance: Appearance) -> (J: Double, a: Double, b: Double) {
        let J = 1.7 * appearance.lightness / (1 + 0.007 * appearance.lightness)
        let M = log(1 + 0.0228 * appearance.colourfulness) / 0.0228
        let h = appearance.hue * .pi / 180
        return (J, M * cos(h), M * sin(h))
    }

    /// Euclidean ΔE' in CAM16-UCS (K_L = 1).
    public static func deltaE(_ lhs: XYZ, _ rhs: XYZ, in conditions: ViewingConditions = .displayD65) -> Double {
        let p = ucs(appearance(of: lhs, in: conditions)), q = ucs(appearance(of: rhs, in: conditions))
        return sqrt(pow(p.J - q.J, 2) + pow(p.a - q.a, 2) + pow(p.b - q.b, 2))
    }
}
