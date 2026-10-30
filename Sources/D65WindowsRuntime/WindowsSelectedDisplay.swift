#if os(Windows)
import D65Calibration
import D65Core
import D65Display
import Foundation

/// The display being calibrated: its gamma ramp, its DDC/CI controls and the mode it was in.
@MainActor public final class WindowsSelectedDisplay: CalibrationDisplay {
    public let display: WindowsDisplay
    public private(set) var context: DisplayContext
    private let transaction: TransferTableTransaction
    private let monitor: WindowsMonitorControl?

    public init(displayID: UInt32) throws {
        guard let display = WindowsDisplayDirectory.display(id: displayID) else { throw CalibrationError.displayChanged }
        self.display = display
        transaction = TransferTableTransaction(backend: WindowsGammaBackend(display: display))
        monitor = WindowsMonitorControl(display: display)
        var settings: [String: UInt16] = [:]
        // Guarded settings decide staleness later; brightness and input are recorded for context only.
        for (name, code) in MCCS.guardedSettings + [("brightness", MCCS.luminance), ("input", MCCS.inputSource)] {
            if let value = monitor?.read(code) { settings[name] = value.current }
        }
        context = DisplayContext(identity: display.identity, name: display.name, displayID: display.id,
            width: display.width, height: display.height, refreshRate: display.refreshRate, monitorSettings: settings)
    }

    public func begin() throws {
        try validate()
        try transaction.begin()
    }
    public func validate() throws {
        guard let mode = WindowsDisplayDirectory.currentMode(deviceName: display.deviceName),
              mode.width == display.width, mode.height == display.height, mode.refresh == display.refreshRate else {
            throw CalibrationError.displayChanged
        }
    }
    public func setCumulativeGains(_ gains: RGBGains, gamma: Double) throws {
        try validate()
        try transaction.setCumulativeGains(gains, gamma: gamma)
    }
    public func restore() throws {
        // Unlike macOS, Windows keeps a ramp after the process exits, so restore even across a mode change.
        try transaction.restore()
    }
    public func readControl(_ code: UInt8) throws -> DDCValue {
        try validate()
        guard let value = monitor?.read(code) else { throw CalibrationError.controlUnavailable(code) }
        return value
    }
    public func writeControl(_ code: UInt8, value: UInt16) throws {
        try validate()
        guard let monitor else { throw CalibrationError.controlUnavailable(code) }
        guard monitor.write(code, value: value) else { throw CalibrationError.writeFailed(code) }
    }
}
#endif
