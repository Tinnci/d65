#if os(Windows)
import D65Host
import D65Link
import Foundation
import WinSDK

/// Winsock TCP listener on the probe port (IPv6 dual-stack, so IPv4 clients connect too),
/// advertised as `_d65._tcp` through Windows' DNS-SD service API (Windows 10 1809 or later).
/// Accepting and reading run on background threads; every callback is delivered on the main actor.
@MainActor public final class WinsockListener: ProbeListener {
    private let port: UInt16
    private var socket: SOCKET = ~SOCKET(0)
    private var advertisement: ServiceAdvertisement?

    public init(port: UInt16) { self.port = port }

    public func start(onReady: @escaping () -> Void, onFailure: @escaping (String) -> Void,
                      onConnection: @escaping (any ProbeConnection) -> Void) {
        var data = WSADATA()
        guard WSAStartup(0x0202, &data) == 0 else { onFailure("Winsock could not start"); return }
        let listener = WinSDK.socket(AF_INET6, Int32(SOCK_STREAM), Int32(IPPROTO_TCP.rawValue))
        guard listener != ~SOCKET(0) else { onFailure("D65 can’t open a socket: error \(WSAGetLastError())"); return }
        var off: Int32 = 0
        _ = withUnsafeBytes(of: &off) {
            setsockopt(listener, Int32(IPPROTO_IPV6.rawValue), IPV6_V6ONLY, $0.baseAddress?.assumingMemoryBound(to: CChar.self), 4)
        }
        var address = sockaddr_in6()
        address.sin6_family = ADDRESS_FAMILY(AF_INET6)
        address.sin6_port = htons(port)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, Int32(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard bound == 0, listen(listener, SOMAXCONN) == 0 else {
            let error = WSAGetLastError()
            closesocket(listener)
            onFailure(error == WSAEADDRINUSE
                ? "Port \(port) is in use, possibly by another d65 serve. Quit it and try again."
                : "D65 can’t listen on the local network: error \(error)")
            return
        }
        socket = listener
        advertisement = ServiceAdvertisement(port: port)
        if advertisement == nil {
            print("note: could not advertise _d65._tcp over DNS-SD (needs Windows 10 1809 or later)")
        }
        Thread.detachNewThread {
            while true {
                let client = accept(listener, nil, nil)
                guard client != ~SOCKET(0) else { return } // the listening socket was closed
                onMain { onConnection(WinsockConnection(socket: client)) }
            }
        }
        onReady()
    }

    public func cancel() {
        advertisement = nil
        if socket != ~SOCKET(0) { closesocket(socket); socket = ~SOCKET(0) }
    }
}

/// One accepted TCP connection.
@MainActor final class WinsockConnection: ProbeConnection {
    private let socket: SOCKET
    private var closed = false
    private let sender = DispatchQueue(label: "d65.winsock.send")

    init(socket: SOCKET) { self.socket = socket }

    func start(onData: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        let socket = socket
        Thread.detachNewThread { [weak self] in
            var buffer = [CChar](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBufferPointer { recv(socket, $0.baseAddress, Int32($0.count), 0) }
                guard count > 0 else { break }
                let data = buffer.withUnsafeBytes { Data($0.prefix(Int(count))) }
                onMain { onData(data) }
            }
            onMain {
                guard let self, !self.closed else { return }
                self.closed = true
                onClose()
            }
        }
    }

    func send(_ data: Data, completion: (() -> Void)?) {
        let socket = socket
        sender.async {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let sent = WinSDK.send(socket, raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: CChar.self),
                                           Int32(raw.count - offset), 0)
                    guard sent > 0 else { break }
                    offset += Int(sent)
                }
            }
            onMain { completion?() }
        }
    }

    func cancel() {
        let socket = socket
        // After queued sends, so a refusal message still reaches the phone before the close.
        sender.async {
            shutdown(socket, SD_BOTH)
            closesocket(socket)
        }
    }
}

/// `D65._d65._tcp.local` on this host, registered with DnsServiceRegister. Loaded at run time:
/// the DNS-SD service API is not part of Swift's WinSDK module.
final class ServiceAdvertisement {
    private typealias Construct = @convention(c) (UnsafePointer<UInt16>?, UnsafePointer<UInt16>?, UnsafeMutablePointer<DWORD>?,
        UnsafeMutableRawPointer?, WORD, WORD, WORD, DWORD, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> DWORD
    private typealias Free = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias Completion = @convention(c) (DWORD, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

    private let request: UnsafeMutableRawPointer
    private let instance: UnsafeMutableRawPointer
    private let cancel: UnsafeMutableRawPointer

    /// DNS_SERVICE_REGISTER_REQUEST on 64-bit Windows: Version, InterfaceIndex, pServiceInstance,
    /// pRegisterCompletionCallback, pQueryContext, hCredentials, unicastEnabled.
    private static let requestSize = 48

    init?(port: UInt16) {
        guard let construct = systemFunction("dnsapi.dll", "DnsServiceConstructInstance", as: Construct.self),
              let register = systemFunction("dnsapi.dll", "DnsServiceRegister", as: Register.self) else { return nil }
        var size: DWORD = 256
        var name = [UInt16](repeating: 0, count: Int(size))
        guard GetComputerNameExW(ComputerNameDnsHostname, &name, &size).boolValue else { return nil }
        let host = String(decoding: name.prefix(Int(size)), as: UTF16.self) + ".local"
        // With no IPv4 address, Windows' own mDNS responder still answers for <host>.local.
        var address = Self.ipv4Address() ?? 0
        let hasAddress = address != 0
        let created = "D65.\(Link.serviceType).local".withWide { service in
            host.withWide { host in
                withUnsafeMutablePointer(to: &address) { pointer in
                    construct(service, host, hasAddress ? pointer : nil, nil, port, 0, 0, 0, nil, nil)
                }
            }
        }
        guard let created else { return nil }
        instance = created
        request = .allocate(byteCount: Self.requestSize, alignment: 8)
        request.initializeMemory(as: UInt8.self, repeating: 0, count: Self.requestSize)
        request.storeBytes(of: 1, toByteOffset: 0, as: UInt32.self)                 // DNS_QUERY_REQUEST_VERSION1
        request.storeBytes(of: created, toByteOffset: 8, as: UnsafeMutableRawPointer.self)
        let completion: Completion = { _, _, _ in }
        request.storeBytes(of: unsafeBitCast(completion, to: UnsafeMutableRawPointer.self), toByteOffset: 16,
                           as: UnsafeMutableRawPointer.self)
        cancel = .allocate(byteCount: 8, alignment: 8)
        cancel.initializeMemory(as: UInt8.self, repeating: 0, count: 8)
        // DNS_REQUEST_PENDING: the registration completes asynchronously.
        guard register(request, cancel) == 9506 else {
            systemFunction("dnsapi.dll", "DnsServiceFreeInstance", as: Free.self)?(created)
            request.deallocate(); cancel.deallocate()
            return nil
        }
    }

    deinit {
        if let deregister = systemFunction("dnsapi.dll", "DnsServiceDeRegister", as: Register.self) {
            _ = deregister(request, nil)
        }
        systemFunction("dnsapi.dll", "DnsServiceFreeInstance", as: Free.self)?(instance)
        request.deallocate(); cancel.deallocate()
    }

    /// The host's first non-loopback IPv4 address, in network byte order, for the A record.
    private static func ipv4Address() -> DWORD? {
        var name = [CChar](repeating: 0, count: 256)
        guard gethostname(&name, Int32(name.count)) == 0 else { return nil }
        var hints = ADDRINFOA()
        hints.ai_family = AF_INET
        var result: UnsafeMutablePointer<ADDRINFOA>?
        guard getaddrinfo(name, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }
        var node: UnsafeMutablePointer<ADDRINFOA>? = first
        while let current = node {
            if let address = current.pointee.ai_addr {
                let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.S_un.S_addr }
                if ipv4 & 0xFF != 127 { return ipv4 }
            }
            node = current.pointee.ai_next
        }
        return nil
    }
}
#endif
