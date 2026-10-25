import D65Core
import D65Display
import D65Measurement
import Foundation

public enum CalibrationState: String, Codable, Sendable {
    case idle, measuring, applying, verifying, restoring, finished
}
public enum CalibrationOutcome: String, Codable, Sendable {
    case measured, confirmed, converged, rejected, stoppedImproving, exhausted, cancelled, failed
}
public enum CalibrationMode: String, Codable, Sendable {
    case measureOnly, calibrate, gammaTest, ddcTest, brightnessTest, effectTest
}

public struct CalibrationConfiguration: Codable, Sendable {
    public var mode: CalibrationMode
    public var settlingSeconds: Double = 0.5
    public var samplingSeconds: Double = 2
    public var minimumSamples: Int = 3
    public var maximumPasses: Int = 3
    public var targetDeltaE: Double = 2
    public var gate = QualityGate()
    /// How white error is scored for the gate, the target and the stopping rule.
    public var metric: WhiteErrorMetric = .ciede2000
    /// The observer the probe's XYZ uses. The iPhone ALS reports XYZ computed by iOS, taken as CIE 1931 2°.
    public var observer: Observer = .cie1931TwoDegree
    public init(mode: CalibrationMode = .measureOnly) { self.mode = mode }

    private enum CodingKeys: String, CodingKey {
        case mode, settlingSeconds, samplingSeconds, minimumSamples, maximumPasses, targetDeltaE, gate, metric, observer
    }
    /// Records written before metrics and observers existed decode as CIEDE2000 and CIE 1931 2°.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(CalibrationMode.self, forKey: .mode)
        settlingSeconds = try c.decode(Double.self, forKey: .settlingSeconds)
        samplingSeconds = try c.decode(Double.self, forKey: .samplingSeconds)
        minimumSamples = try c.decode(Int.self, forKey: .minimumSamples)
        maximumPasses = try c.decode(Int.self, forKey: .maximumPasses)
        targetDeltaE = try c.decode(Double.self, forKey: .targetDeltaE)
        gate = try c.decode(QualityGate.self, forKey: .gate)
        metric = try c.decodeIfPresent(WhiteErrorMetric.self, forKey: .metric) ?? .ciede2000
        observer = try c.decodeIfPresent(Observer.self, forKey: .observer) ?? .cie1931TwoDegree
    }
}

public struct DisplayContext: Codable, Hashable, Sendable {
    public let identity: String
    public let name: String
    public let displayID: UInt32
    public let width: Int
    public let height: Int
    public let refreshRate: Double
    /// Unknown output range/chroma stays unknown; do not invent an SDR/RGB mode.
    public var mode: DisplayModeKey?
    public var monitorSettings: [String: UInt16]

    public init(identity: String, name: String, displayID: UInt32, width: Int, height: Int,
                refreshRate: Double, mode: DisplayModeKey? = nil, monitorSettings: [String: UInt16] = [:]) {
        self.identity = identity; self.name = name; self.displayID = displayID
        self.width = width; self.height = height; self.refreshRate = refreshRate
        self.mode = mode; self.monitorSettings = monitorSettings
    }
}

public struct ProbeIdentity: Codable, Hashable, Sendable {
    public let model: String
    public let build: String
    public init(model: String, build: String) { self.model = model; self.build = build }
}

public struct CalibrationPatch: Codable, Hashable, Sendable {
    public let name: String
    public let red: Double
    public let green: Double
    public let blue: Double
    public init(_ name: String, _ red: Double, _ green: Double, _ blue: Double) {
        self.name = name; self.red = red; self.green = green; self.blue = blue
    }
    public static let white = CalibrationPatch("white", 1, 1, 1)
    public static let sequence: [CalibrationPatch] = [
        .init("black", 0, 0, 0), .white, .init("red", 1, 0, 0), .init("green", 0, 1, 0),
        .init("blue", 0, 0, 1), .init("yellow", 1, 1, 0), .init("cyan", 0, 1, 1),
        .init("magenta", 1, 0, 1), .init("grey20", 0.2, 0.2, 0.2),
        .init("grey40", 0.4, 0.4, 0.4), .init("grey60", 0.6, 0.6, 0.6), .init("grey80", 0.8, 0.8, 0.8)
    ]
}

/// Live progress for a UI. Emitted on the main actor while the engine runs.
public enum CalibrationProgress: Sendable {
    case patch(index: Int, count: Int, patch: CalibrationPatch)
    case applying(pass: Int, gains: RGBGains)
    case verifying(pass: Int)
    case passMeasured(CorrectionPass)
    case restoring
}

/// Why a session failed, in a form a UI can explain without parsing `terminationReason`.
public enum CalibrationFailure: String, Codable, Sendable {
    case disconnected, displayChanged, invalidMeasurement, insufficientSamples, noConsensus
    case invalidConfiguration, outputFailed, controlFailed, restorationFailed, other
}

/// The session finished and the display was restored, but its record could not be written.
public struct RecordSaveError: Error {
    public let record: ExperimentRecord
    public let underlying: String
}

public enum CalibrationError: Error, Equatable {
    case busy, disconnected, invalidConfiguration, invalidMeasurement, displayChanged
    case controlUnavailable(UInt8), writeFailed(UInt8), restorationUnverified(UInt8)
}

@MainActor public protocol CalibrationClock {
    var now: Date { get }
    func sleep(seconds: Double) async throws
}
@MainActor public struct SystemCalibrationClock: CalibrationClock {
    public init() {}
    public var now: Date { Date() }
    public func sleep(seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

@MainActor public protocol CalibrationProbe {
    var identity: ProbeIdentity { get }
    /// Coordinate system supplied by this source; target selection never converts its XYZ.
    var observer: Observer { get }
    func start(_ request: MeasurementRequest) throws
    func finish(_ request: MeasurementRequest) throws -> [TaggedMeasurement]
    @discardableResult func stop() -> [TaggedMeasurement]
}
extension CalibrationProbe {
    /// Existing iPhone ALS sources retain their historical CIE 1931 2° assumption.
    public var observer: Observer { .cie1931TwoDegree }
}

@MainActor public protocol PatchPresenter {
    /// Returns after the selected screen has presented the patch.
    func show(_ patch: CalibrationPatch) async throws
    func close()
}
@MainActor public protocol CalibrationDisplay {
    var context: DisplayContext { get }
    /// Capture the exact starting state. Subsequent gains are cumulative relative to this baseline.
    func begin() throws
    func validate() throws
    func setCumulativeGains(_ gains: RGBGains, gamma: Double) throws
    func restore() throws
    func readControl(_ code: UInt8) throws -> DDCValue
    func writeControl(_ code: UInt8, value: UInt16) throws
}
