import D65Display
import XCTest

final class MonitorAdjustmentTests: XCTestCase {
    private func endpoint(_ transport: any DDCTransport) -> DDCDisplay {
        DDCDisplay(transport: transport, timing: VirtualClock().timing)
    }

    func testUsesHardwareRangeAndClampsWrite() throws {
        let monitor = FakeMonitor(values: [0x10: (100, 255)])
        let ddc = endpoint(monitor)
        XCTAssertEqual(MonitorAdjustment.brightness.read(from: ddc)?.maximum, 255)
        let result = try MonitorAdjustment.brightness.set(500, maximum: 255, on: ddc)
        XCTAssertEqual(result, DDCValue(current: 255, maximum: 255))
        XCTAssertEqual(monitor.value(0x10), 255)
    }

    func testUnsupportedAndInvalidRangesAreNotExposed() {
        let ddc = endpoint(FakeMonitor(values: [0x10: (0, 0), 0x12: (101, 100)]))
        XCTAssertNil(MonitorAdjustment.brightness.read(from: ddc))
        XCTAssertNil(MonitorAdjustment.contrast.read(from: ddc))
        XCTAssertNil(MonitorAdjustment.volume.read(from: ddc))
    }

    func testZeroVolumeIsValidAndOtherControlsStayUnchanged() throws {
        let monitor = FakeMonitor(values: [0x62: (25, 64), 0x10: (40, 100), 0x12: (50, 100)])
        let result = try MonitorAdjustment.volume.set(0, maximum: 64, on: endpoint(monitor))
        XCTAssertEqual(result.current, 0)
        XCTAssertEqual(monitor.value(0x10), 40)
        XCTAssertEqual(monitor.value(0x12), 50)
    }

    func testAcknowledgedButIgnoredWriteIsReportedWithActualValue() {
        let monitor = FakeMonitor(values: [0x12: (50, 100)])
        let ddc = endpoint(IgnoringWrites(monitor: monitor))
        XCTAssertThrowsError(try MonitorAdjustment.contrast.set(75, maximum: 100, on: ddc)) { error in
            guard case AdjustmentError.notAccepted(let actual) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(actual.current, 50)
        }
    }

    func testFailedWriteAndMissingReadbackAreDistinct() {
        XCTAssertThrowsError(try MonitorAdjustment.brightness.set(75, maximum: 100,
            on: endpoint(FailedTransport()))) { error in
            guard case AdjustmentError.writeFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try MonitorAdjustment.brightness.set(75, maximum: 100,
            on: endpoint(FakeMonitor()))) { error in
            guard case AdjustmentError.unverified = error else { return XCTFail("\(error)") }
        }
    }
}

private struct IgnoringWrites: DDCTransport {
    let monitor: FakeMonitor
    func write(_ packet: [UInt8]) -> Bool {
        if packet.count > 1, packet[1] == 0x03 { return true }
        return monitor.write(packet)
    }
    func read(count: Int) -> [UInt8]? { monitor.read(count: count) }
}

private struct FailedTransport: DDCTransport {
    func write(_ packet: [UInt8]) -> Bool { false }
    func read(count: Int) -> [UInt8]? { nil }
}
