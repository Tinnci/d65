#if os(macOS)
import CoreFoundation
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

public struct DDCValue: Sendable, Equatable {
    public let current: UInt16
    public let maximum: UInt16
}

/// DDC/CI access to an external display on Apple silicon.
public final class DDCDisplay: @unchecked Sendable {
    public static let luminance: UInt8 = 0x10
    public static let contrast: UInt8 = 0x12
    public static let redGain: UInt8 = 0x16
    public static let greenGain: UInt8 = 0x18
    public static let blueGain: UInt8 = 0x1A
    public static let inputSource: UInt8 = 0x60

    private let service: CFTypeRef
    private static let sevenBitAddress: UInt8 = 0x37
    private static let dataAddress: UInt8 = 0x51

    private init(service: CFTypeRef) {
        self.service = service
    }

    /// Finds the external `DCPAVServiceProxy` and wraps it.
    public static func external() -> DDCDisplay? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("DCPAVServiceProxy"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(
                entry, "Location" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String

            guard location == "External" else { continue }
            guard let service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() else {
                continue
            }
            return DDCDisplay(service: service)
        }
        return nil
    }

    public func read(_ vcp: UInt8) -> DDCValue? {
        var send: [UInt8] = [vcp]
        var reply = [UInt8](repeating: 0, count: 11)
        guard communicate(send: &send, reply: &reply) else { return nil }
        let maximum = UInt16(reply[6]) * 256 + UInt16(reply[7])
        let current = UInt16(reply[8]) * 256 + UInt16(reply[9])
        return DDCValue(current: current, maximum: maximum)
    }

    /// Returns true when the write was acknowledged. Many displays accept the
    /// I2C write but ignore the value; verify with `read` before trusting it.
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
                let result = packet.withUnsafeMutableBytes { buffer in
                    IOAVServiceWriteI2C(
                        service,
                        UInt32(Self.sevenBitAddress),
                        UInt32(dataAddress),
                        buffer.baseAddress!,
                        UInt32(buffer.count)
                    )
                }
                success = result == 0
            }

            if !reply.isEmpty {
                usleep(50_000)
                let result = reply.withUnsafeMutableBytes { buffer in
                    IOAVServiceReadI2C(
                        service,
                        UInt32(Self.sevenBitAddress),
                        0,
                        buffer.baseAddress!,
                        UInt32(buffer.count)
                    )
                }
                if result == 0 {
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
