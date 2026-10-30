#if os(macOS)
import AppKit
import D65Calibration
@_exported import D65Host
import D65Link
import Foundation
import Network

/// Network.framework listener: TCP on the probe port, advertised over Bonjour, peer-to-peer allowed.
@MainActor final class NetworkListener: ProbeListener {
    private let listener: NWListener
    private let port: UInt16

    init(port: UInt16) throws {
        guard let endpoint = NWEndpoint.Port(rawValue: port) else { throw CalibrationError.invalidConfiguration }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        listener = try NWListener(using: parameters, on: endpoint)
        listener.service = NWListener.Service(name: "D65", type: Link.serviceType)
        self.port = port
    }

    func start(onReady: @escaping () -> Void, onFailure: @escaping (String) -> Void,
               onConnection: @escaping (any ProbeConnection) -> Void) {
        let port = port
        listener.newConnectionHandler = { connection in
            Task { @MainActor in onConnection(NetworkConnection(connection)) }
        }
        listener.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state {
                case .ready: onReady()
                case .failed(let error):
                    if case .posix(let code) = error, code == .EADDRINUSE {
                        onFailure("Port \(port) is in use, possibly by d65 serve. Quit it and try again.")
                    } else { onFailure("D65 can’t listen on the local network: \(error)") }
                default: break
                }
            }
        }
        listener.start(queue: .main)
    }

    func cancel() { listener.cancel() }
}

@MainActor final class NetworkConnection: ProbeConnection {
    let connection: NWConnection
    private var closed = false
    init(_ connection: NWConnection) { self.connection = connection }

    func start(onData: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        let close = { [weak self] in
            guard let self, !self.closed else { return }
            self.closed = true; onClose()
        }
        connection.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state {
                case .failed, .cancelled: close()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive(onData: onData, onClose: close)
    }

    private func receive(onData: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty { onData(data) }
                if complete || error != nil { onClose() } else { self.receive(onData: onData, onClose: onClose) }
            }
        }
    }

    func send(_ data: Data, completion: (() -> Void)?) {
        connection.send(content: data, completion: .contentProcessed { _ in
            Task { @MainActor in completion?() }
        })
    }

    func cancel() { connection.cancel() }
}

extension HostPlatform {
    /// AppKit patch window, CoreGraphics gamma tables, IOKit DDC.
    @MainActor public static let mac = HostPlatform(
        makeOverlay: { id in NSScreen.forDisplay(id).map { ScreenPatchPresenter(screen: $0, displayID: id) } },
        makeDisplay: { id in try SelectedDisplay(displayID: id) })
}

extension CalibrationService {
    /// The Mac host: Network.framework on `port`, advertised as `_d65._tcp`.
    public convenience init(port: UInt16 = 50515, recordDirectory: URL, softwareRevision: String) throws {
        self.init(listener: try NetworkListener(port: port), platform: .mac,
                  recordDirectory: recordDirectory, softwareRevision: softwareRevision)
    }
}
#endif
