import D65Core
import XCTest

final class GammaTableTests: XCTestCase {
    func testIdentityGainLeavesTableUnchanged() {
        let base = GammaTable.ramp(count: 256)
        XCTAssertEqual(GammaTable.scaled(base, by: 1), base)
    }

    func testGainScalesAndClamps() {
        let base = [0.0, 0.25, 0.5, 0.75, 1.0]
        XCTAssertEqual(GammaTable.scaled(base, by: 0.5), [0.0, 0.125, 0.25, 0.375, 0.5])
        // Gains above 1 are clamped, matching RGBGains.attenuated(): this adapter
        // attenuates, it does not brighten.
        XCTAssertEqual(GammaTable.scaled(base, by: 2.0), base)
        XCTAssertEqual(GammaTable.scaled([0.5, 1.2], by: 1), [0.5, 1.0])
        XCTAssertEqual(GammaTable.scaled(base, by: 0), [0, 0, 0, 0, 0])
    }

    func testRampEndpoints() {
        XCTAssertEqual(GammaTable.ramp(count: 256).first, 0)
        XCTAssertEqual(GammaTable.ramp(count: 256).last, 1)
        XCTAssertEqual(GammaTable.ramp(count: 1), [0])
    }
}
