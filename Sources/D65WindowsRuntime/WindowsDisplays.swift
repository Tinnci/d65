#if os(Windows)
import D65Core
import Foundation
import WinSDK

/// One active display, from the display configuration API (names, connection type, identity) and
/// the GDI monitor list (position, size, mode).
public struct WindowsDisplay: Hashable, Sendable {
    /// The GDI number in `\\.\DISPLAYn`, which is what `--display-id` takes.
    public let id: UInt32
    /// GDI device name, e.g. `\\.\DISPLAY2`.
    public let deviceName: String
    /// The monitor's own name from its EDID, e.g. `K27`.
    public let name: String
    /// Stable for a monitor on a given connection: the target's device path.
    public let identity: String
    public let isInternal: Bool
    public let isPrimary: Bool
    /// Desktop rectangle in physical pixels (the process is per-monitor DPI aware).
    public let left: Int32, top: Int32, right: Int32, bottom: Int32
    public let width: Int, height: Int
    public let refreshRate: Double
}

public enum WindowsDisplayDirectory {
    /// Every active display.
    public static func online() -> [WindowsDisplay] {
        let monitors = gdiMonitors()
        return configuredTargets().compactMap { target in
            guard let monitor = monitors.first(where: { $0.deviceName == target.deviceName }),
                  let id = UInt32(target.deviceName.drop { !$0.isNumber }) else { return nil }
            let mode = currentMode(deviceName: target.deviceName)
            return WindowsDisplay(id: id, deviceName: target.deviceName,
                name: target.name.isEmpty ? target.deviceName : target.name,
                identity: target.devicePath.isEmpty ? target.deviceName : target.devicePath,
                isInternal: target.isInternal, isPrimary: monitor.isPrimary,
                left: monitor.rect.left, top: monitor.rect.top, right: monitor.rect.right, bottom: monitor.rect.bottom,
                width: mode?.width ?? Int(monitor.rect.right - monitor.rect.left),
                height: mode?.height ?? Int(monitor.rect.bottom - monitor.rect.top),
                refreshRate: mode?.refresh ?? 0)
        }.sorted { $0.id < $1.id }
    }

    /// The display D65 is for: the first external one, whatever the primary display is.
    public static func preferred(in displays: [WindowsDisplay]) -> WindowsDisplay? {
        displays.first { !$0.isInternal } ?? displays.first
    }

    public static func display(id: UInt32) -> WindowsDisplay? { online().first { $0.id == id } }

    /// The monitor handle for a display, for DDC/CI and DPI queries.
    static func monitorHandle(deviceName: String) -> HMONITOR? {
        gdiMonitors().first { $0.deviceName == deviceName }?.handle
    }

    /// Width, height and refresh rate of the display's current mode.
    static func currentMode(deviceName: String) -> (width: Int, height: Int, refresh: Double)? {
        var mode = DEVMODEW()
        mode.dmSize = WORD(MemoryLayout<DEVMODEW>.size)
        // ENUM_CURRENT_SETTINGS is (DWORD)-1.
        let ok = deviceName.withWide { EnumDisplaySettingsW($0, DWORD.max, &mode) }
        guard ok.boolValue else { return nil }
        return (Int(mode.dmPelsWidth), Int(mode.dmPelsHeight), Double(mode.dmDisplayFrequency))
    }

    // MARK: Display configuration

    private struct Target { let deviceName: String; let name: String; let devicePath: String; let isInternal: Bool }

    private static func configuredTargets() -> [Target] {
        let flags = UInt32(QDC_ONLY_ACTIVE_PATHS)
        var pathCount: UInt32 = 0, modeCount: UInt32 = 0
        guard GetDisplayConfigBufferSizes(flags, &pathCount, &modeCount) == 0 else { return [] }
        var paths = [DISPLAYCONFIG_PATH_INFO](repeating: DISPLAYCONFIG_PATH_INFO(), count: Int(pathCount))
        var modes = [DISPLAYCONFIG_MODE_INFO](repeating: DISPLAYCONFIG_MODE_INFO(), count: Int(modeCount))
        guard QueryDisplayConfig(flags, &pathCount, &paths, &modeCount, &modes, nil) == 0 else { return [] }
        return paths.prefix(Int(pathCount)).map { path in
            var source = DISPLAYCONFIG_SOURCE_DEVICE_NAME()
            source.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME
            source.header.size = UInt32(MemoryLayout<DISPLAYCONFIG_SOURCE_DEVICE_NAME>.size)
            source.header.adapterId = path.sourceInfo.adapterId
            source.header.id = path.sourceInfo.id
            _ = withUnsafeMutablePointer(to: &source) {
                $0.withMemoryRebound(to: DISPLAYCONFIG_DEVICE_INFO_HEADER.self, capacity: 1) { DisplayConfigGetDeviceInfo($0) }
            }
            var target = DISPLAYCONFIG_TARGET_DEVICE_NAME()
            target.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME
            target.header.size = UInt32(MemoryLayout<DISPLAYCONFIG_TARGET_DEVICE_NAME>.size)
            target.header.adapterId = path.targetInfo.adapterId
            target.header.id = path.targetInfo.id
            _ = withUnsafeMutablePointer(to: &target) {
                $0.withMemoryRebound(to: DISPLAYCONFIG_DEVICE_INFO_HEADER.self, capacity: 1) { DisplayConfigGetDeviceInfo($0) }
            }
            let technology = path.targetInfo.outputTechnology
            let isInternal = technology == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INTERNAL
                || technology == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_DISPLAYPORT_EMBEDDED
                || technology == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_UDI_EMBEDDED
            return Target(deviceName: string(fromWideTuple: source.viewGdiDeviceName),
                          name: string(fromWideTuple: target.monitorFriendlyDeviceName),
                          devicePath: string(fromWideTuple: target.monitorDevicePath),
                          isInternal: isInternal)
        }
    }

    // MARK: GDI monitors

    private struct Monitor { let handle: HMONITOR; let deviceName: String; let rect: RECT; let isPrimary: Bool }

    private final class MonitorList { var monitors: [Monitor] = [] }

    private static func gdiMonitors() -> [Monitor] {
        let list = MonitorList()
        let context = Unmanaged.passUnretained(list).toOpaque()
        _ = EnumDisplayMonitors(nil, nil, { handle, _, _, context in
            guard let handle else { return true }
            var info = MONITORINFOEXW()
            info.cbSize = DWORD(MemoryLayout<MONITORINFOEXW>.size)
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: MONITORINFO.self, capacity: 1) { GetMonitorInfoW(handle, $0) }
            }
            if ok.boolValue {
                let list = Unmanaged<MonitorList>.fromOpaque(UnsafeRawPointer(bitPattern: Int(context))!).takeUnretainedValue()
                list.monitors.append(Monitor(handle: handle, deviceName: string(fromWideTuple: info.szDevice),
                                             rect: info.rcMonitor, isPrimary: info.dwFlags & DWORD(MONITORINFOF_PRIMARY) != 0))
            }
            return true
        }, LPARAM(Int(bitPattern: context)))
        return list.monitors
    }
}
#endif
