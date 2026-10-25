import D65Core
import XCTest

final class CIEDE2000Tests: XCTestCase {
    /// Test pairs from Sharma, Wu & Dalal (2005), table 1.
    func testSharmaReferencePairs() {
        let pairs: [(Lab, Lab, Double)] = [
            (Lab(l: 50.0000, a: 2.6772, b: -79.7751), Lab(l: 50.0000, a: 0.0000, b: -82.7485), 2.0425),
            (Lab(l: 50.0000, a: 3.1571, b: -77.2803), Lab(l: 50.0000, a: 0.0000, b: -82.7485), 2.8615),
            (Lab(l: 50.0000, a: 2.8361, b: -74.0200), Lab(l: 50.0000, a: 0.0000, b: -82.7485), 3.4412),
            (Lab(l: 50.0000, a: -1.3802, b: -84.2814), Lab(l: 50.0000, a: 0.0000, b: -82.7485), 1.0000),
            (Lab(l: 50.0000, a: -1.1848, b: -84.8006), Lab(l: 50.0000, a: 0.0000, b: -82.7485), 1.0000),
        ]

        for (lhs, rhs, expected) in pairs {
            XCTAssertEqual(ColorDifference.deltaE00(lhs, rhs), expected, accuracy: 1e-4)
            XCTAssertEqual(ColorDifference.deltaE00(rhs, lhs), expected, accuracy: 1e-4)
        }
    }

    func testIdenticalColoursHaveZeroDifference() {
        let lab = Lab(l: 42, a: 3, b: -7)
        XCTAssertEqual(ColorDifference.deltaE00(lab, lab), 0, accuracy: 1e-12)
    }

    func testD65WhiteIsNeutralInLab() {
        let lab = Lab(xyz: Chromaticity.d65.xyz())
        XCTAssertEqual(lab.a, 0, accuracy: 1e-9)
        XCTAssertEqual(lab.b, 0, accuracy: 1e-9)
        XCTAssertEqual(lab.l, 100, accuracy: 1e-9)
    }

    func testCCTApproximation() {
        XCTAssertEqual(Chromaticity.d65.correlatedColorTemperature(), 6500, accuracy: 60)
    }
}
