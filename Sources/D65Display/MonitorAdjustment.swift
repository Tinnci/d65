import Foundation

/// Continuous hardware controls exposed in the menu bar. Values use the monitor's own range.
public enum MonitorAdjustment: UInt8, CaseIterable, Sendable {
    case brightness = 0x10
    case contrast = 0x12
    case volume = 0x62

    public var title: String {
        switch self {
        case .brightness: "Brightness"
        case .contrast: "Contrast"
        case .volume: "Volume"
        }
    }

    public func read(from display: DDCDisplay) -> DDCValue? {
        guard let value = display.read(rawValue), value.maximum > 0,
              value.current <= value.maximum else { return nil }
        return value
    }

    /// A bus acknowledgement alone doesn't establish that the monitor accepted the setting.
    public func set(_ requested: UInt16, maximum: UInt16, on display: DDCDisplay) throws -> DDCValue {
        guard maximum > 0 else { throw AdjustmentError.unavailable }
        let target = min(requested, maximum)
        guard display.write(rawValue, value: target) else { throw AdjustmentError.writeFailed }
        guard let actual = read(from: display) else { throw AdjustmentError.unverified }
        guard actual.current == target else { throw AdjustmentError.notAccepted(actual) }
        return actual
    }
}

public enum AdjustmentError: Error, Sendable {
    case unavailable, writeFailed, unverified
    case notAccepted(DDCValue)
}
