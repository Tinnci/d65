import Foundation

/// The identity fields of a 128-byte EDID base block that CoreGraphics also reports per display.
public struct EDIDIdentity: Sendable, Hashable {
    public let vendor: UInt32
    public let product: UInt32
    public let serial: UInt32

    public init(vendor: UInt32, product: UInt32, serial: UInt32) {
        self.vendor = vendor; self.product = product; self.serial = serial
    }

    /// Validates the fixed header and the block checksum; nil for anything else.
    public init?(edid bytes: [UInt8]) {
        guard bytes.count >= 128, Array(bytes.prefix(8)) == [0, 255, 255, 255, 255, 255, 255, 0],
              bytes.prefix(128).reduce(0, { ($0 + Int($1)) & 255 }) == 0 else { return nil }
        vendor = UInt32(bytes[8]) << 8 | UInt32(bytes[9])
        product = UInt32(bytes[10]) | UInt32(bytes[11]) << 8
        serial = UInt32(bytes[12]) | UInt32(bytes[13]) << 8 | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24
    }
}

/// One external DDC endpoint found in the I/O registry.
public struct DDCCandidate: Sendable {
    /// Stable for as long as the endpoint exists; a re-plug creates a new one.
    public let entryID: UInt64
    public let edid: EDIDIdentity
    public let makeTransport: @Sendable () -> (any DDCTransport)?

    public init(entryID: UInt64, edid: EDIDIdentity, makeTransport: @escaping @Sendable () -> (any DDCTransport)?) {
        self.entryID = entryID; self.edid = edid; self.makeTransport = makeTransport
    }

    /// The single candidate whose EDID matches, or nil when none or several do. Two identical panels
    /// without serial numbers are refused rather than guessed.
    public static func unique(in candidates: [DDCCandidate], matching identity: EDIDIdentity) -> DDCCandidate? {
        let matches = candidates.filter { $0.edid == identity }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Maps displays to DDC endpoints without re-reading every EDID on every call.
///
/// Matches are cached until the display configuration changes (re-plug, wake, mode change), until a
/// cached endpoint fails repeatedly, or, for "no endpoint", for a short time, since DDC often comes
/// up a few seconds after wake. Each endpoint has exactly one `DDCDisplay`, so its lock serializes
/// every user of that bus.
public final class DDCRegistry: @unchecked Sendable {
    private enum Entry { case found(UInt64), missing(since: TimeInterval) }

    private let enumerate: @Sendable () -> [DDCCandidate]
    private let identify: @Sendable (UInt32) -> EDIDIdentity?
    private let timing: DDCTiming
    private let lock = NSLock()
    private var entries: [UInt32: Entry] = [:]
    private var endpoints: [UInt64: DDCDisplay] = [:]
    /// How long "no endpoint" is believed before asking the registry again.
    public var missingLifetime: TimeInterval = 10
    /// Consecutive failed exchanges after which a cached endpoint is re-matched and rebuilt.
    public var failureThreshold = 3
    public private(set) var enumerationCount = 0

    public init(enumerate: @escaping @Sendable () -> [DDCCandidate], identify: @escaping @Sendable (UInt32) -> EDIDIdentity?,
                timing: DDCTiming = .system) {
        self.enumerate = enumerate; self.identify = identify; self.timing = timing
    }

    public func display(for displayID: UInt32) -> DDCDisplay? {
        lock.lock()
        defer { lock.unlock() }
        switch entries[displayID] {
        case .found(let entryID)?:
            if let endpoint = endpoints[entryID], endpoint.statistics.consecutiveFailures < failureThreshold { return endpoint }
            endpoints[entryID] = nil   // stale service: rebuild its transport on re-match
        case .missing(let since)?:
            if timing.now() - since < missingLifetime { return nil }
        case nil:
            break
        }
        return match(displayID)
    }

    /// Forget every display→endpoint match. Endpoint objects survive, so a re-match of the same
    /// endpoint keeps sharing one lock with anyone still holding it.
    public func invalidate() {
        lock.withLock { entries.removeAll() }
    }

    private func match(_ displayID: UInt32) -> DDCDisplay? {
        enumerationCount += 1
        guard let identity = identify(displayID),
              let candidate = DDCCandidate.unique(in: enumerate(), matching: identity) else {
            entries[displayID] = .missing(since: timing.now())
            return nil
        }
        if let endpoint = endpoints[candidate.entryID] {
            entries[displayID] = .found(candidate.entryID)
            return endpoint
        }
        guard let transport = candidate.makeTransport() else {
            entries[displayID] = .missing(since: timing.now())
            return nil
        }
        let endpoint = DDCDisplay(transport: transport, timing: timing)
        endpoints[candidate.entryID] = endpoint
        entries[displayID] = .found(candidate.entryID)
        return endpoint
    }
}

#if os(macOS)
import CoreGraphics
import IOKit

@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32,
                                _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ dataAddress: UInt32,
                                 _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

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

extension DDCRegistry {
    /// The process-wide registry over Apple silicon's external `DCPAVServiceProxy` endpoints,
    /// invalidated by CoreGraphics on every display reconfiguration.
    public static let shared: DDCRegistry = {
        let registry = DDCRegistry(enumerate: avServiceCandidates, identify: { id in
            EDIDIdentity(vendor: CGDisplayVendorNumber(id), product: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id))
        })
        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            guard !flags.contains(.beginConfigurationFlag), let context else { return }
            Unmanaged<DDCRegistry>.fromOpaque(context).takeUnretainedValue().invalidate()
        }, Unmanaged.passUnretained(registry).toOpaque())
        return registry
    }()

    private static func avServiceCandidates() -> [DDCCandidate] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var candidates: [DDCCandidate] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            var entryID: UInt64 = 0
            guard location == "External", IORegistryEntryGetRegistryEntryID(entry, &entryID) == KERN_SUCCESS,
                  let service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            var edid = [UInt8](repeating: 0, count: 128)
            let result = edid.withUnsafeMutableBytes { IOAVServiceReadI2C(service, 0x50, 0, $0.baseAddress!, 128) }
            guard result == 0, let identity = EDIDIdentity(edid: edid) else { continue }
            let transport = AVDDCTransport(service: service)
            candidates.append(DDCCandidate(entryID: entryID, edid: identity, makeTransport: { transport }))
        }
        return candidates
    }
}

extension DDCDisplay {
    /// The shared, serialized endpoint for a display, matched by EDID and cached by `DDCRegistry.shared`.
    public static func matching(displayID: CGDirectDisplayID) -> DDCDisplay? {
        DDCRegistry.shared.display(for: displayID)
    }
}
#endif
