#if os(Windows)
import D65Host
import Foundation
import WinSDK

extension HostPlatform {
    /// Win32 patch window, GDI gamma ramps, dxva2 DDC/CI.
    @MainActor public static let windows = HostPlatform(
        makeOverlay: { id in WindowsOverlay(displayID: id) },
        makeDisplay: { id in try WindowsSelectedDisplay(displayID: id) })
}

extension CalibrationService {
    /// The Windows host: Winsock on `port`, advertised as `_d65._tcp` over DNS-SD.
    public static func windows(port: UInt16 = 50515, recordDirectory: URL, softwareRevision: String) -> CalibrationService {
        CalibrationService(listener: WinsockListener(port: port), platform: .windows,
                           recordDirectory: recordDirectory, softwareRevision: softwareRevision)
    }
}

public enum WindowsHost {
    /// Call before creating any window: coordinates and the outline's physical size are in real pixels
    /// only when the process is per-monitor DPI aware.
    public static func prepare() {
        // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 is (DPI_AWARENESS_CONTEXT)-4.
        _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT(bitPattern: -4))
    }

    /// Pumps Win32 messages for the patch window and runs the main queue (and so the main actor)
    /// in between, until the process exits.
    public static func runMessageLoop() -> Never {
        var message = MSG()
        while true {
            // QS_ALLINPUT; wake at least every 10 ms to service the main queue.
            MsgWaitForMultipleObjects(0, nil, false, 10, DWORD(0x04FF))
            while PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)).boolValue {
                TranslateMessage(&message)
                DispatchMessageW(&message)
            }
            RunLoop.main.run(mode: .default, before: Date())
        }
    }

    private static var interruptHandler: (@MainActor () -> Void)?

    /// Ctrl-C, Ctrl-Break or closing the console run `handler` on the main actor. The handler must
    /// restore the display and exit: Windows keeps a gamma ramp after the process ends.
    public static func onInterrupt(_ handler: @escaping @MainActor () -> Void) {
        interruptHandler = handler
        SetConsoleCtrlHandler({ _ in
            onMain { WindowsHost.interruptHandler?() }
            // Hold the console's close until the handler exits the process (Windows allows ~5 s).
            Sleep(5000)
            return true
        }, true)
    }
}
#endif
