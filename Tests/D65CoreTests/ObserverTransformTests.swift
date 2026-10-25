import XCTest
@testable import D65Core

final class ObserverTransformTests: XCTestCase {
    /// D65 under the CIE 1931 2° CMFs, from scripts/check_cie_data.py's Decimal integration.
    private let d65In1931 = Chromaticity(x: 0.3127268710265648, y: 0.3290232066412840)

    /// A display whose primaries add up to the CIE D65 spectrum: its white is D65 for every observer.
    private func d65Split(at cuts: (Int, Int)) throws -> PrimarySpectra {
        let spectrum = try XCTUnwrap(CIESpectralData.spectrum)
        // From 360 nm, where the 1931 CMFs start: the 1931 reference integrates over 360–830 nm.
        let rows = spectrum.filter { (360.0...830.0).contains($0[0]) }
        let band = { (range: ClosedRange<Double>) in rows.map { range.contains($0[0]) ? $0[1] : 0 } }
        return try PrimarySpectra(wavelengths: rows.map { $0[0] },
                                  red: band(Double(cuts.1)...830), green: band(Double(cuts.0)...Double(cuts.1 - 1)),
                                  blue: band(360...Double(cuts.0 - 1)), source: "D65 split")
    }

    private func gaussian(_ peaks: (Double, Double, Double), width: Double) throws -> PrimarySpectra {
        let grid = stride(from: 380.0, through: 780, by: 1).map { $0 }
        let g = { (peak: Double) in grid.map { exp(-0.5 * pow(($0 - peak) / width, 2)) } }
        return try PrimarySpectra(wavelengths: grid, red: g(peaks.2), green: g(peaks.1), blue: g(peaks.0), source: "model")
    }

    func testA_D65SpectrumDisplayReadsAsD65UnderEveryObserverPair() throws {
        for cuts in [(490, 590), (480, 600), (500, 575)] {
            let spectra = try d65Split(at: cuts)
            for viewer in [Observer.cie2015TwoDegree, .cie2015TenDegree] {
                let target = try ObserverTransform.target(measuredIn: .cie1931TwoDegree, d65For: viewer, spectra: spectra)
                XCTAssertEqual(target.x, d65In1931.x, accuracy: 1e-12, "\(cuts) \(viewer)")
                XCTAssertEqual(target.y, d65In1931.y, accuracy: 1e-12, "\(cuts) \(viewer)")
            }
        }
    }

    func testMatrixMapsEachPrimaryAndInvertsExactly() throws {
        let spectra = try gaussian((460, 535, 630), width: 12)
        let p1931 = try ObserverTransform.primaryMatrix(spectra, observer: .cie1931TwoDegree)
        let p2015 = try ObserverTransform.primaryMatrix(spectra, observer: .cie2015TwoDegree)
        let forward = try ObserverTransform.matrix(from: .cie1931TwoDegree, to: .cie2015TwoDegree, spectra: spectra)
        let back = try ObserverTransform.matrix(from: .cie2015TwoDegree, to: .cie1931TwoDegree, spectra: spectra)
        for column in 0..<3 {
            let primary = XYZ(x: p1931[0, column], y: p1931[1, column], z: p1931[2, column])
            let mapped = forward.multiplied(by: primary)
            XCTAssertEqual(mapped.x, p2015[0, column], accuracy: 1e-9)
            XCTAssertEqual(mapped.y, p2015[1, column], accuracy: 1e-9)
            XCTAssertEqual(mapped.z, p2015[2, column], accuracy: 1e-9)
        }
        let product = forward.multiplied(by: back)
        for i in 0..<9 { XCTAssertEqual(product.m[i], Matrix3x3.identity.m[i], accuracy: 1e-12) }
        XCTAssertEqual(try ObserverTransform.matrix(from: .cie2015TwoDegree, to: .cie2015TwoDegree, spectra: spectra), .identity)
    }

    func testNarrowPrimariesNeedACorrectedTargetThatTheViewerSeesAsD65() throws {
        let spectra = try gaussian((465, 532, 637), width: 2)   // laser-like
        let target = try ObserverTransform.target(measuredIn: .cie1931TwoDegree, d65For: .cie2015TwoDegree, spectra: spectra)
        XCTAssertGreaterThan(hypot(target.x - d65In1931.x, target.y - d65In1931.y), 0.002, "narrow primaries shift the target")
        // Drive the display to that 1931 white, then view it with the 2015 observer: it must be D65.
        let p1931 = try ObserverTransform.primaryMatrix(spectra, observer: .cie1931TwoDegree)
        let p2015 = try ObserverTransform.primaryMatrix(spectra, observer: .cie2015TwoDegree)
        let weights = try XCTUnwrap(p1931.inverted()).multiplied(by: target.xyz())
        let seen = try XCTUnwrap(p2015.multiplied(by: weights).chromaticity)
        let d65 = try XCTUnwrap(Observer.cie2015TwoDegree.d65)
        XCTAssertEqual(seen.x, d65.x, accuracy: 1e-12)
        XCTAssertEqual(seen.y, d65.y, accuracy: 1e-12)
    }

    func testSameObserverKeepsItsStandardTarget() throws {
        let spectra = try gaussian((460, 535, 630), width: 12)
        XCTAssertEqual(try ObserverTransform.target(measuredIn: .cie1931TwoDegree, d65For: .cie1931TwoDegree, spectra: spectra), .d65)
    }

    func testImportReadsCommonLayoutsAndInterpolates() throws {
        let text = """
        # primaries measured at full drive
        nm,red,green,blue
        380,0,0,0.1
        385,0,0.1,0.3
        """ + "\n" + stride(from: 390, through: 730, by: 5).map { "\($0)\t0.\($0 % 9)\t0.2\t0.3" }.joined(separator: "\n")
        let spectra = try PrimarySpectra(csv: text, source: "test.csv")
        XCTAssertEqual(spectra.range, 380...730)
        XCTAssertEqual(spectra.power(1, at: 387.5), 0.15, accuracy: 1e-12, "linear between 385 and 390")
        XCTAssertEqual(spectra.power(0, at: 731), 0, "zero outside the measured range")
    }

    func testImportRejectsUnusableData() {
        func error(_ text: String) -> PrimarySpectra.ImportError? {
            do { _ = try PrimarySpectra(csv: text, source: "x"); return nil } catch { return error as? PrimarySpectra.ImportError }
        }
        let rows = { (range: StrideThrough<Int>) in range.map { "\($0),1,1,1" }.joined(separator: "\n") }
        XCTAssertEqual(error(rows(stride(from: 420, through: 700, by: 5))), .insufficientRange(420...700))
        XCTAssertEqual(error(rows(stride(from: 380, through: 780, by: 20))), .stepTooCoarse(20))
        XCTAssertEqual(error("400,1,1,1\n401,1,1,1\n403,1,1,1"), .unevenSteps)
        XCTAssertEqual(error("400,1,-1,1"), .negativeValue(line: 1))
        XCTAssertEqual(error("400,1,1"), .badRow(line: 1))
        XCTAssertEqual(error(stride(from: 380, through: 780, by: 5).map { "\($0),1,0,1" }.joined(separator: "\n")), .emptyPrimary("green"))
        XCTAssertEqual(error("# nothing"), .noRows)
    }
}
