#if os(Windows)
import D65Calibration
import D65Host
import Foundation
import WinSDK

/// Full-screen patches on the target display: a topmost borderless window that takes focus so Esc
/// always ends a session, hides the cursor, keeps its guidance at the edges away from the sensor, and
/// holds the display awake while it is up.
@MainActor public final class WindowsOverlay: HostOverlay {
    public let displayID: UInt32
    public var showsProgress = true
    public var onCancel: (() -> Void)?
    public var onStartNow: (() -> Void)?
    private let display: WindowsDisplay
    private var window: HWND?

    // What the next paint draws.
    private var fill: (r: Double, g: Double, b: Double) = (0, 0, 0)
    private var luminance = 0.0
    private var outline: (width: Int32, height: Int32)?
    private var hint: String?
    private var footer: String?
    private var fraction: Double?

    public init?(displayID: UInt32) {
        guard let display = WindowsDisplayDirectory.display(id: displayID) else { return nil }
        self.display = display
        self.displayID = displayID
    }

    public func show(_ patch: CalibrationPatch) async throws {
        open()
        outline = nil; hint = nil
        fill = (patch.red, patch.green, patch.blue)
        luminance = 0.2126 * patch.red + 0.7152 * patch.green + 0.0722 * patch.blue
        repaint()
    }

    public func showPlacement(probeModel: String?, hint: String) {
        open()
        fill = (1, 1, 1); luminance = 1
        let phone = PhoneOutline.millimetres(model: probeModel)
        let perMM = pixelsPerMillimetre()
        outline = (Int32(phone.width * perMM), Int32(phone.height * perMM))
        self.hint = hint
        footer = "Space to start now · Esc to cancel"
        fraction = nil
        repaint()
    }

    public func setHint(_ hint: String) { self.hint = hint; repaint() }

    public func setProgress(_ text: String, fraction: Double?) {
        guard showsProgress else { return }
        footer = text + " · Esc to cancel"; self.fraction = fraction
        repaint()
    }

    public func close() {
        guard let window else { return }
        Self.overlays[UInt(bitPattern: window)] = nil
        DestroyWindow(window)
        self.window = nil
        // ES_CONTINUOUS alone clears the display-required state set in open().
        SetThreadExecutionState(EXECUTION_STATE(0x8000_0000))
    }

    // MARK: Window

    private static var overlays: [UInt: WindowsOverlay] = [:]
    /// Lives for the process: RegisterClassExW keeps the pointer.
    private static let className: UnsafeMutablePointer<UInt16> = {
        let name = wide("D65PatchOverlay")
        let pointer = UnsafeMutablePointer<UInt16>.allocate(capacity: name.count)
        pointer.initialize(from: name, count: name.count)
        return pointer
    }()
    private static var registered = false

    private func open() {
        guard window == nil else { return }
        Self.registerClass()
        let width = display.right - display.left, height = display.bottom - display.top
        let created = "D65".withWide { title in
            CreateWindowExW(DWORD(0x0000_0008 | 0x0000_0080),   // WS_EX_TOPMOST | WS_EX_TOOLWINDOW
                            Self.className, title, DWORD(0x8000_0000 | 0x1000_0000), // WS_POPUP | WS_VISIBLE
                            display.left, display.top, width, height, nil, nil, GetModuleHandleW(nil), nil)
        }
        guard let created else { return }
        window = created
        Self.overlays[UInt(bitPattern: created)] = self
        SetForegroundWindow(created)
        SetFocus(created)
        // ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED: no idle sleep or screen saver
        // may blank the patch the phone is reading.
        SetThreadExecutionState(EXECUTION_STATE(0x8000_0000 | 0x2 | 0x1))
    }

    private func repaint() {
        guard let window else { return }
        InvalidateRect(window, nil, false)
        UpdateWindow(window)
    }

    private static func registerClass() {
        guard !registered else { return }
        registered = true
        var windowClass = WNDCLASSEXW()
        windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        windowClass.lpfnWndProc = { window, message, wParam, lParam in
            guard let window else { return 0 }
            return MainActor.assumeIsolated {
                WindowsOverlay.overlays[UInt(bitPattern: window)]?.handle(window, message, wParam, lParam)
                    ?? DefWindowProcW(window, message, wParam, lParam)
            }
        }
        windowClass.hInstance = GetModuleHandleW(nil)
        windowClass.lpszClassName = UnsafePointer(className)
        RegisterClassExW(&windowClass)
    }

    private func handle(_ window: HWND, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        switch message {
        case UINT(WM_PAINT):
            var paint = PAINTSTRUCT()
            if let dc = BeginPaint(window, &paint) { draw(dc, window: window) }
            EndPaint(window, &paint)
            return 0
        case UINT(WM_ERASEBKGND):
            return 1
        case UINT(WM_SETCURSOR):
            SetCursor(nil)
            return 1
        case UINT(WM_KEYDOWN):
            switch Int32(truncatingIfNeeded: wParam) {
            case VK_ESCAPE: onCancel?(); return 0
            case VK_SPACE: onStartNow?(); return 0
            default: return nil
            }
        default:
            return nil
        }
    }

    // MARK: Drawing (GDI)

    private func colour(_ r: Double, _ g: Double, _ b: Double) -> COLORREF {
        func byte(_ v: Double) -> DWORD { DWORD(max(0, min(255, (v * 255).rounded()))) }
        return byte(r) | byte(g) << 8 | byte(b) << 16
    }

    private func draw(_ dc: HDC, window: HWND) {
        var bounds = RECT()
        GetClientRect(window, &bounds)
        let background = CreateSolidBrush(colour(fill.r, fill.g, fill.b))
        FillRect(dc, &bounds, background)
        DeleteObject(background)

        // Guidance ink stays low-contrast: GDI has no alpha, so blend it with the patch by hand.
        let mix = luminance > 0.5 ? (0.0, 0.5) : (1.0, 0.32)
        let ink = colour(fill.r + (mix.0 - fill.r) * mix.1, fill.g + (mix.0 - fill.g) * mix.1, fill.b + (mix.0 - fill.b) * mix.1)
        SetBkMode(dc, Int32(TRANSPARENT))
        SetTextColor(dc, ink)
        let midX = (bounds.right - bounds.left) / 2, midY = (bounds.bottom - bounds.top) / 2

        if let outline {
            let pen = CreatePen(Int32(PS_SOLID), 2, ink)
            let oldPen = SelectObject(dc, pen)
            let oldBrush = SelectObject(dc, GetStockObject(Int32(HOLLOW_BRUSH)))
            let left = midX - outline.width / 2, top = midY - outline.height / 2
            let radius = Int32(Double(outline.width) * 0.32)
            RoundRect(dc, left, top, left + outline.width, top + outline.height, radius, radius)
            // The sensor sits at the top edge, on the screen side.
            let sensor = CreateSolidBrush(ink)
            var mark = RECT(left: midX - outline.width * 15 / 100, top: top + outline.height * 4 / 100,
                            right: midX + outline.width * 15 / 100, bottom: top + outline.height * 4 / 100 + max(4, outline.height * 18 / 1000))
            FillRect(dc, &mark, sensor)
            DeleteObject(sensor)
            SelectObject(dc, oldBrush); SelectObject(dc, oldPen); DeleteObject(pen)
            text(dc, "Top edge here — sensor", in: RECT(left: 0, top: top - 34, right: bounds.right, bottom: top - 8),
                 size: 15, weight: 400, centered: true)
        }
        if let hint {
            let y = bounds.bottom * 9 / 100
            text(dc, hint, in: RECT(left: 0, top: y - 20, right: bounds.right, bottom: y + 24), size: 24, weight: 600, centered: true)
        }
        if let footer {
            let bottom = bounds.bottom - 18
            text(dc, footer, in: RECT(left: 24, top: bottom - 30, right: bounds.right - 24, bottom: bottom - 8),
                 size: 14, weight: 400, centered: false)
            if let fraction {
                let width = bounds.right - 48
                var track = RECT(left: 24, top: bottom - 2, right: 24 + width, bottom: bottom)
                let faint = CreateSolidBrush(colour(fill.r + (mix.0 - fill.r) * mix.1 * 0.25,
                                                    fill.g + (mix.0 - fill.g) * mix.1 * 0.25, fill.b + (mix.0 - fill.b) * mix.1 * 0.25))
                FillRect(dc, &track, faint); DeleteObject(faint)
                track.right = 24 + Int32(Double(width) * min(1, max(0, fraction)))
                let solid = CreateSolidBrush(ink)
                FillRect(dc, &track, solid); DeleteObject(solid)
            }
        }
    }

    private func text(_ dc: HDC, _ string: String, in rect: RECT, size: Int32, weight: Int32, centered: Bool) {
        let font = "Segoe UI".withWide {
            CreateFontW(-size, 0, 0, 0, weight, 0, 0, 0, DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS),
                        DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY), DWORD(DEFAULT_PITCH), $0)
        }
        let old = SelectObject(dc, font)
        var area = rect
        var characters = wide(string)
        // DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX, plus DT_CENTER when centred.
        let format = UINT(0x20 | 0x4 | 0x800) | (centered ? UINT(0x1) : 0)
        DrawTextW(dc, &characters, -1, &area, format)
        SelectObject(dc, old)
        DeleteObject(font)
    }

    /// Physical pixels per millimetre from the monitor's EDID-derived raw DPI; ~110 ppi when unknown.
    private func pixelsPerMillimetre() -> Double {
        typealias GetDpi = @convention(c) (HMONITOR?, Int32, UnsafeMutablePointer<UINT>?, UnsafeMutablePointer<UINT>?) -> HRESULT
        var x: UINT = 0, y: UINT = 0
        if let getDpi = systemFunction("Shcore.dll", "GetDpiForMonitor", as: GetDpi.self),
           let monitor = WindowsDisplayDirectory.monitorHandle(deviceName: display.deviceName),
           getDpi(monitor, 2 /* MDT_RAW_DPI */, &x, &y) == 0, x > 0 {
            return Double(x) / 25.4
        }
        return 110 / 25.4
    }
}
#endif
