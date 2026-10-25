import D65Core
import D65Link
import D65Measurement
import XCTest

final class CalibrationMessageTests: XCTestCase {
    private let sample = MeasurementSampleStub.make()

    func testRoundTrip() throws {
        let messages: [CalibrationMessage] = [
            .hello(deviceModel: "iPhone15,2", build: "21A360"),
            .sensorCalibration(channels: [0.9, 1.1, 0.7], wavelengths: [450, 550, 650]),
            .ready(options: ["patches": 5]),
            .sample(sample),
            .progress(phase: "white", fraction: 0.4),
            .result(gains: RGBGains(r: 0.92, g: 0.97, b: 1), preDeltaE: 12, postDeltaE: 2.1, verdict: .improved),
            .failure(code: 3, message: "sensor unavailable"),
        ]

        for message in messages {
            let frame = try MessageFraming.encode(message)
            XCTAssertEqual(try MessageFraming.decode(frame), message)
        }
    }

    func testDrainLeavesPartialFrameInBuffer() throws {
        let first = try MessageFraming.encode(.ready(options: [:]))
        let second = try MessageFraming.encode(.sample(sample))

        var buffer = Data()
        buffer.append(first)
        buffer.append(second.prefix(second.count - 3))

        let messages = try MessageFraming.drain(&buffer)
        XCTAssertEqual(messages, [.ready(options: [:])])
        XCTAssertFalse(buffer.isEmpty)

        buffer.append(second.suffix(3))
        XCTAssertEqual(try MessageFraming.drain(&buffer), [.sample(sample)])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testRejectsMalformedPayload() {
        var frame = try! MessageFraming.encode(.ready(options: [:]))
        frame.replaceSubrange(4..<frame.count, with: Data("{}".utf8))
        XCTAssertThrowsError(try MessageFraming.decode(frame))
    }
}

private enum MeasurementSampleStub {
    static func make() -> MeasurementSample {
        MeasurementSample(
            xyz: XYZ(x: 0.9505, y: 1.0, z: 1.089),
            lux: 120,
            channels: [0.4, 0.5, 0.6],
            reportedCCT: 6504,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            deviceModel: "iPhone15,2"
        )
    }
}
