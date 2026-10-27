#if os(macOS)
import AppKit
import CoreGraphics
import D65Display

/// Keeps blocking DDC exchanges off the UI thread and drains them before calibration starts.
public actor TrayMonitorControl {
    private var suspended = false
    public init() {}

    public func setSuspended(_ value: Bool) { suspended = value }

    public func read(displayID: UInt32, identity: String) -> [MonitorAdjustment: DDCValue] {
        guard !suspended, matches(displayID, identity: identity),
              let endpoint = DDCDisplay.matching(displayID: displayID) else { return [:] }
        var values: [MonitorAdjustment: DDCValue] = [:]
        for control in MonitorAdjustment.allCases { values[control] = control.read(from: endpoint) }
        return values
    }

    public func set(_ control: MonitorAdjustment, value: UInt16, maximum: UInt16,
                    displayID: UInt32, identity: String) throws -> DDCValue {
        guard !suspended, matches(displayID, identity: identity),
              let endpoint = DDCDisplay.matching(displayID: displayID) else { throw AdjustmentError.unavailable }
        return try control.set(value, maximum: maximum, on: endpoint)
    }

    private func matches(_ displayID: UInt32, identity: String) -> Bool {
        guard CGDisplayIsOnline(displayID) != 0, CGDisplayIsAsleep(displayID) == 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let actual = CFUUIDCreateString(nil, uuid) else { return false }
        return actual as String == identity
    }
}
#endif
