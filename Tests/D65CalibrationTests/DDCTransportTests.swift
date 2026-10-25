#if os(macOS)
import D65Display
import XCTest

final class DDCTransportTests: XCTestCase {
    func testSuccessfulRequestWriteDoesNotHideFailedRead() {
        XCTAssertNil(DDCDisplay(transport: StubTransport(reply: nil)).read(0x10))
    }
    func testRejectsUnsupportedAndWrongControlRepliesDespiteValidChecksum() {
        XCTAssertNil(DDCDisplay(transport: StubTransport(reply: reply(code: 0x12))).read(0x10))
        XCTAssertNil(DDCDisplay(transport: StubTransport(reply: reply(code: 0x10, status: 1))).read(0x10))
    }
    func testDecodesValidReplyIncludingRealZero() {
        let value = DDCDisplay(transport: StubTransport(reply: reply(code: 0x10))).read(0x10)
        XCTAssertEqual(value, DDCValue(current: 0, maximum: 100))
    }
    private func reply(code: UInt8, status: UInt8 = 0) -> [UInt8] {
        var bytes: [UInt8] = [0x6E, 0x88, 0x02, status, code, 0, 0, 100, 0, 0]
        bytes.append(bytes.reduce(0x50, ^))
        return bytes
    }
}
private struct StubTransport: DDCTransport {
    let reply: [UInt8]?
    func write(_ packet: [UInt8]) -> Bool { true }
    func read(count: Int) -> [UInt8]? { reply }
}
#endif
