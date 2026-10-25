#if os(macOS)
import AppKit
import CoreGraphics
import D65Calibration
import D65Core
import D65Display
import Foundation

/// All adapters share this selection. DDC is unavailable unless its EDID matches uniquely.
@MainActor public final class SelectedDisplay: CalibrationDisplay {
    public let screen: NSScreen
    public private(set) var context: DisplayContext
    private let transaction: TransferTableTransaction
    private let ddc: DDCDisplay?
    private let modeID: Int32?

    public init(displayID requested: UInt32? = nil) throws {
        let id = requested ?? DisplayDirectory.preferred(in: DisplayDirectory.online())?.id ?? CGMainDisplayID()
        guard let screen = NSScreen.forDisplay(id), let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
            throw CalibrationError.displayChanged
        }
        self.screen = screen
        transaction = TransferTableTransaction(backend: MacDisplayOutput(displayID: id))
        ddc = DDCDisplay.matching(displayID: id)
        let mode = CGDisplayCopyDisplayMode(id)
        modeID = mode?.ioDisplayModeID
        let identity = CFUUIDCreateString(nil, uuid)! as String
        var settings: [String: UInt16] = [:]
        // Guarded settings decide staleness later; brightness and input are recorded for context only.
        for (name, code) in MCCS.guardedSettings + [("brightness", MCCS.luminance), ("input", MCCS.inputSource)] {
            if let value = ddc?.read(code) { settings[name] = value.current }
        }
        context = DisplayContext(identity: identity, name: screen.localizedName, displayID: id,
            width: mode?.pixelWidth ?? 0, height: mode?.pixelHeight ?? 0,
            refreshRate: mode?.refreshRate ?? 0, monitorSettings: settings)
    }

    public func begin() throws {
        try validate()
        try transaction.begin()
    }
    public func validate() throws {
        guard CGDisplayIsOnline(context.displayID) != 0,
              CGDisplayCopyDisplayMode(context.displayID)?.ioDisplayModeID == modeID else {
            throw CalibrationError.displayChanged
        }
    }
    public func setCumulativeGains(_ gains: RGBGains, gamma: Double) throws {
        try validate()
        try transaction.setCumulativeGains(gains, gamma: gamma)
    }
    public func restore() throws {
        // Do not reuse a table captured in another mode. Surface the unknown restoration state.
        try validate()
        try transaction.restore()
    }
    public func readControl(_ code: UInt8) throws -> DDCValue {
        try validate()
        guard let value = ddc?.read(code) else { throw CalibrationError.controlUnavailable(code) }
        return value
    }
    public func writeControl(_ code: UInt8, value: UInt16) throws {
        try validate()
        guard let ddc else { throw CalibrationError.controlUnavailable(code) }
        guard ddc.write(code, value: value) else { throw CalibrationError.writeFailed(code) }
    }
}

/// Every online display with what the UI needs to choose and label it.
public struct DisplayInfo: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let identity: String
    public let name: String
    public let isBuiltin: Bool
    public let width: Int
    public let height: Int
    public let refreshRate: Double
    public var modeSignature: String { StoredCorrection.modeSignature(width: width, height: height, refreshRate: refreshRate) }
}

@MainActor public enum DisplayDirectory {
    public static func online() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            let mode = CGDisplayCopyDisplayMode(id)
            return DisplayInfo(id: id, identity: CFUUIDCreateString(nil, uuid)! as String, name: screen.localizedName,
                isBuiltin: CGDisplayIsBuiltin(id) != 0, width: mode?.pixelWidth ?? 0, height: mode?.pixelHeight ?? 0,
                refreshRate: mode?.refreshRate ?? 0)
        }
    }
    /// The display D65 is for: the first external one, whatever the main display is.
    public static func preferred(in displays: [DisplayInfo]) -> DisplayInfo? {
        displays.first { !$0.isBuiltin } ?? displays.first
    }
    /// Guarded settings that could be read, for display. Empty when DDC is unavailable for this display.
    public nonisolated static func monitorSettings(displayID: UInt32) -> [String: UInt16] {
        guard case .values(let values) = monitorReading(displayID: displayID) else { return [:] }
        return values.compactMapValues { $0 }
    }

    /// Read every guarded setting through the display's shared, serialized endpoint.
    /// Blocking (tens to hundreds of milliseconds per read): call off the main thread.
    public nonisolated static func monitorReading(displayID: UInt32) -> MonitorReading {
        guard let ddc = DDCDisplay.matching(displayID: displayID) else { return .unreachable }
        var values: [String: UInt16?] = [:]
        for (name, code) in MCCS.guardedSettings { values[name] = .some(ddc.read(code)?.current) }
        // A monitor that answered nothing at all is unreachable, not merely missing settings.
        return values.values.allSatisfy { $0 == nil } ? .unreachable : .values(values)
    }

    /// Ask for fresh EDID matches, e.g. after wake, when DDC endpoints may have been rebuilt.
    public nonisolated static func refreshMonitorControl() { DDCRegistry.shared.invalidate() }
}

extension NSScreen {
    var displayID: UInt32? { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
    static func forDisplay(_ id: UInt32) -> NSScreen? { screens.first { $0.displayID == id } }
}
#endif
