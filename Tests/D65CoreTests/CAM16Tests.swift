import D65Core
import XCTest

final class CAM16Tests: XCTestCase {
    /// Reference values for CAM16 from colour-science's documented example
    /// (XYZ 19.01/20.00/21.78, D65 white 95.05/100/108.88, L_A 318.31, Y_b 20, average surround).
    func testMatchesTheReferenceExample() {
        let conditions = CAM16.ViewingConditions(white: XYZ(x: 95.05, y: 100, z: 108.88), adaptingLuminance: 318.31)
        let result = CAM16.appearance(of: XYZ(x: 19.01, y: 20.00, z: 21.78), in: conditions)
        XCTAssertEqual(result.lightness, 41.73120791, accuracy: 1e-6)
        XCTAssertEqual(result.chroma, 0.10335574, accuracy: 1e-6)
        XCTAssertEqual(result.hue, 217.06795977, accuracy: 1e-5)
        XCTAssertEqual(result.colourfulness, 0.10743677, accuracy: 1e-6)
    }

    func testAdoptedWhiteIsNeutralAndDifferenceIsZero() {
        let white = Chromaticity.d65.xyz(luminance: 100)
        let result = CAM16.appearance(of: white, in: .displayD65)
        XCTAssertEqual(result.lightness, 100, accuracy: 1e-9)
        XCTAssertEqual(result.chroma, 0, accuracy: 1e-9)
        XCTAssertEqual(CAM16.deltaE(white, white), 0, accuracy: 1e-12)
    }

    func testDifferenceGrowsAwayFromTheTarget() {
        let target = Chromaticity.d65.xyz(luminance: 100)
        let near = Chromaticity(x: 0.3110, y: 0.3270).xyz(luminance: 100)
        let far = Chromaticity(x: 0.3030, y: 0.3190).xyz(luminance: 100)
        let dNear = CAM16.deltaE(near, target), dFar = CAM16.deltaE(far, target)
        XCTAssertGreaterThan(dNear, 0)
        XCTAssertGreaterThan(dFar, dNear)
        XCTAssertEqual(CAM16.deltaE(near, target), CAM16.deltaE(target, near), accuracy: 1e-12)
    }
}
