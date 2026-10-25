#if os(macOS)
import CoreFoundation
import CoreGraphics
import D65Core
import Foundation
import IOKit

// Minimal DDC/CI transport, ported from MonitorControl's Arm64DDC (MIT).
// https://github.com/MonitorControl/MonitorControl
//
// Packet layout, XOR checksum, retry counts and sleeps are identical; only the
// display-matching heuristics are omitted.

@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(
    _ service: CFTypeRef,
    _ chipAddress: UInt32,
    _ offset: UInt32,
    _ buffer: UnsafeMutableRawPointer,
    _ size: UInt32
) -> IOReturn

@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(
    _ service: CFTypeRef,
    _ chipAddress: UInt32,
    _ dataAddress: UInt32,
    _ buffer: UnsafeMutableRawPointer,
    _ size: UInt32
) -> IOReturn

/// Injectable I2C boundary; a failed read is distinct from successful zero-valued data.
public protocol DDCTransport: Sendable {
    func write(_ packet: [UInt8]) -> Bool
    func read(count: Int) -> [UInt8]?
}

private final class AVDDCTransport: DDCTransport, @unchecked Sendable {
    let service: CFTypeRef
    init(service: CFTypeRef) { self.service = service }
    func write(_ packet: [UInt8]) -> Bool {
        var packet = packet
        return packet.withUnsafeMutableBytes {
            IOAVServiceWriteI2C(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) == 0
        }
    }
    func read(count: Int) -> [UInt8]? {
        var reply = [UInt8](repeating: 0, count: count)
        let result = reply.withUnsafeMutableBytes {
            IOAVServiceReadI2C(service, 0x37, 0, $0.baseAddress!, UInt32($0.count))
        }
        return result == 0 ? reply : nil
    }
}

/// DDC/CI access to an external display on Apple silicon.
public final class DDCDisplay: @unchecked Sendable {
    public static let luminance: UInt8 = 0x10
    public static let contrast: UInt8 = 0x12
    public static let redGain: UInt8 = 0x16
    public static let greenGain: UInt8 = 0x18
    public static let blueGain: UInt8 = 0x1A
    public static let inputSource: UInt8 = 0x60

    private let transport: any DDCTransport
    private static let sevenBitAddress: UInt8 = 0x37
    private static let dataAddress: UInt8 = 0x51

    private init(service: CFTypeRef) {
        self.transport = AVDDCTransport(service: service)
    }

    public init(transport: any DDCTransport) { self.transport = transport }

    public func read(_ vcp: UInt8) -> DDCValue? {
        var send: [UInt8] = [vcp]
        var reply = [UInt8](repeating: 0, count: 11)
        guard communicate(send: &send, reply: &reply) else { return nil }
        guard reply[0] == 0x6E, reply[1] == 0x88, reply[2] == 0x02,
              reply[3] == 0, reply[4] == vcp else { return nil }
        let maximum = UInt16(reply[6]) * 256 + UInt16(reply[7])
        let current = UInt16(reply[8]) * 256 + UInt16(reply[9])
        return DDCValue(current: current, maximum: maximum)
    }

    /// Matches the endpoint by EDID, refusing ambiguous matches (including identical serial-less panels).
    public static func matching(displayID: CGDirectDisplayID) -> DDCDisplay? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var matches: [DDCDisplay] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            guard location == "External",
                  let service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            var edid = [UInt8](repeating: 0, count: 128)
            let result = edid.withUnsafeMutableBytes { IOAVServiceReadI2C(service, 0x50, 0, $0.baseAddress!, 128) }
            guard result == 0, Array(edid.prefix(8)) == [0, 255, 255, 255, 255, 255, 255, 0],
                  edid.reduce(0, { ($0 + Int($1)) & 255 }) == 0 else { continue }
            let vendor = UInt32(edid[8]) << 8 | UInt32(edid[9])
            let product = UInt32(edid[10]) | UInt32(edid[11]) << 8
            let serial = UInt32(edid[12]) | UInt32(edid[13]) << 8 | UInt32(edid[14]) << 16 | UInt32(edid[15]) << 24
            if vendor == CGDisplayVendorNumber(displayID), product == CGDisplayModelNumber(displayID),
               serial == CGDisplaySerialNumber(displayID) { matches.append(DDCDisplay(service: service)) }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Returns true when the write was acknowledged. Many displays accept the
    /// I2C write but ignore the value; only a sensor measurement establishes the effect.
    @discardableResult
    public func write(_ vcp: UInt8, value: UInt16) -> Bool {
        var send: [UInt8] = [vcp, UInt8(value >> 8), UInt8(value & 255)]
        var reply: [UInt8] = []
        return communicate(send: &send, reply: &reply)
    }

    private func communicate(send: inout [UInt8], reply: inout [UInt8]) -> Bool {
        let dataAddress = Self.dataAddress
        var packet: [UInt8] = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0]
        packet[packet.count - 1] = Self.checksum(
            chk: send.count == 1 ? Self.sevenBitAddress << 1 : Self.sevenBitAddress << 1 ^ dataAddress,
            data: &packet,
            start: 0,
            end: packet.count - 2
        )

        var success = false
        for _ in 0..<4 {
            for _ in 0..<2 {
                usleep(10_000)
                success = transport.write(packet)
            }

            if !reply.isEmpty {
                usleep(50_000)
                success = false
                if let received = transport.read(count: reply.count), received.count == reply.count {
                    reply = received
                    success = Self.checksum(chk: 0x50, data: &reply, start: 0, end: reply.count - 2)
                        == reply[reply.count - 1]
                }
            }

            if success { return true }
            usleep(20_000)
        }
        return success
    }

    private static func checksum(chk: UInt8, data: inout [UInt8], start: Int, end: Int) -> UInt8 {
        var value = chk
        for index in start...end { value ^= data[index] }
        return value
    }
}
#endif
