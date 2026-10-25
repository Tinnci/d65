import D65Core
import XCTest

final class WhitePointSolverTests: XCTestCase {
    func testIdentityWhenDisplayAlreadyAtD65() {
        let gains = WhitePointSolver.gains(measuredWhite: Chromaticity.d65.xyz())
        XCTAssertEqual(gains.r, 1, accuracy: 1e-6)
        XCTAssertEqual(gains.g, 1, accuracy: 1e-6)
        XCTAssertEqual(gains.b, 1, accuracy: 1e-6)
        XCTAssertTrue(gains.isIdentity)
    }

    func testWarmDisplayIsCorrectedToD65() throws {
        // 5500 K-ish white: too much red relative to blue.
        let warm = Chromaticity(x: 0.3320, y: 0.3470).xyz(luminance: 200)
        let gains = WhitePointSolver.gains(measuredWhite: warm)

        XCTAssertLessThan(gains.r, 1.0, "red should be attenuated for a warm display")
        XCTAssertEqual(max(gains.r, gains.g, gains.b), 1.0, accuracy: 1e-9)

        let corrected = WhitePointSolver.predictedWhite(after: gains, measuredWhite: warm)
        let chromaticity = try XCTUnwrap(corrected.chromaticity)
        XCTAssertEqual(chromaticity.x, Chromaticity.d65.x, accuracy: 1e-6)
        XCTAssertEqual(chromaticity.y, Chromaticity.d65.y, accuracy: 1e-6)
    }

    func testCorrectionNeverBrightensAndKeepsLuminanceReasonable() {
        let measured = Chromaticity(x: 0.345, y: 0.355).xyz(luminance: 120)
        let gains = WhitePointSolver.gains(measuredWhite: measured)

        XCTAssertLessThanOrEqual(gains.r, 1.0 + 1e-9)
        XCTAssertLessThanOrEqual(gains.g, 1.0 + 1e-9)
        XCTAssertLessThanOrEqual(gains.b, 1.0 + 1e-9)
        XCTAssertGreaterThan(gains.luminanceScale, 0)
        XCTAssertLessThanOrEqual(gains.luminanceScale, 1.0 + 1e-9)
    }

    func testBlendTowardIdentity() {
        let gains = RGBGains(r: 0.8, g: 0.9, b: 1.0)
        let half = gains.blended(alpha: 0.5)
        XCTAssertEqual(half.r, 0.9, accuracy: 1e-12)
        XCTAssertEqual(half.g, 0.95, accuracy: 1e-12)
        XCTAssertEqual(half.b, 1.0, accuracy: 1e-12)
    }

    func testDiagonalMatrixLayout() {
        let matrix = RGBGains(r: 0.5, g: 0.75, b: 1).diagonalMatrix
        XCTAssertEqual(matrix.count, 16)
        XCTAssertEqual(matrix[0], 0.5)
        XCTAssertEqual(matrix[5], 0.75)
        XCTAssertEqual(matrix[10], 1.0)
        XCTAssertEqual(matrix[15], 1.0)
    }

    func testQualityGate() {
        let gate = QualityGate()
        XCTAssertEqual(gate.verdict(preDeltaE: 1.2, postDeltaE: 1.0), .confirmed)
        XCTAssertEqual(gate.verdict(preDeltaE: 15, postDeltaE: 2.0), .improved)
        XCTAssertEqual(gate.verdict(preDeltaE: 15, postDeltaE: 6.0), .rejected)
        XCTAssertEqual(gate.verdict(preDeltaE: 15, postDeltaE: 2.0, luminanceScale: 0.7), .rejected)
    }
}
