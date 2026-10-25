import D65Core
import D65Measurement
import XCTest

final class MeasurementCollectorTests: XCTestCase {
    func testRejectsForeignStaleSettlingAndInvalidSamples() throws {
        let start = Date(timeIntervalSince1970: 100)
        let request = MeasurementRequest(sessionID: UUID(), phase: "white", startedAt: start,
            settlingSeconds: 0.5, samplingSeconds: 2)
        func sample(session: UUID? = nil, patch: UUID? = nil, offset: Double = 1, y: Double = 100) -> TaggedMeasurement {
            TaggedMeasurement(sessionID: session ?? request.sessionID, patchID: patch ?? request.patchID,
                sample: .init(xyz: .init(x: 95, y: y, z: 109), lux: 100), receivedAt: start.addingTimeInterval(offset))
        }
        let input = [sample(), sample(), sample(), sample(session: UUID()), sample(patch: UUID()),
                     sample(offset: 0.1), sample(offset: 3), sample(y: .nan), sample(y: 1000)]
        let result = try MeasurementCollector().collect(input, for: request)
        XCTAssertEqual(result.samples.count, 3)
        XCTAssertEqual(result.rejectedCount, 6)
        XCTAssertEqual(result.mean.y, 100)
        XCTAssertEqual(result.standardError.y, 0)
    }
    func testAmbientSubtractionUsesAllThreeChannels() throws {
        let request = MeasurementRequest(sessionID: UUID(), phase: "white", startedAt: Date(), settlingSeconds: 0, samplingSeconds: 2)
        let sample = TaggedMeasurement(sessionID: request.sessionID, patchID: request.patchID,
            sample: .init(xyz: .init(x: 100, y: 110, z: 120), lux: 110), receivedAt: request.startedAt)
        let measurement = try MeasurementCollector().collect([sample, sample, sample], for: request)
        XCTAssertEqual(measurement.subtracting(.init(x: 5, y: 10, z: 15)), .init(x: 95, y: 100, z: 105))
    }
    func testBlackCanBeZeroButInsufficientSamplesFail() throws {
        let request = MeasurementRequest(sessionID: UUID(), phase: "black", startedAt: Date(),
            settlingSeconds: 0, samplingSeconds: 2)
        let sample = TaggedMeasurement(sessionID: request.sessionID, patchID: request.patchID,
            sample: .init(xyz: .zero, lux: 0), receivedAt: request.startedAt)
        XCTAssertThrowsError(try MeasurementCollector().collect([sample], for: request))
        XCTAssertEqual(try MeasurementCollector().collect([sample, sample, sample], for: request).mean, .zero)
    }
}
