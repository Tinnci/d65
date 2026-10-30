#if os(Windows)
import D65Display
import Foundation
import WinSDK

/// DDC/CI through Windows' public monitor configuration API (dxva2). Windows runs the DDC/CI
/// protocol itself, so this sits above `DDCDisplay`'s raw I²C framing. Calls block for tens of
/// milliseconds and are serialized per monitor.
public final class WindowsMonitorControl: @unchecked Sendable {
    /// PHYSICAL_MONITOR: a HANDLE followed by WCHAR[128].
    private static let recordSize = MemoryLayout<HANDLE?>.size + 128 * 2

    private typealias CountFn = @convention(c) (HMONITOR?, UnsafeMutablePointer<DWORD>?) -> WindowsBool
    private typealias GetMonitorsFn = @convention(c) (HMONITOR?, DWORD, UnsafeMutableRawPointer?) -> WindowsBool
    private typealias DestroyFn = @convention(c) (DWORD, UnsafeMutableRawPointer?) -> WindowsBool
    private typealias GetVCPFn = @convention(c) (HANDLE?, BYTE, UnsafeMutableRawPointer?, UnsafeMutablePointer<DWORD>?,
                                                 UnsafeMutablePointer<DWORD>?) -> WindowsBool
    private typealias SetVCPFn = @convention(c) (HANDLE?, BYTE, DWORD) -> WindowsBool
    private typealias CapabilitiesLengthFn = @convention(c) (HANDLE?, UnsafeMutablePointer<DWORD>?) -> WindowsBool
    private typealias CapabilitiesFn = @convention(c) (HANDLE?, UnsafeMutablePointer<CChar>?, DWORD) -> WindowsBool

    private static let count = systemFunction("dxva2.dll", "GetNumberOfPhysicalMonitorsFromHMONITOR", as: CountFn.self)
    private static let getMonitors = systemFunction("dxva2.dll", "GetPhysicalMonitorsFromHMONITOR", as: GetMonitorsFn.self)
    private static let destroy = systemFunction("dxva2.dll", "DestroyPhysicalMonitors", as: DestroyFn.self)
    private static let getVCP = systemFunction("dxva2.dll", "GetVCPFeatureAndVCPFeatureReply", as: GetVCPFn.self)
    private static let setVCP = systemFunction("dxva2.dll", "SetVCPFeature", as: SetVCPFn.self)
    private static let capabilitiesLength = systemFunction("dxva2.dll", "GetCapabilitiesStringLength", as: CapabilitiesLengthFn.self)
    private static let capabilities = systemFunction("dxva2.dll", "CapabilitiesRequestAndCapabilitiesReply", as: CapabilitiesFn.self)

    private var records: [UInt8]
    private let count: Int
    private let lock = NSLock()

    /// The monitor behind a display, or nil when Windows reports no physical monitor for it.
    public init?(display: WindowsDisplay) {
        guard let count = Self.count, let getMonitors = Self.getMonitors,
              let handle = WindowsDisplayDirectory.monitorHandle(deviceName: display.deviceName) else { return nil }
        var number: DWORD = 0
        guard count(handle, &number), number > 0 else { return nil }
        var records = [UInt8](repeating: 0, count: Int(number) * Self.recordSize)
        guard records.withUnsafeMutableBytes({ getMonitors(handle, number, $0.baseAddress) }) else { return nil }
        self.records = records; self.count = Int(number)
    }

    deinit {
        guard let destroy = Self.destroy else { return }
        let count = count
        _ = records.withUnsafeMutableBytes { destroy(DWORD(count), $0.baseAddress) }
    }

    /// The first physical monitor; a display with several (a rare splitter) is driven as one.
    private var handle: HANDLE? { records.withUnsafeBytes { $0.load(as: HANDLE?.self) } }

    public func read(_ code: UInt8) -> DDCValue? {
        guard let getVCP = Self.getVCP else { return nil }
        return lock.withLock {
            var current: DWORD = 0, maximum: DWORD = 0
            guard getVCP(handle, code, nil, &current, &maximum) else { return nil }
            return DDCValue(current: UInt16(truncatingIfNeeded: current), maximum: UInt16(truncatingIfNeeded: maximum))
        }
    }

    public func write(_ code: UInt8, value: UInt16) -> Bool {
        guard let setVCP = Self.setVCP else { return false }
        return lock.withLock { Bool(setVCP(handle, code, DWORD(value))) }
    }

    public func readCapabilitiesString() -> String? {
        guard let length = Self.capabilitiesLength, let request = Self.capabilities else { return nil }
        return lock.withLock {
            var size: DWORD = 0
            guard length(handle, &size), size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(size) + 1)
            guard request(handle, &buffer, size) else { return nil }
            return String(cString: buffer)
        }
    }
}
#endif
