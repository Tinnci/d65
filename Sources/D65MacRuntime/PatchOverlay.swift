#if os(macOS)
import AppKit
import D65Calibration
import Foundation

/// Full-screen patches on the target display. It takes key focus so Esc always ends a session,
/// hides the cursor, and keeps its guidance in a strip at the bottom edge, away from the sensor.
@MainActor final class ScreenPatchPresenter: PatchPresenter {
    let screen: NSScreen
    let displayID: UInt32
    var onCancel: (() -> Void)?
    var onStartNow: (() -> Void)?
    var showsProgress = true
    private var window: OverlayWindow?
    private var view: OverlayView?
    private var cursorHidden = false

    init(screen: NSScreen, displayID: UInt32) { self.screen = screen; self.displayID = displayID }

    func show(_ patch: CalibrationPatch) async throws {
        let view = open()
        view.outline = nil; view.hint = nil
        // Explicit sRGB avoids device-dependent NSColor primary/grey definitions.
        view.fill = NSColor(srgbRed: patch.red, green: patch.green, blue: patch.blue, alpha: 1)
        view.luminance = 0.2126 * patch.red + 0.7152 * patch.green + 0.0722 * patch.blue
        view.needsDisplay = true
        window?.displayIfNeeded()
    }

    /// White patch with the phone's outline at physical size.
    func showPlacement(probeModel: String?, hint: String) {
        let view = open()
        view.fill = .white; view.luminance = 1
        view.outline = PhoneOutline.size(model: probeModel, on: screen, displayID: displayID)
        view.hint = hint
        view.footer = "Space to start now · Esc to cancel"
        view.fraction = nil
        view.needsDisplay = true
    }

    func setHint(_ hint: String) { view?.hint = hint; view?.needsDisplay = true }

    func setProgress(_ text: String, fraction: Double?) {
        guard showsProgress else { return }
        view?.footer = text + " · Esc to cancel"; view?.fraction = fraction; view?.needsDisplay = true
    }

    func close() {
        window?.orderOut(nil); window = nil; view = nil
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
    }

    private func open() -> OverlayView {
        if let view { return view }
        let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        w.level = .screenSaver
        w.isOpaque = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.setFrame(screen.frame, display: false)
        let v = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        w.contentView = v
        w.onKey = { [weak self] event in
            switch event.keyCode {
            case 53: self?.onCancel?(); return true          // Esc
            case 49: self?.onStartNow?(); return true        // Space
            default: return false
            }
        }
        window = w; view = v
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        if !cursorHidden { NSCursor.hide(); cursorHidden = true }
        return v
    }
}

final class OverlayWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

final class OverlayView: NSView {
    var fill: NSColor = .black
    var luminance: Double = 0
    var outline: CGSize?
    var hint: String?
    var footer: String?
    var fraction: Double?

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        bounds.fill()
        // Guidance ink stays low-contrast and is only drawn at the edges or around the outline.
        let ink = luminance > 0.5 ? NSColor(white: 0, alpha: 0.5) : NSColor(white: 1, alpha: 0.32)
        if let outline {
            let rect = NSRect(x: bounds.midX - outline.width / 2, y: bounds.midY - outline.height / 2,
                              width: outline.width, height: outline.height)
            let path = NSBezierPath(roundedRect: rect, xRadius: outline.width * 0.16, yRadius: outline.width * 0.16)
            path.lineWidth = 2
            path.setLineDash([8, 6], count: 2, phase: 0)
            ink.setStroke(); path.stroke()
            let sensor = NSRect(x: rect.midX - outline.width * 0.15, y: rect.maxY - outline.height * 0.06,
                                width: outline.width * 0.3, height: max(4, outline.height * 0.018))
            ink.setFill(); NSBezierPath(roundedRect: sensor, xRadius: 3, yRadius: 3).fill()
            draw("Top edge here — sensor", at: NSPoint(x: rect.midX, y: rect.maxY + 14), size: 13, color: ink, centered: true)
        }
        if let hint {
            draw(hint, at: NSPoint(x: bounds.midX, y: bounds.maxY - bounds.height * 0.1), size: 22, color: ink,
                 centered: true, weight: .semibold)
        }
        if let footer {
            let strip = NSRect(x: 24, y: 18, width: bounds.width - 48, height: 18)
            draw(footer, at: NSPoint(x: strip.minX, y: strip.minY + 10), size: 12, color: ink, centered: false)
            if let fraction {
                let track = NSRect(x: strip.minX, y: strip.minY - 4, width: strip.width, height: 2)
                ink.withAlphaComponent(0.25).setFill(); track.fill()
                ink.setFill(); NSRect(x: track.minX, y: track.minY, width: track.width * min(1, max(0, fraction)), height: 2).fill()
            }
        }
    }

    private func draw(_ text: String, at point: NSPoint, size: CGFloat, color: NSColor, centered: Bool,
                      weight: NSFont.Weight = .regular) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let string = NSAttributedString(string: text, attributes: attributes)
        let width = string.size().width
        string.draw(at: NSPoint(x: centered ? point.x - width / 2 : point.x, y: point.y - string.size().height / 2))
    }
}

/// The phone's footprint in points on a given display, from its physical size.
enum PhoneOutline {
    /// Width × height in millimetres for models seen by the probe; others use a 6.1-inch body.
    static let millimetres: [String: CGSize] = [
        "iPhone18,4": CGSize(width: 74.7, height: 156.2),   // iPhone Air
        "iPhone17,1": CGSize(width: 71.5, height: 149.6), "iPhone17,2": CGSize(width: 77.6, height: 163.0),
        "iPhone17,3": CGSize(width: 71.5, height: 147.6), "iPhone17,4": CGSize(width: 77.8, height: 160.9),
    ]
    static func size(model: String?, on screen: NSScreen, displayID: UInt32) -> CGSize {
        let phone = model.flatMap { millimetres[$0] } ?? CGSize(width: 71.5, height: 147.6)
        let physical = CGDisplayScreenSize(displayID)
        // CGDisplayScreenSize is EDID-derived and can be zero; fall back to ~110 ppi.
        let pointsPerMM = physical.width > 0 ? screen.frame.width / physical.width : 110 / 25.4
        return CGSize(width: phone.width * pointsPerMM, height: phone.height * pointsPerMM)
    }
}
#endif
