import D65Core
import Foundation

// DDC/CI protocol, ported from MonitorControl's Arm64DDC (MIT).
// https://github.com/MonitorControl/MonitorControl
//
// Packet layout, the Get VCP checksum quirk, retry counts and sleeps are kept from the port, which is
// verified on hardware. This file has no IOKit: the I2C transport is injected, so the protocol, the
// per-endpoint serialization and the capabilities read are testable with a fake monitor.

/// Injectable I2C boundary; a failed read is distinct from successful zero-valued data.
public protocol DDCTransport: Sendable {
    func write(_ packet: [UInt8]) -> Bool
    func read(count: Int) -> [UInt8]?
}

/// Clock and sleep for the protocol's mandatory pauses, injectable so tests do not wait.
public struct DDCTiming: Sendable {
    public var sleep: @Sendable (TimeInterval) -> Void
    public var now: @Sendable () -> TimeInterval
    /// MCCS asks the host to leave about 50 ms between one exchange's end and the next message.
    public var minimumInterval: TimeInterval

    public init(sleep: @escaping @Sendable (TimeInterval) -> Void, now: @escaping @Sendable () -> TimeInterval,
                minimumInterval: TimeInterval = 0.05) {
        self.sleep = sleep; self.now = now; self.minimumInterval = minimumInterval
    }

    public static let system = DDCTiming(sleep: { Thread.sleep(forTimeInterval: max(0, $0)) },
                                         now: { ProcessInfo.processInfo.systemUptime })
}

/// Per-endpoint counters, so poll cost and bus health can be measured instead of guessed.
public struct DDCStatistics: Sendable, Equatable {
    public var exchanges = 0
    public var retries = 0
    public var failures = 0
    public var consecutiveFailures = 0
    public var lastDuration: TimeInterval = 0
    public var longestDuration: TimeInterval = 0
}

/// One DDC/CI endpoint. Every exchange holds the endpoint's lock, so callers on different threads
/// (the agent's poll, a session's engine, the CLI) can never interleave packets on the same bus.
/// Share one instance per endpoint; `DDCRegistry` does that on macOS.
public final class DDCDisplay: @unchecked Sendable {
    public static let luminance: UInt8 = MCCS.luminance
    public static let contrast: UInt8 = MCCS.contrast
    public static let redGain: UInt8 = 0x16
    public static let greenGain: UInt8 = 0x18
    public static let blueGain: UInt8 = 0x1A
    public static let inputSource: UInt8 = MCCS.inputSource

    private static let displayAddress: UInt8 = 0x6E   // 0x37 << 1
    private static let hostAddress: UInt8 = 0x51
    private static let replyChecksumSeed: UInt8 = 0x50

    private let transport: any DDCTransport
    private let timing: DDCTiming
    private let lock = NSLock()
    private var lastExchangeEnded: TimeInterval?
    private var stats = DDCStatistics()
    private var cachedCapabilities: MCCSCapabilities??

    public init(transport: any DDCTransport, timing: DDCTiming = .system) {
        self.transport = transport; self.timing = timing
    }

    public var statistics: DDCStatistics { lock.withLock { stats } }

    // MARK: Commands

    public func read(_ vcp: UInt8) -> DDCValue? {
        guard let reply = exchange([0x01, vcp], replyCount: 11, seed: Self.displayAddress),
              reply.count >= 11, reply[1] == 0x88, reply[2] == 0x02, reply[3] == 0, reply[4] == vcp else { return nil }
        let maximum = UInt16(reply[6]) * 256 + UInt16(reply[7])
        let current = UInt16(reply[8]) * 256 + UInt16(reply[9])
        return DDCValue(current: current, maximum: maximum)
    }

    /// Returns true when the write was acknowledged. Many displays accept the
    /// I2C write but ignore the value; only a sensor measurement establishes the effect.
    @discardableResult
    public func write(_ vcp: UInt8, value: UInt16) -> Bool {
        exchange([0x03, vcp, UInt8(value >> 8), UInt8(value & 255)], replyCount: nil,
                 seed: Self.displayAddress ^ Self.hostAddress) != nil
    }

    /// The MCCS capabilities string, read once in 32-byte chunks and cached for this endpoint.
    /// Nil when the monitor does not answer the request or the string does not parse.
    public func capabilities() -> MCCSCapabilities? {
        if let cached = lock.withLock({ cachedCapabilities }) { return cached }
        let parsed = readCapabilitiesString().flatMap(MCCSCapabilities.init)
        lock.withLock { cachedCapabilities = .some(parsed) }
        return parsed
    }

    /// Raw capabilities string, without caching. Exposed for diagnostics.
    public func readCapabilitiesString(maximumLength: Int = 4096) -> String? {
        var bytes: [UInt8] = []
        // The spec checksums the request with the host address; the Get VCP quirk is tried as a fallback.
        var seeds: [UInt8] = [Self.displayAddress ^ Self.hostAddress, Self.displayAddress]
        while bytes.count < maximumLength {
            let offset = UInt16(bytes.count)
            var chunk: [UInt8]?
            for seed in seeds {
                if let reply = exchange([0xF3, UInt8(offset >> 8), UInt8(offset & 255)], replyCount: 38, seed: seed),
                   let data = Self.capabilitiesData(reply, offset: offset) {
                    chunk = data
                    seeds = [seed]
                    break
                }
            }
            guard let chunk else { return nil }
            if chunk.isEmpty { break }
            bytes += chunk
        }
        guard !bytes.isEmpty else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func capabilitiesData(_ reply: [UInt8], offset: UInt16) -> [UInt8]? {
        let length = Int(reply[1] & 0x7F)
        guard reply[2] == 0xE3, length >= 3,
              UInt16(reply[3]) << 8 | UInt16(reply[4]) == offset else { return nil }
        return Array(reply[5..<(2 + length)])
    }

    // MARK: Exchange

    /// One request/reply under the endpoint lock, with spacing, retries and a validated reply.
    /// Returns the reply (empty for a write-only command), or nil after all attempts failed.
    private func exchange(_ payload: [UInt8], replyCount: Int?, seed: UInt8) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastExchangeEnded {
            let wait = timing.minimumInterval - (timing.now() - last)
            if wait > 0 { timing.sleep(wait) }
        }
        let started = timing.now()
        var packet: [UInt8] = [0x80 | UInt8(payload.count)] + payload
        packet.append(packet.reduce(seed, ^))

        var result: [UInt8]?
        var attempts = 0
        for _ in 0..<4 {
            attempts += 1
            var written = false
            for _ in 0..<2 {
                timing.sleep(0.01)
                written = transport.write(packet)
            }
            if let replyCount {
                timing.sleep(0.05)
                if let received = transport.read(count: replyCount), let valid = Self.validated(received) {
                    result = valid
                }
            } else if written {
                result = []
            }
            if result != nil { break }
            timing.sleep(0.02)
        }

        let ended = timing.now()
        lastExchangeEnded = ended
        stats.exchanges += 1
        stats.retries += attempts - 1
        stats.lastDuration = ended - started
        stats.longestDuration = max(stats.longestDuration, stats.lastDuration)
        if result == nil { stats.failures += 1; stats.consecutiveFailures += 1 } else { stats.consecutiveFailures = 0 }
        return result
    }

    /// A reply is `0x6E, 0x80|length, payload…, checksum`, checksummed from the 0x50 seed.
    private static func validated(_ reply: [UInt8]) -> [UInt8]? {
        guard reply.count >= 3, reply[0] == displayAddress, reply[1] & 0x80 != 0 else { return nil }
        let end = 2 + Int(reply[1] & 0x7F)
        guard end < reply.count, reply[0..<end].reduce(replyChecksumSeed, ^) == reply[end] else { return nil }
        return Array(reply[...end])
    }
}
