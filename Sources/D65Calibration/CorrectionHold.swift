import D65Core
import D65Display
import Foundation

/// Holds one display's correction after a session, outside the engine.
///
/// The engine always restores what it changed; keeping a result is a separate, explicit step owned by a
/// long-lived agent. macOS reverts the table when this process exits, which is the crash-safe default.
@MainActor public final class CorrectionHold {
    public enum State: String, Sendable, Equatable {
        case none
        /// Applied while the user reviews it; not yet stored.
        case previewing
        case held
        /// Correction known but temporarily not applied (user toggle or before recalibrating).
        case paused
    }

    public private(set) var state: State = .none
    public private(set) var gains: RGBGains?
    public private(set) var gamma: Double = 2.2
    private let backend: any TransferTableBackend
    private var transaction: TransferTableTransaction?

    public init(backend: any TransferTableBackend) { self.backend = backend }

    public func preview(_ gains: RGBGains, gamma: Double) throws { try apply(gains, gamma: gamma, as: .previewing) }
    public func hold(_ gains: RGBGains, gamma: Double) throws { try apply(gains, gamma: gamma, as: .held) }

    /// Promote a preview to a held correction.
    public func keep() {
        if state == .previewing { state = .held }
    }

    /// Paused keeps the correction in memory and shows the original table.
    public func setPaused(_ paused: Bool) throws {
        guard let gains else { return }
        if paused {
            guard state == .held || state == .previewing else { return }
            try restoreBaseline()
            state = .paused
        } else if state == .paused {
            try apply(gains, gamma: gamma, as: .held)
        }
    }

    /// Show the original while comparing, without changing the stored state.
    public func showOriginal(_ original: Bool) throws {
        guard let gains, state == .held || state == .previewing else { return }
        if original { try restoreBaseline() }
        else { try writeGains(gains, gamma: gamma) }
    }

    /// Write the correction again after the system may have reset the table (reconnect, mode change).
    public func reassert() throws {
        guard let gains, state == .held || state == .previewing else { return }
        try restoreBaseline()
        try writeGains(gains, gamma: gamma)
    }

    /// Restore the display and forget the correction.
    public func release() throws {
        defer { state = .none; gains = nil }
        try restoreBaseline()
    }

    private func apply(_ gains: RGBGains, gamma: Double, as next: State) throws {
        try writeGains(gains, gamma: gamma)
        self.gains = gains; self.gamma = gamma; state = next
    }

    private func writeGains(_ gains: RGBGains, gamma: Double) throws {
        if transaction == nil {
            let transaction = TransferTableTransaction(backend: backend)
            try transaction.begin()
            self.transaction = transaction
        }
        try transaction?.setCumulativeGains(gains, gamma: gamma)
    }

    private func restoreBaseline() throws {
        guard let transaction else { return }
        self.transaction = nil
        try transaction.restore()
    }
}
