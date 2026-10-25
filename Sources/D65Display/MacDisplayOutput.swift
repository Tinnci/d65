#if os(macOS)
import CoreGraphics
import D65Core
import Foundation

public enum DisplayOutputError: Error, Equatable {
    case readFailed(Int32)
    case writeFailed(Int32)
}

/// A snapshot of a display's current transfer tables.
public struct DisplayTransferSnapshot: Sendable {
    public let displayID: UInt32
    public let red: [Double]
    public let green: [Double]
    public let blue: [Double]

    public var count: Int { red.count }
}

/// Applies per-channel gains to a display by scaling its existing gamma table.
///
/// Uses only public CoreGraphics API. `reset()` restores the system's ColorSync
/// state, which is what the Display pane's "Restore Defaults" does.
public struct MacDisplayOutput: DisplayOutput {
    public let displayID: CGDirectDisplayID
    /// Effective display gamma used to convert a linear-light gain into a table scale.
    public var gamma: Double
    private static let capacity = 256

    public init(displayID: CGDirectDisplayID = CGMainDisplayID(), gamma: Double = 2.2) {
        self.displayID = displayID
        self.gamma = gamma
    }

    public func probe() throws -> DisplayTransferSnapshot {
        var red = [Float](repeating: 0, count: Self.capacity)
        var green = [Float](repeating: 0, count: Self.capacity)
        var blue = [Float](repeating: 0, count: Self.capacity)
        var sampleCount: UInt32 = 0

        let error = CGGetDisplayTransferByTable(
            displayID,
            UInt32(Self.capacity),
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

    public func apply(_ gains: RGBGains) throws {
        let snapshot = try probe()
        let blended = gains.blended()

        let red = GammaTable.scaledLinear(snapshot.red, by: blended.r, gamma: gamma).map { Float($0) }
        let green = GammaTable.scaledLinear(snapshot.green, by: blended.g, gamma: gamma).map { Float($0) }
        let blue = GammaTable.scaledLinear(snapshot.blue, by: blended.b, gamma: gamma).map { Float($0) }

        let error = CGSetDisplayTransferByTable(
            displayID,
            UInt32(snapshot.count),
            red,
            green,
            blue
        )
        guard error == .success else {
            throw DisplayOutputError.writeFailed(error.rawValue)
        }
    }

    public func reset() throws {
        CGDisplayRestoreColorSyncSettings()
    }
}
#endif
