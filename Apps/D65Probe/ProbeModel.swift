import D65Core
import D65Link
import D65Measurement
import SwiftUI
import UIKit

/// The probe's whole UI state. The phone is face-down while it works, so the states before and after
/// matter most, and haptics carry the moments in between.
@MainActor final class ProbeModel: ObservableObject {
    enum Phase: Equatable {
        case noSensor
        case searching
        case localNetworkOff(String)
        case ready
        case placing
        case measuring(phase: String, fraction: Double?)
        case result(verdict: CalibrationVerdict, before: Double, after: Double)
        case refused(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .searching
    @Published private(set) var sensorName = "No sensor"
    @Published private(set) var isSimulated = false
    @Published private(set) var lastReading: Double?

    private let link = LinkClient()
    private let stillness = StillnessMonitor()
    private var sensor: ProbeSensor?
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let notify = UINotificationFeedbackGenerator()

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        guard let sensor = SensorRegistry.make() else { phase = .noSensor; return }
        self.sensor = sensor
        sensorName = sensor.name; isSimulated = sensor.isSimulated
        stillness.start()
        link.onEvent = { [weak self] in self?.handle($0) }
        sensor.start { [weak self] sample in
            guard let self else { return }
            self.lastReading = sample.xyz.y
            self.link.sendSample(sample, stable: self.stillness.isStable)
        }
        link.start()
    }

    /// Leaving the foreground must never leave the screen at 1 % brightness.
    func didLeaveForeground() { link.restoreBrightness() }

    func stop() {
        sensor?.stop(); stillness.stop(); link.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func handle(_ event: LinkEvent) {
        switch event {
        case .searching: if !isTerminal { phase = .searching }
        case .browseFailed(let text): phase = .localNetworkOff(text)
        case .connected: phase = .ready
        case .disconnected: phase = .searching
        case .placementStarted:
            phase = .placing; impact.impactOccurred()
        case .placementEnded:
            if phase == .placing { phase = .ready }
        case .measuring(let name, let fraction):
            if case .measuring = phase {} else { impact.impactOccurred(intensity: 1) }
            phase = .measuring(phase: name, fraction: fraction)
        case .result(let verdict, let before, let after):
            phase = .result(verdict: verdict, before: before, after: after)
            notify.notificationOccurred(verdict == .rejected ? .warning : .success)
        case .sessionEnded:
            if case .measuring = phase { phase = .ready }
            if phase == .placing { phase = .ready }
        case .failure(let code, let message):
            if code == LinkFailure.busy.rawValue || code == LinkFailure.incompatible.rawValue { phase = .refused(message) }
            else { phase = .failed(message) }
            notify.notificationOccurred(.error)
        }
    }

    private var isTerminal: Bool {
        switch phase { case .refused, .noSensor: true; default: false }
    }

    /// Results stay until the Mac starts the next placement.
    func dismissResult() { phase = link.isConnected ? .ready : .searching }
}
