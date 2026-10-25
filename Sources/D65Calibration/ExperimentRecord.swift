import D65Core
import D65Measurement
import Foundation

public struct MeasurementAttempt: Codable, Sendable {
    public let request: MeasurementRequest
    public var samples: [TaggedMeasurement]
    public var failure: String?
    public init(request: MeasurementRequest, samples: [TaggedMeasurement] = [], failure: String? = nil) {
        self.request = request; self.samples = samples; self.failure = failure
    }
}
public struct GainApplication: Codable, Sendable {
    public let gains: RGBGains
    public let gamma: Double
    public let attemptedAt: Date
    public var failure: String?
}
public struct ControlWriteAttempt: Codable, Sendable {
    public let code: UInt8
    public let value: UInt16
    public let purpose: String
    public let attemptedAt: Date
    public var failure: String?
}
public struct CorrectionPass: Codable, Sendable {
    public let number: Int
    public let gains: RGBGains
    public let measured: XYZ
    public let deltaE: Double
}
public struct ControlExperiment: Codable, Sendable {
    public let code: UInt8
    public let original: UInt16
    public let requested: UInt16
    public let baseline: XYZ
    public let after: XYZ
    public let restored: XYZ
    public let effective: Bool
}
/// Baseline and best white error under one metric, so every session can be read in each metric.
public struct MetricReport: Codable, Sendable, Equatable {
    public let metric: WhiteErrorMetric
    public let baseline: Double
    public let best: Double
}

public struct ExperimentRecord: Codable, Sendable {
    public let schemaVersion: Int
    public let whiteErrorMetric: String
    public let id: UUID
    public let startedAt: Date
    public var finishedAt: Date?
    public let softwareRevision: String
    public let configuration: CalibrationConfiguration
    public let display: DisplayContext
    public let probe: ProbeIdentity
    public var measurements: [PatchMeasurement] = []
    public var attempts: [MeasurementAttempt] = []
    public var passes: [CorrectionPass] = []
    public var applications: [GainApplication] = []
    public var controlWrites: [ControlWriteAttempt] = []
    public var controls: [ControlExperiment] = []
    public var gamma: Double = 2.2
    public var baselineDeltaE: Double?
    public var bestGains: RGBGains?
    public var bestDeltaE: Double?
    public var outcome: CalibrationOutcome = .failed
    public var terminationReason: String = "Session did not finish"
    /// Structured failure kind and the patch being measured when it happened (absent in older records).
    public var failure: CalibrationFailure?
    public var failedPhase: String?
    /// The observer the measured XYZ belongs to (absent in older records, which were CIE 1931 2°).
    public var observer: Observer?
    /// The baseline and best white in every metric (absent in older records).
    public var metricReports: [MetricReport]?
    /// The white this session steered to, in the probe's observer (absent in older records: D65).
    public var whiteTarget: Chromaticity?
    /// The observer the target was chosen for, and where the display's primary spectra came from.
    public var viewerObserver: Observer?
    public var primarySpectraSource: String?
    public var restorationErrors: [String] = []
    public var stateHistory: [CalibrationState] = [.idle]

    public init(id: UUID = UUID(), startedAt: Date, softwareRevision: String,
                configuration: CalibrationConfiguration, display: DisplayContext, probe: ProbeIdentity) {
        schemaVersion = 1; whiteErrorMetric = configuration.metric.definition
        observer = configuration.observer
        viewerObserver = configuration.viewerObserver
        primarySpectraSource = configuration.primarySpectra?.source
        self.id = id; self.startedAt = startedAt
        self.softwareRevision = softwareRevision; self.configuration = configuration
        self.display = display; self.probe = probe
    }

    /// Shared record codec preserves sub-second window times and invalid diagnostic values.
    public static func decode(_ data: Data) throws -> ExperimentRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try decoder.decode(ExperimentRecord.self, from: data)
    }

    public var consoleSummary: String {
        var lines = ["session \(id.uuidString): \(outcome.rawValue) — \(terminationReason)",
                     "display \(display.name) [\(display.identity)], probe \(probe.model), revision \(softwareRevision)"]
        for patch in measurements {
            let xy = patch.mean.chromaticity
            lines.append(String(format: "  %@ n=%d Y=%.2f ±%.3f x=%.4f y=%.4f", patch.request.phase,
                patch.samples.count, patch.mean.y, patch.standardError.y, xy?.x ?? 0, xy?.y ?? 0))
        }
        lines.append(String(format: "gamma %.3f", gamma))
        let unit = configuration.metric.label
        lines.append("metric \(whiteErrorMetric); observer \((observer ?? .cie1931TwoDegree).rawValue)")
        if let viewer = viewerObserver, let target = whiteTarget {
            lines.append(String(format: "target: D65 as seen by %@ → x=%.5f y=%.5f in the probe's observer (spectra: %@)",
                                viewer.rawValue, target.x, target.y, primarySpectraSource ?? "?"))
        }
        if let baselineDeltaE { lines.append(String(format: "baseline %@ %.2f", unit, baselineDeltaE)) }
        if let bestDeltaE, let bestGains {
            lines.append(String(format: "best measured %@ %.2f R=%.4f G=%.4f B=%.4f", unit,
                bestDeltaE, bestGains.r, bestGains.g, bestGains.b))
        }
        for pass in passes {
            lines.append(String(format: "  pass %d R=%.4f G=%.4f B=%.4f %@=%.2f", pass.number,
                pass.gains.r, pass.gains.g, pass.gains.b, unit, pass.deltaE))
        }
        for report in metricReports ?? [] {
            lines.append(String(format: "  %@ %.2f → %.2f", report.metric.label, report.baseline, report.best))
        }
        for control in controls {
            lines.append(String(format: "  VCP 0x%02X %d→%d ΔY=%+.1f%% effect=%@", control.code,
                control.original, control.requested, (control.after.y / control.baseline.y - 1) * 100,
                control.effective ? "measured" : "below threshold"))
        }
        lines += restorationErrors.map { "RESTORATION ERROR: \($0)" }
        return lines.joined(separator: "\n")
    }
}

@MainActor public protocol ExperimentRecorder {
    func save(_ record: ExperimentRecord) throws
}

/// Atomic, versioned JSON artifacts. One immutable result per session, including failures.
@MainActor public final class JSONExperimentRecorder: ExperimentRecorder {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func save(_ record: ExperimentRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: directory.appendingPathComponent("\(record.id.uuidString).json"), options: .atomic)
    }
}
