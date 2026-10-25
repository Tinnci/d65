import Foundation

/// CIE L*a*b* under a given reference white (D65 by default).
public struct Lab: Codable, Hashable, Sendable {
    public var l: Double
    public var a: Double
    public var b: Double

    public init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    public init(xyz: XYZ, white: XYZ = Chromaticity.d65.xyz()) {
        let epsilon = 216.0 / 24389.0
        let kappa = 24389.0 / 27.0

        func f(_ t: Double) -> Double {
            t > epsilon ? cbrt(t) : (kappa * t + 16) / 116
        }

        let fx = f(xyz.x / white.x)
        let fy = f(xyz.y / white.y)
        let fz = f(xyz.z / white.z)

        self.l = 116 * fy - 16
        self.a = 500 * (fx - fy)
        self.b = 200 * (fy - fz)
    }
}

public enum ColorDifference {
    /// CIEDE2000 colour difference (kL = kC = kH = 1).
    ///
    /// Reference: Sharma, Wu & Dalal (2005), "The CIEDE2000 Color-Difference
    /// Formula: Implementation Notes, Supplementary Test Data, and
    /// Mathematical Observations".
    public static func deltaE00(_ lhs: Lab, _ rhs: Lab) -> Double {
        let l1 = lhs.l, a1 = lhs.a, b1 = lhs.b
        let l2 = rhs.l, a2 = rhs.a, b2 = rhs.b

        let c1 = (a1 * a1 + b1 * b1).squareRoot()
        let c2 = (a2 * a2 + b2 * b2).squareRoot()
        let cBar = (c1 + c2) / 2
        let cBar7 = pow(cBar, 7)
        let g = 0.5 * (1 - (cBar7 / (cBar7 + pow(25, 7))).squareRoot())

        let a1p = (1 + g) * a1
        let a2p = (1 + g) * a2
        let c1p = (a1p * a1p + b1 * b1).squareRoot()
        let c2p = (a2p * a2p + b2 * b2).squareRoot()

        func hueDegrees(_ b: Double, _ ap: Double) -> Double {
            guard b != 0 || ap != 0 else { return 0 }
            var h = atan2(b, ap) * 180 / .pi
            if h < 0 { h += 360 }
            return h
        }

        let h1p = hueDegrees(b1, a1p)
        let h2p = hueDegrees(b2, a2p)

        let deltaLp = l2 - l1
        let deltaCp = c2p - c1p

        var deltahp: Double
        if c1p * c2p == 0 {
            deltahp = 0
        } else {
            deltahp = h2p - h1p
            if deltahp > 180 { deltahp -= 360 }
            if deltahp < -180 { deltahp += 360 }
        }
        let deltaHp = 2 * (c1p * c2p).squareRoot() * sin(deltahp * .pi / 360)

        let lBarP = (l1 + l2) / 2
        let cBarP = (c1p + c2p) / 2

        var hBarP: Double
        if c1p * c2p == 0 {
            hBarP = h1p + h2p
        } else if abs(h1p - h2p) <= 180 {
            hBarP = (h1p + h2p) / 2
        } else if h1p + h2p < 360 {
            hBarP = (h1p + h2p + 360) / 2
        } else {
            hBarP = (h1p + h2p - 360) / 2
        }

        let t = 1
            - 0.17 * cos((hBarP - 30) * .pi / 180)
            + 0.24 * cos(2 * hBarP * .pi / 180)
            + 0.32 * cos((3 * hBarP + 6) * .pi / 180)
            - 0.20 * cos((4 * hBarP - 63) * .pi / 180)

        let deltaTheta = 30 * exp(-pow((hBarP - 275) / 25, 2))
        let cBarP7 = pow(cBarP, 7)
        let rc = 2 * (cBarP7 / (cBarP7 + pow(25, 7))).squareRoot()
        let sl = 1 + (0.015 * pow(lBarP - 50, 2)) / (20 + pow(lBarP - 50, 2)).squareRoot()
        let sc = 1 + 0.045 * cBarP
        let sh = 1 + 0.015 * cBarP * t
        let rt = -sin(2 * deltaTheta * .pi / 180) * rc

        let termL = deltaLp / sl
        let termC = deltaCp / sc
        let termH = deltaHp / sh

        return (termL * termL + termC * termC + termH * termH + rt * termC * termH).squareRoot()
    }

    public static func deltaE00(_ lhs: XYZ, _ rhs: XYZ, white: XYZ = Chromaticity.d65.xyz()) -> Double {
        deltaE00(Lab(xyz: lhs, white: white), Lab(xyz: rhs, white: white))
    }
}
