#if os(macOS)
import CoreGraphics
import D65Core
import Foundation

public enum DisplayOutputError: Error, Equatable {
    case readFailed(Int32)
    case writeFailed(Int32)
}

/// Applies per-channel gains to a display by scaling its existing gamma table.
///
/// Uses only public CoreGraphics API. `reset()` restores the system's ColorSync
/// state, which is what the Display pane's "Restore Defaults" does.
public struct MacDisplayOutput: DisplayOutput, TransferTableBackend {
    public let displayID: CGDirectDisplayID
    /// Effective display gamma used to convert a linear-light gain into a table scale.
    public var gamma: Double
    private var capacity: Int { max(256, Int(CGDisplayGammaTableCapacity(displayID))) }

    public init(displayID: CGDirectDisplayID = CGMainDisplayID(), gamma: Double = 2.2) {
        self.displayID = displayID
        self.gamma = gamma
    }

    public func probe() throws -> DisplayTransferSnapshot {
        var red = [Float](repeating: 0, count: capacity)
        var green = [Float](repeating: 0, count: capacity)
        var blue = [Float](repeating: 0, count: capacity)
        var sampleCount: UInt32 = 0

        let error = CGGetDisplayTransferByTable(
            displayID,
            UInt32(capacity),
            &red,
            &green,
            &blue,
            &sampleCount
        )
        guard error == .success, sampleCount > 0 else {
            throw DisplayOutputError.readFailed(error.rawValue)
        }

        let count = Int(sampleCount)
        return DisplayTransferSnapshot(
            displayID: displayID,
            red: red.prefix(count).map { Double($0) },
            green: green.prefix(count).map { Double($0) },
            blue: blue.prefix(count).map { Double($0) }
        )
    }

    /// Low-level residual operation relative to the current tables. Session code uses TransferTableTransaction.
    public func apply(_ gains: RGBGains) throws {
        try apply(gains, relativeTo: probe())
    }

    /// Set a cumulative correction relative to the captured baseline, never the current table.
    public func apply(_ gains: RGBGains, relativeTo snapshot: DisplayTransferSnapshot) throws {
        guard snapshot.displayID == displayID else { throw DisplayOutputError.writeFailed(-1) }
        let corrected = DisplayTransferSnapshot(
            displayID: displayID,
            red: GammaTable.scaledLinear(snapshot.red, by: gains.r, gamma: gamma),
            green: GammaTable.scaledLinear(snapshot.green, by: gains.g, gamma: gamma),
            blue: GammaTable.scaledLinear(snapshot.blue, by: gains.b, gamma: gamma)
        )
        try restore(corrected)
    }

    /// Restore only this display's exact captured tables, rather than global ColorSync defaults.
    public func restore(_ snapshot: DisplayTransferSnapshot) throws {
        guard snapshot.displayID == displayID, snapshot.count > 0,
              snapshot.green.count == snapshot.count, snapshot.blue.count == snapshot.count else {
            throw DisplayOutputError.writeFailed(-1)
        }
        let error = CGSetDisplayTransferByTable(displayID, UInt32(snapshot.count),
            snapshot.red.map(Float.init), snapshot.green.map(Float.init), snapshot.blue.map(Float.init))
        guard error == .success else { throw DisplayOutputError.writeFailed(error.rawValue) }
    }

    public func reset() throws {
        CGDisplayRestoreColorSyncSettings()
    }
}
#endif
