import D65Core
import Foundation

public protocol TransferTableBackend: Sendable {
    func probe() throws -> DisplayTransferSnapshot
    func restore(_ snapshot: DisplayTransferSnapshot) throws
}

public enum TransferTransactionError: Error { case alreadyStarted, notStarted }

/// Owns a baseline once, and resolves every cumulative correction against that baseline.
@MainActor public final class TransferTableTransaction {
    private let backend: any TransferTableBackend
    private var baseline: DisplayTransferSnapshot?
    private var changed = false
    public init(backend: any TransferTableBackend) { self.backend = backend }
    public func begin() throws {
        guard baseline == nil else { throw TransferTransactionError.alreadyStarted }
        baseline = try backend.probe()
        changed = false
    }
    public func setCumulativeGains(_ gains: RGBGains, gamma: Double) throws {
        guard let baseline else { throw TransferTransactionError.notStarted }
        let table = DisplayTransferSnapshot(displayID: baseline.displayID,
            red: GammaTable.scaledLinear(baseline.red, by: gains.r, gamma: gamma),
            green: GammaTable.scaledLinear(baseline.green, by: gains.g, gamma: gamma),
            blue: GammaTable.scaledLinear(baseline.blue, by: gains.b, gamma: gamma))
        changed = true // Even a failed backend write may have partially changed the display.
        try backend.restore(table)
    }
    public func restore() throws {
        guard let baseline else { return }
        if changed { try backend.restore(baseline) }
        self.baseline = nil
        changed = false
    }
}
