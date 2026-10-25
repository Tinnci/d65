import D65Calibration
import D65Measurement
import XCTest

final class DepthAlignmentTests: XCTestCase {
    private let intrinsics = DepthCameraIntrinsics(fx: 600, fy: 600, cx: 320, cy: 240)

    private func plane(distance: Double = 0.5, tiltDegrees: Double = 0) -> [DepthPixel] {
        let a = tan(tiltDegrees * .pi / 180)
        return stride(from: 180, through: 300, by: 8).flatMap { y in
            stride(from: 260, through: 380, by: 8).map { x in
                let z = distance / (1 - a * (Double(x) - 320) / 600)
                return DepthPixel(x: Double(x), y: Double(y), meters: z)
            }
        }
    }

    func testFrontFacingPlaneHasCorrectDistanceAndZeroTilt() throws {
        let result = DepthAlignmentEstimator.estimate(plane(), intrinsics: intrinsics)
        XCTAssertEqual(result.status, .estimate)
        XCTAssertEqual(try XCTUnwrap(result.distanceMeters), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(result.tiltDegrees), 0, accuracy: 1e-9)
        XCTAssertLessThan(try XCTUnwrap(result.residualMeters), 1e-12)
        XCTAssertTrue(result.blocksColourSampling, "an estimate is not camera-off or contact authorization")
    }

    func testTiltIsRecoveredFromAThreeDimensionalPlane() throws {
        let result = DepthAlignmentEstimator.estimate(plane(tiltDegrees: 20), intrinsics: intrinsics)
        XCTAssertEqual(result.status, .estimate)
        XCTAssertEqual(try XCTUnwrap(result.distanceMeters), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(result.tiltDegrees), 20, accuracy: 1e-9)
    }

    func testPixelCoordinatesAndIntrinsicsMustScaleTogether() throws {
        let pixels = plane(tiltDegrees: 15)
        let half = pixels.map { DepthPixel(x: $0.x / 2, y: $0.y / 2, meters: $0.meters) }
        let k = DepthCameraIntrinsics(fx: 300, fy: 300, cx: 160, cy: 120)
        let original = DepthAlignmentEstimator.estimate(pixels, intrinsics: intrinsics)
        let scaled = DepthAlignmentEstimator.estimate(half, intrinsics: k)
        XCTAssertEqual(try XCTUnwrap(original.distanceMeters), try XCTUnwrap(scaled.distanceMeters), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(original.tiltDegrees), try XCTUnwrap(scaled.tiltDegrees), accuracy: 1e-10)
    }

    func testContactAndInvalidDepthNeverBecomeAValidPlacement() {
        for depth in [Double.nan, .infinity, 0, -1, 0.005, 2] {
            let pixels = plane().map { DepthPixel(x: $0.x, y: $0.y, meters: depth) }
            let result = DepthAlignmentEstimator.estimate(pixels, intrinsics: intrinsics)
            XCTAssertEqual(result.status, .noReliableDepth)
            XCTAssertNil(result.distanceMeters)
            XCTAssertNil(result.tiltDegrees)
            XCTAssertTrue(result.blocksColourSampling)
        }
        XCTAssertEqual(DepthAlignmentEstimator.estimate([], intrinsics: intrinsics).status, .noReliableDepth)
        let invalid = DepthCameraIntrinsics(fx: 0, fy: .nan, cx: 0, cy: 0)
        XCTAssertEqual(DepthAlignmentEstimator.estimate(plane(), intrinsics: invalid).status, .noReliableDepth)
    }

    func testHolesNonPlanarAndDegenerateSurfacesAreRejected() {
        let pixels = plane()
        let holes = pixels.enumerated().map { i, p in DepthPixel(x: p.x, y: p.y, meters: i % 4 == 0 ? p.meters : .nan) }
        XCTAssertEqual(DepthAlignmentEstimator.estimate(holes, intrinsics: intrinsics).status, .noReliableDepth)
        let uneven = pixels.enumerated().map { i, p in DepthPixel(x: p.x, y: p.y, meters: p.meters + (i % 2 == 0 ? 0.02 : -0.02)) }
        XCTAssertEqual(DepthAlignmentEstimator.estimate(uneven, intrinsics: intrinsics).status, .noReliableDepth)
        let line = pixels.map { DepthPixel(x: $0.x, y: 240, meters: $0.meters) }
        XCTAssertEqual(DepthAlignmentEstimator.estimate(line, intrinsics: intrinsics).status, .noReliableDepth)
    }

    func testColourSamplingWaitsForCameraShutdownAndSettling() {
        let now = Date(timeIntervalSince1970: 100)
        var gate = AlignmentSamplingGate()
        XCTAssertTrue(gate.permitsColourSample(at: now))
        gate.begin()
        XCTAssertFalse(gate.permitsColourSample(at: now.addingTimeInterval(100)), "time alone never proves camera shutdown")
        gate.cameraDidStop(at: now.addingTimeInterval(101))
        XCTAssertFalse(gate.permitsColourSample(at: now.addingTimeInterval(101.49)))
        XCTAssertTrue(gate.permitsColourSample(at: now.addingTimeInterval(101.5)))
        gate.begin()
        XCTAssertFalse(gate.permitsColourSample(at: now.addingTimeInterval(200)))
    }

    func testStaleEstimatesDisappearButDoNotUnblockColourSampling() throws {
        let now = Date(timeIntervalSince1970: 100)
        let estimate = DepthAlignmentEstimator.estimate(plane(), intrinsics: intrinsics)
        var feedback = DepthAlignmentFeedback()
        feedback.receive(estimate, at: now)
        XCTAssertEqual(feedback.visible(at: now), estimate)
        let stale = try XCTUnwrap(feedback.visible(at: now.addingTimeInterval(2)))
        XCTAssertNil(stale.distanceMeters)
        XCTAssertNil(stale.tiltDegrees)
        XCTAssertTrue(feedback.blocksColourSampling)
        feedback.receive(.init(status: .finished, message: "Camera off"), at: now.addingTimeInterval(3))
        XCTAssertFalse(feedback.blocksColourSampling)
        XCTAssertNil(feedback.visible(at: now.addingTimeInterval(5)))
        feedback.reset()
        XCTAssertNil(feedback.visible(at: now))
    }
}
