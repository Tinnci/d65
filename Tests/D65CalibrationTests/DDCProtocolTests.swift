import D65Display
import Foundation
import XCTest

/// A DDC/CI monitor on a fake I2C bus: validates request checksums, answers Get VCP, applies Set VCP,
/// serves the capabilities string in 32-byte chunks, and notices packets from interleaved exchanges.
final class FakeMonitor: DDCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt8: (current: UInt16, maximum: UInt16)]
    private var reply: [UInt8]?
    private var lastWriter: Thread?
    let capabilities: [UInt8]
    var capabilitiesSeed: UInt8 = 0x6E ^ 0x51
    var capabilitiesOffsetSkew: UInt16 = 0
    var failingReads = 0
    var clock: VirtualClock?
    private(set) var interleaved = 0
    private(set) var writeTimes: [TimeInterval] = []
    private(set) var readTimes: [TimeInterval] = []
    private(set) var capabilityRequests = 0

    init(values: [UInt8: (UInt16, UInt16)] = [:], capabilities: String = "") {
        self.values = values.mapValues { (current: $0.0, maximum: $0.1) }
        self.capabilities = Array(capabilities.utf8)
    }

    func value(_ code: UInt8) -> UInt16? { lock.withLock { values[code]?.current } }
    func setFailingReads(_ count: Int) { lock.withLock { failingReads = count } }

    func write(_ packet: [UInt8]) -> Bool {
        lock.withLock {
            writeTimes.append(clock?.now ?? 0)
            lastWriter = Thread.current
            reply = nil
            guard packet.count >= 3, Int(packet[0] & 0x7F) == packet.count - 2 else { return false }
            let body = Array(packet.dropLast())
            let opcode = packet[1]
            let seed: UInt8 = opcode == 0x01 ? 0x6E : opcode == 0xF3 ? capabilitiesSeed : 0x6E ^ 0x51
            guard body.reduce(seed, ^) == packet.last else { return true } // acked on the bus, ignored by the monitor
            switch opcode {
            case 0x01:
                let code = packet[2]
                if let value = values[code] {
                    reply = Self.frame([0x02, 0x00, code, 0x00, UInt8(value.maximum >> 8), UInt8(value.maximum & 255),
                                        UInt8(value.current >> 8), UInt8(value.current & 255)])
                } else {
                    reply = Self.frame([0x02, 0x01, code, 0, 0, 0, 0, 0])
                }
            case 0x03:
                let code = packet[2], value = UInt16(packet[3]) << 8 | UInt16(packet[4])
                if values[code] != nil { values[code]!.current = value }
            case 0xF3:
                capabilityRequests += 1
                let offset = Int(UInt16(packet[2]) << 8 | UInt16(packet[3]))
                let chunk = Array(capabilities.dropFirst(offset).prefix(32))
                let reported = UInt16(offset) &+ capabilitiesOffsetSkew
                reply = Self.frame([0xE3, UInt8(reported >> 8), UInt8(reported & 255)] + chunk)
            default: break
            }
            return true
        }
    }

    func read(count: Int) -> [UInt8]? {
        lock.withLock {
            readTimes.append(clock?.now ?? 0)
            if lastWriter !== Thread.current { interleaved += 1 }
            if failingReads > 0 { failingReads -= 1; return nil }
            guard let reply else { return [UInt8](repeating: 0x5A, count: count) } // garbage on the bus
            return Array((reply + [UInt8](repeating: 0, count: max(0, count - reply.count))).prefix(count))
        }
    }

    static func frame(_ payload: [UInt8]) -> [UInt8] {
        let bytes: [UInt8] = [0x6E, 0x80 | UInt8(payload.count)] + payload
        return bytes + [bytes.reduce(0x50, ^)]
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 100
    var now: TimeInterval { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += max(0, seconds) } }
    var timing: DDCTiming { DDCTiming(sleep: { [self] in advance($0) }, now: { [self] in now }) }
}

final class DDCProtocolTests: XCTestCase {
    private let capabilityString = "(prot(monitor)type(LCD)model(K27)cmds(01 02 03 07 0C E3 F3)vcp(02 04 05 08 10 12 14(05 08 0B) 16 18 1A 52 60(0F 11 12) 6C 6E 70 AC AE B6 C8 C9 D6(01 04) DC DF)mccs_ver(2.2)mswhql(1))"

    private func endpoint(_ monitor: FakeMonitor) -> (DDCDisplay, VirtualClock) {
        let clock = VirtualClock()
        monitor.clock = clock
        return (DDCDisplay(transport: monitor, timing: clock.timing), clock)
    }

    func testReadAndWriteRoundTripThroughChecksummedPackets() {
        let monitor = FakeMonitor(values: [0x12: (50, 100)])
        let (ddc, _) = endpoint(monitor)
        XCTAssertEqual(ddc.read(0x12), DDCValue(current: 50, maximum: 100))
        XCTAssertTrue(ddc.write(0x12, value: 65))
        XCTAssertEqual(monitor.value(0x12), 65, "the Set VCP packet must carry the host-address checksum")
        XCTAssertEqual(ddc.read(0x12)?.current, 65)
        XCTAssertNil(ddc.read(0x8A), "unsupported codes answer with a non-zero result")
    }

    func testCapabilitiesAreAssembledFromChunksParsedAndCached() throws {
        let monitor = FakeMonitor(capabilities: capabilityString)
        let (ddc, _) = endpoint(monitor)
        let capabilities = try XCTUnwrap(ddc.capabilities())
        XCTAssertEqual(capabilities.raw, capabilityString)
        XCTAssertEqual(ddc.statistics.exchanges, (capabilityString.utf8.count + 31) / 32 + 1, "chunks plus the empty terminator")
        XCTAssertEqual(capabilities.model, "K27")
        XCTAssertEqual(capabilities.mccsVersion, "2.2")
        XCTAssertEqual(capabilities.values(for: 0x14), [0x05, 0x08, 0x0B])
        XCTAssertEqual(capabilities.values(for: 0x60), [0x0F, 0x11, 0x12])
        XCTAssertNil(capabilities.values(for: 0x10), "continuous controls list no values")
        XCTAssertTrue(capabilities.supports(0xDC))
        XCTAssertFalse(capabilities.supports(0x0C))
        XCTAssertEqual(capabilities.commands, [0x01, 0x02, 0x03, 0x07, 0x0C, 0xE3, 0xF3])
        let exchanges = ddc.statistics.exchanges
        XCTAssertNotNil(ddc.capabilities())
        XCTAssertEqual(ddc.statistics.exchanges, exchanges, "read once per endpoint")
    }

    func testCapabilitiesFallBackToTheGetChecksumQuirk() {
        let monitor = FakeMonitor(capabilities: capabilityString)
        monitor.capabilitiesSeed = 0x6E
        let (ddc, _) = endpoint(monitor)
        XCTAssertEqual(ddc.capabilities()?.model, "K27")
    }

    func testCapabilitiesRejectAReplyForTheWrongOffset() {
        let monitor = FakeMonitor(capabilities: capabilityString)
        monitor.capabilitiesOffsetSkew = 32
        let (ddc, _) = endpoint(monitor)
        XCTAssertNil(ddc.readCapabilitiesString())
    }

    func testExchangesAreSpacedByTheMinimumInterval() {
        let monitor = FakeMonitor(values: [0x10: (30, 100), 0x12: (50, 100)])
        let (ddc, _) = endpoint(monitor)
        _ = ddc.read(0x10)
        let firstReplyAt = monitor.readTimes.last!
        _ = ddc.read(0x12)
        let secondRequestAt = monitor.writeTimes[2]
        XCTAssertGreaterThanOrEqual(secondRequestAt - firstReplyAt, 0.05)
    }

    func testStatisticsCountRetriesAndConsecutiveFailures() {
        let monitor = FakeMonitor(values: [0x12: (50, 100)])
        let (ddc, _) = endpoint(monitor)
        monitor.setFailingReads(2)
        XCTAssertNotNil(ddc.read(0x12))
        XCTAssertEqual(ddc.statistics.retries, 2)
        monitor.setFailingReads(8)
        XCTAssertNil(ddc.read(0x12))
        XCTAssertNil(ddc.read(0x12))
        XCTAssertEqual(ddc.statistics.consecutiveFailures, 2)
        XCTAssertEqual(ddc.statistics.failures, 2)
        XCTAssertNotNil(ddc.read(0x12))
        XCTAssertEqual(ddc.statistics.consecutiveFailures, 0)
        XCTAssertGreaterThan(ddc.statistics.longestDuration, 0)
    }

    func testConcurrentCallersNeverInterleaveOnOneEndpoint() {
        let monitor = FakeMonitor(values: [0x10: (30, 100), 0x12: (50, 100), 0x14: (5, 12)])
        // Real (tiny) sleeps so unserialized callers would genuinely overlap.
        let timing = DDCTiming(sleep: { Thread.sleep(forTimeInterval: $0 / 100) },
                               now: { ProcessInfo.processInfo.systemUptime }, minimumInterval: 0.0005)
        let ddc = DDCDisplay(transport: monitor, timing: timing)
        let codes: [UInt8] = [0x10, 0x12, 0x14]
        let expected: [UInt8: UInt16] = [0x10: 30, 0x12: 50, 0x14: 5]
        let mismatches = Counter()
        DispatchQueue.concurrentPerform(iterations: 48) { index in
            let code = codes[index % 3]
            if ddc.read(code)?.current != expected[code] { mismatches.increment() }
        }
        XCTAssertEqual(monitor.interleaved, 0)
        XCTAssertEqual(mismatches.value, 0)
        XCTAssertEqual(ddc.statistics.exchanges, 48)
    }
}

final class MCCSCapabilitiesTests: XCTestCase {
    func testLenientParsing() throws {
        let runTogether = try XCTUnwrap(MCCSCapabilities("prot(monitor) type(lcd) vcp(10121416 14(010B) 60(0f11)) mccs_ver(2.1)"))
        XCTAssertTrue([0x10, 0x12, 0x14, 0x16, 0x60].allSatisfy(runTogether.supports))
        XCTAssertEqual(runTogether.values(for: 0x14), [0x01, 0x0B])
        XCTAssertEqual(runTogether.values(for: 0x60), [0x0F, 0x11])
        XCTAssertEqual(runTogether.mccsVersion, "2.1")

        let nested = try XCTUnwrap(MCCSCapabilities("(vcp(02 10 DC(00 02 03 (05)) DF) model(X))\0\0"))
        XCTAssertEqual(nested.values(for: 0xDC), [0x00, 0x02, 0x03, 0x05])
        XCTAssertTrue(nested.supports(0xDF))
        XCTAssertEqual(nested.model, "X")

        XCTAssertNil(MCCSCapabilities("(prot(monitor)type(lcd))"), "no vcp section")
    }

    /// Captured from the HAN K27 over USB-C on 2026-10-25 with `d65 ddc capabilities`.
    func testHANK27CapabilitiesString() throws {
        let raw = "(prot(monitor)type(lcd)MStarcmds(01 02 03 07 0C E3 F3)vcp(02 04 05 08 10 12 14(05 08 0B 0C) 16 18 1A 52 60( 11 12 0F) AA(01 02) AC AE B2 B6 C6 C8 C9 D6(01 04 05) DC(00 02 03 05 ) DF FD)mccs_ver(2.1)mswhql(1))"
        let k27 = try XCTUnwrap(MCCSCapabilities(raw))
        XCTAssertEqual(k27.commands, [0x01, 0x02, 0x03, 0x07, 0x0C, 0xE3, 0xF3], "recovered from the glued MStarcmds key")
        XCTAssertEqual(k27.fields["unlabelled"], "MStar")
        XCTAssertEqual(k27.mccsVersion, "2.1")
        XCTAssertEqual(k27.values(for: 0x14), [0x05, 0x08, 0x0B, 0x0C])
        XCTAssertEqual(k27.values(for: 0x60), [0x11, 0x12, 0x0F])
        XCTAssertEqual(k27.values(for: 0xDC), [0x00, 0x02, 0x03, 0x05])
        XCTAssertTrue(k27.supports(0x52) && k27.supports(0x02), "change notification is available")
        for unlisted: UInt8 in [0x0B, 0x0C, 0x6C, 0x6E, 0x70, 0x8A] {
            XCTAssertFalse(k27.supports(unlisted), String(format: "0x%02X is not advertised", unlisted))
        }
    }

    func testVocabulary() {
        XCTAssertEqual(MCCS.name(of: 0x0B), "Colour Temperature Increment")
        XCTAssertEqual(MCCS.name(of: 0x6C), "Video Black Level: Red")
        XCTAssertEqual(MCCS.name(of: 0x52), "Active Control")
        XCTAssertEqual(MCCS.presetName(0x05), "6500 K")
        XCTAssertEqual(MCCS.presetName(0x0B), "User 1")
        XCTAssertTrue(MCCS.disruptive.contains(0x60))
        XCTAssertFalse(MCCS.guardedSettings.contains { $0.code == MCCS.luminance })
    }
}

final class DDCRegistryTests: XCTestCase {
    private func edid(vendor: (UInt8, UInt8) = (0x20, 0x2E), product: UInt16 = 0x2700, serial: UInt32 = 0) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 128)
        bytes[0..<8] = [0, 255, 255, 255, 255, 255, 255, 0]
        bytes[8] = vendor.0; bytes[9] = vendor.1
        bytes[10] = UInt8(product & 255); bytes[11] = UInt8(product >> 8)
        for i in 0..<4 { bytes[12 + i] = UInt8((serial >> (8 * UInt32(i))) & 255) }
        bytes[127] = UInt8((256 - bytes.prefix(127).reduce(0) { ($0 + Int($1)) & 255 }) & 255)
        return bytes
    }

    func testEDIDIdentityValidatesAndDecodes() throws {
        let identity = try XCTUnwrap(EDIDIdentity(edid: edid(serial: 0x0102_0304)))
        XCTAssertEqual(identity, EDIDIdentity(vendor: 0x202E, product: 0x2700, serial: 0x0102_0304))
        var corrupt = edid(); corrupt[20] ^= 1
        XCTAssertNil(EDIDIdentity(edid: corrupt), "bad checksum")
        var header = edid(); header[0] = 1
        XCTAssertNil(EDIDIdentity(edid: header))
    }

    private final class Bus: @unchecked Sendable {
        var candidates: [DDCCandidate] = []
        var transportsMade = 0
        func candidate(_ entryID: UInt64, _ identity: EDIDIdentity) -> DDCCandidate {
            DDCCandidate(entryID: entryID, edid: identity, makeTransport: { [self] in
                transportsMade += 1
                return FakeMonitor(values: [0x12: (50, 100)])
            })
        }
    }

    private let k27 = EDIDIdentity(vendor: 0x202E, product: 0x2700, serial: 0)

    private func registry(_ bus: Bus, clock: VirtualClock) -> DDCRegistry {
        let identity = k27
        return DDCRegistry(enumerate: { bus.candidates }, identify: { id in id == 2 ? identity : nil }, timing: clock.timing)
    }

    func testMatchesAreCachedAndInvalidationKeepsTheSharedEndpoint() {
        let bus = Bus(), clock = VirtualClock()
        bus.candidates = [bus.candidate(7, k27), bus.candidate(8, EDIDIdentity(vendor: 1, product: 2, serial: 3))]
        let registry = registry(bus, clock: clock)
        let first = registry.display(for: 2)
        XCTAssertNotNil(first)
        XCTAssertTrue(registry.display(for: 2) === first)
        XCTAssertEqual(registry.enumerationCount, 1)
        registry.invalidate()
        XCTAssertTrue(registry.display(for: 2) === first, "same endpoint, same lock")
        XCTAssertEqual(registry.enumerationCount, 2)
        XCTAssertEqual(bus.transportsMade, 1)
    }

    func testAmbiguousPanelsAreRefusedAndMissingMatchesExpire() {
        let bus = Bus(), clock = VirtualClock()
        bus.candidates = [bus.candidate(7, k27), bus.candidate(9, k27)]
        let registry = registry(bus, clock: clock)
        XCTAssertNil(registry.display(for: 2), "two identical serial-less panels")
        XCTAssertNil(registry.display(for: 2))
        XCTAssertEqual(registry.enumerationCount, 1, "negative result cached")
        bus.candidates = [bus.candidate(7, k27)]
        clock.advance(registry.missingLifetime + 1)
        XCTAssertNotNil(registry.display(for: 2))
        XCTAssertEqual(registry.enumerationCount, 2)
    }

    func testRepeatedFailuresRebuildTheEndpoint() throws {
        let bus = Bus(), clock = VirtualClock()
        let failing = FakeMonitor(values: [0x12: (50, 100)])
        failing.setFailingReads(100)
        bus.candidates = [DDCCandidate(entryID: 7, edid: k27, makeTransport: { bus.transportsMade += 1; return failing })]
        let registry = registry(bus, clock: clock)
        let first = try XCTUnwrap(registry.display(for: 2))
        for _ in 0..<registry.failureThreshold { XCTAssertNil(first.read(0x12)) }
        bus.candidates = [bus.candidate(7, k27)]
        let rebuilt = try XCTUnwrap(registry.display(for: 2))
        XCTAssertFalse(rebuilt === first)
        XCTAssertEqual(rebuilt.read(0x12)?.current, 50)
    }
}
