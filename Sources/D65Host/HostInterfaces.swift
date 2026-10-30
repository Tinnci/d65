import D65Calibration
import Foundation

// The calibration host is the same on every desktop platform; these are the parts each platform
// supplies: a TCP listener advertised as _d65._tcp, the full-screen patch window, and the display.

/// One probe's TCP connection. Every callback arrives on the main actor.
@MainActor public protocol ProbeConnection: AnyObject {
    /// Begins delivery: `onData` for each received chunk, `onClose` once when the peer closes or fails.
    func start(onData: @escaping (Data) -> Void, onClose: @escaping () -> Void)
    /// Queues `data`; `completion` runs once it has been handed to the network (or failed).
    func send(_ data: Data, completion: (() -> Void)?)
    func cancel()
}

/// Listens on the probe port and advertises it as `_d65._tcp`.
@MainActor public protocol ProbeListener: AnyObject {
    func start(onReady: @escaping () -> Void, onFailure: @escaping (String) -> Void,
               onConnection: @escaping (any ProbeConnection) -> Void)
    func cancel()
}

/// The full-screen patch window on the display being measured.
@MainActor public protocol HostOverlay: PatchPresenter, AnyObject {
    var displayID: UInt32 { get }
    var showsProgress: Bool { get set }
    /// Esc on the overlay.
    var onCancel: (() -> Void)? { get set }
    /// Space on the overlay.
    var onStartNow: (() -> Void)? { get set }
    /// A white patch with the phone's outline at physical size.
    func showPlacement(probeModel: String?, hint: String)
    func setHint(_ hint: String)
    func setProgress(_ text: String, fraction: Double?)
}

/// What a platform provides to `CalibrationService`.
public struct HostPlatform {
    public var makeOverlay: @MainActor (_ displayID: UInt32) -> (any HostOverlay)?
    public var makeDisplay: @MainActor (_ displayID: UInt32) throws -> any CalibrationDisplay
    public init(makeOverlay: @escaping @MainActor (UInt32) -> (any HostOverlay)?,
                makeDisplay: @escaping @MainActor (UInt32) throws -> any CalibrationDisplay) {
        self.makeOverlay = makeOverlay; self.makeDisplay = makeDisplay
    }
}

/// The phone's body in millimetres, for the placement outline.
public enum PhoneOutline {
    /// Width × height for models seen by the probe; others use a 6.1-inch body.
    public static let millimetres: [String: (width: Double, height: Double)] = [
        "iPhone18,4": (74.7, 156.2),   // iPhone Air
        "iPhone17,1": (71.5, 149.6), "iPhone17,2": (77.6, 163.0),
        "iPhone17,3": (71.5, 147.6), "iPhone17,4": (77.8, 160.9),
    ]
    public static func millimetres(model: String?) -> (width: Double, height: Double) {
        model.flatMap { millimetres[$0] } ?? (71.5, 147.6)
    }
}
