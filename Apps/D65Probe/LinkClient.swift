import D65Core
import D65Link
import D65Measurement
import Foundation
import Network
import UIKit

/// What the probe UI needs to know. The Mac owns all session state; this mirrors it.
enum LinkEvent: Equatable {
    case searching
    case browseFailed(String)
    case connected
    case disconnected
    case placementStarted
    case placementEnded
    case measuring(phase: String, fraction: Double?)
    case result(verdict: CalibrationVerdict, before: Double, after: Double)
    case sessionEnded
    case failure(code: Int, message: String)
}

/// Public networking boundary; private ALS acquisition stays in the local experiment sources.
/// The connection outlives sessions and reconnects on its own, so the phone can stay face-down.
@MainActor final class LinkClient {
    var onStatus: ((String) -> Void)?
    var onMessage: ((String) -> Void)?
    var onEvent: ((LinkEvent) -> Void)?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var buffer = Data()
    private var request: MeasurementRequest?
    private var placementID: UUID?
    private var savedBrightness: CGFloat?
    private var wanted = false
    private var refusedUntil: Date?
    var isConnected: Bool { connection != nil }
    /// True while the Mac is collecting samples, during placement or a patch.
    var isSampling: Bool { request != nil || placementID != nil }

    func start() {
        wanted = true
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Link.serviceType, domain: nil), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.connectIfNeeded(results, parameters: parameters) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed(let error), .waiting(let error):
                    let text: String
                    if case .dns(let code) = error, code == -65570 { text = "Local Network access is off for D65 Probe." }
                    else { text = "Can’t search the local network: \(error)" }
                    self?.onStatus?(text); self?.onEvent?(.browseFailed(text))
                default: break
                }
            }
        }
        browser.start(queue: .main)
        onStatus?("Searching for D65…"); onEvent?(.searching)
    }

    func stop() {
        wanted = false
        browser?.cancel(); browser = nil
        drop()
        onStatus?("Disconnected")
    }

    /// Sample from the sensor. During placement it is a preview; during a patch it is tagged.
    func sendSample(_ sample: MeasurementSample, stable: Bool = true) {
        if let request {
            guard stable else { return }
            send(.taggedSample(sessionID: request.sessionID, patchID: request.patchID, sample: sample))
        } else if let placementID {
            send(.previewSample(sessionID: placementID, sample: sample, stable: stable))
        }
    }

    /// The phone lies face-down while sampling; its own light must not reach the sensor.
    func restoreBrightness() {
        if let savedBrightness { UIScreen.main.brightness = savedBrightness }
        savedBrightness = nil
    }

    private func dim() {
        if savedBrightness == nil { savedBrightness = UIScreen.main.brightness }
        UIScreen.main.brightness = 0.01
    }

    private func connectIfNeeded(_ results: Set<NWBrowser.Result>, parameters: NWParameters) {
        guard wanted, connection == nil, let result = results.first else { return }
        if let refusedUntil, refusedUntil > Date() { return }
        let candidate = NWConnection(to: result.endpoint, using: parameters)
        connection = candidate; buffer.removeAll()
        candidate.stateUpdateHandler = { [weak self, weak candidate] state in
            Task { @MainActor in
                guard let self, let candidate, self.connection === candidate else { return }
                switch state {
                case .ready:
                    self.onStatus?("Connected"); self.onEvent?(.connected)
                    self.send(.helloV2(deviceModel: Self.deviceModel,
                        build: "probe \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"); iOS \(UIDevice.current.systemVersion)",
                        protocolVersion: Link.protocolVersion))
                    self.receive(candidate)
                case .failed, .cancelled: self.lost()
                default: break
                }
            }
        }
        candidate.start(queue: .main)
    }

    /// Connection gone: restore the screen and look for the Mac again.
    private func lost() {
        let wasConnected = connection != nil
        drop()
        if wasConnected { onStatus?("Disconnected"); onEvent?(.disconnected) }
        guard wanted else { return }
        browser?.cancel(); browser = nil
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(refusedUntil.map { max(1, $0.timeIntervalSinceNow) } ?? 1))
            if self.wanted, self.connection == nil { self.start() }
        }
    }

    private func drop() {
        connection?.cancel(); connection = nil
        buffer.removeAll(); request = nil; placementID = nil
        restoreBrightness()
    }

    private static var deviceModel: String {
        var info = utsname()
        uname(&info)
        let capacity = MemoryLayout.size(ofValue: info.machine)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
    }

    private func receive(_ candidate: NWConnection) {
        candidate.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connection === candidate else { return }
                if let data {
                    self.buffer.append(data)
                    do { for message in try MessageFraming.drain(&self.buffer) { self.handle(message) } }
                    catch { self.onMessage?("Invalid message: \(error)"); self.lost(); return }
                }
                if complete || error != nil { self.lost() }
                else { self.receive(candidate) }
            }
        }
    }

    private func send(_ message: CalibrationMessage) {
        guard let data = try? MessageFraming.encode(message) else { return }
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func handle(_ message: CalibrationMessage) {
        switch message {
        case .placementRequest(let id):
            placementID = id; dim()
            onEvent?(.placementStarted)
        case .placementEnd(let id):
            if placementID == id { placementID = nil }
            if request == nil { onEvent?(.placementEnded) }
        case .measurementRequest(let request):
            dim()
            self.request = request
            onMessage?(request.phase)
        case .measurementEnd(let sessionID, let patchID):
            if request?.sessionID == sessionID, request?.patchID == patchID { request = nil }
        case .progress(let phase, let fraction):
            onEvent?(.measuring(phase: phase, fraction: fraction))
        case .sessionEnded:
            request = nil; placementID = nil
            restoreBrightness(); onEvent?(.sessionEnded)
        case .result(let gains, let before, let after, let verdict):
            onMessage?(String(format: "%@ R=%.3f G=%.3f B=%.3f", verdict.rawValue, gains.r, gains.g, gains.b))
            request = nil; restoreBrightness()
            onEvent?(.result(verdict: verdict, before: before, after: after))
        case .failure(let code, let message):
            onMessage?(message); request = nil; restoreBrightness()
            // A busy or incompatible Mac would refuse again at once; back off before retrying.
            if code == LinkFailure.busy.rawValue || code == LinkFailure.incompatible.rawValue {
                refusedUntil = Date().addingTimeInterval(code == LinkFailure.busy.rawValue ? 10 : 3600)
            }
            onEvent?(.failure(code: code, message: message))
        default: break
        }
    }
}
