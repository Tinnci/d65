import D65Core
import D65Display
import D65Measurement
import Foundation

/// One serialized workflow shared by CLI and app. Hardware/network/UI are injected boundaries.
@MainActor public final class CalibrationEngine {
    public private(set) var state: CalibrationState = .idle
    /// Progress for presentation only; the record remains the source of truth.
    public var onProgress: ((CalibrationProgress) -> Void)?
    private var running = false
    public init() {}

    public func run(configuration: CalibrationConfiguration, display: any CalibrationDisplay,
                    probe: any CalibrationProbe, presenter: any PatchPresenter,
                    clock: any CalibrationClock, recorder: any ExperimentRecorder,
                    softwareRevision: String) async throws -> ExperimentRecord {
        guard !running else { throw CalibrationError.busy }
        running = true
        state = .idle
        defer { running = false }
        var record = ExperimentRecord(startedAt: clock.now, softwareRevision: softwareRevision,
            configuration: configuration, display: display.context, probe: probe.identity)
        var captured = false
        var baselineWhite: XYZ?
        do {
            guard configuration.settlingSeconds.isFinite, configuration.settlingSeconds >= 0,
                  configuration.samplingSeconds.isFinite, configuration.samplingSeconds > 0,
                  configuration.minimumSamples >= 2, configuration.maximumPasses > 0,
                  configuration.targetDeltaE.isFinite, configuration.targetDeltaE > 0,
                  configuration.gate.minimumPreCorrectionDeltaE.isFinite, configuration.gate.minimumPreCorrectionDeltaE >= 0,
                  configuration.gate.maximumPostCorrectionDeltaE.isFinite, configuration.gate.maximumPostCorrectionDeltaE > 0,
                  configuration.gate.maximumLuminanceLoss.isFinite,
                  (0...1).contains(configuration.gate.maximumLuminanceLoss) else {
                throw CalibrationError.invalidConfiguration
            }
            // The caller must supply XYZ for its declared observer. Never substitute another observer's D65.
            guard configuration.observer == probe.observer else { throw CalibrationError.invalidConfiguration }
            // D65, or the probe-observer white a different viewer sees as D65 on this display's primaries.
            let target = try configuration.whiteTarget()
            record.whiteTarget = target
            let metric = configuration.metric
            try Task.checkCancellation()
            try display.begin()
            captured = true
            transition(.measuring, record: &record)
            var emitted: [String: XYZ] = [:]
            var ambient = XYZ.zero
            for (index, patch) in CalibrationPatch.sequence.enumerated() {
                onProgress?(.patch(index: index, count: CalibrationPatch.sequence.count, patch: patch))
                let measurement = try await measure(patch, record: &record, display: display,
                    probe: probe, presenter: presenter, clock: clock)
                if patch.name == "black" { ambient = measurement.mean }
                else { emitted[patch.name] = measurement.subtracting(ambient) }
            }
            guard let white = emitted["white"], white.y > 1 else { throw CalibrationError.invalidMeasurement }
            record.gamma = fitGamma(emitted)
            record.baselineDeltaE = metric.whiteError(white, target: target)
            baselineWhite = white
            switch configuration.mode {
            case .measureOnly:
                record.outcome = .measured
                record.terminationReason = "Measurement completed; no correction requested"
            case .calibrate:
                try await correct(white: white, ambient: ambient, record: &record,
                    display: display, probe: probe, presenter: presenter, clock: clock)
            case .gammaTest:
                transition(.applying, record: &record)
                let gains = RGBGains(r: 1, g: 1, b: 0.7)
                try apply(gains, record: &record, display: display, clock: clock)
                transition(.verifying, record: &record)
                let m = try await measure(.white, record: &record, display: display,
                    probe: probe, presenter: presenter, clock: clock).subtracting(ambient)
                record.passes.append(CorrectionPass(number: 1, gains: gains, measured: m, deltaE: metric.whiteError(m, target: target)))
                record.outcome = .measured
                record.terminationReason = "Fixed gamma gain tested"
            case .ddcTest, .brightnessTest, .effectTest:
                let candidates: [(UInt8, UInt16)]
                switch configuration.mode {
                case .brightnessTest: candidates = [(0x10, 100)]
                case .ddcTest:
                    let red = try display.readControl(0x16).current
                    candidates = [(0x16, red > 25 ? red - 25 : 0)]
                default: candidates = [(0x12, 80), (0x6C, 100)]
                }
                for (code, value) in candidates {
                    try await testControl(code, value: value, ambient: ambient, record: &record,
                        display: display, probe: probe, presenter: presenter, clock: clock)
                }
                record.outcome = .measured
                record.terminationReason = "Control effects measured and restoration verified"
            }
        } catch is CancellationError {
            record.outcome = .cancelled
            record.terminationReason = "Session cancelled"
        } catch {
            record.outcome = .failed
            record.terminationReason = String(describing: error)
            record.failure = Self.classify(error)
        }
        record.metricReports = Self.metricReports(baseline: baselineWhite, record: record)
        onProgress?(.restoring)
        transition(.restoring, record: &record)
        probe.stop()
        if captured {
            do { try display.restore() }
            catch {
                record.restorationErrors.append(String(describing: error))
                record.outcome = .failed
                record.terminationReason = "Display restoration failed"
                record.failure = .restorationFailed
            }
        }
        presenter.close()
        transition(.finished, record: &record)
        record.finishedAt = clock.now
        // A storage failure is surfaced to the caller, never silently presented as a saved experiment.
        // The record travels with the error so the caller can still present what was measured.
        do { try recorder.save(record) }
        catch { throw RecordSaveError(record: record, underlying: String(describing: error)) }
        return record
    }

    static func classify(_ error: Error) -> CalibrationFailure {
        switch error {
        case let error as CalibrationError:
            switch error {
            case .disconnected: return .disconnected
            case .displayChanged: return .displayChanged
            case .invalidMeasurement: return .invalidMeasurement
            case .invalidConfiguration, .busy: return .invalidConfiguration
            case .controlUnavailable, .writeFailed: return .controlFailed
            case .restorationUnverified: return .restorationFailed
            }
        case let error as MeasurementError:
            switch error {
            case .insufficientSamples: return .insufficientSamples
            case .noConsensus: return .noConsensus
            case .outOfRange: return .invalidMeasurement
            }
        case is TransferTransactionError: return .outputFailed
        default:
            #if os(macOS)
            if error is DisplayOutputError { return .outputFailed }
            #endif
            return .other
        }
    }

    private func transition(_ next: CalibrationState, record: inout ExperimentRecord) {
        state = next
        record.stateHistory.append(next)
    }

    private func measure(_ patch: CalibrationPatch, record: inout ExperimentRecord,
                         display: any CalibrationDisplay, probe: any CalibrationProbe,
                         presenter: any PatchPresenter, clock: any CalibrationClock) async throws -> PatchMeasurement {
        try Task.checkCancellation()
        try display.validate()
        try await presenter.show(patch)
        let config = record.configuration
        let request = MeasurementRequest(sessionID: record.id, phase: patch.name, startedAt: clock.now,
            settlingSeconds: config.settlingSeconds, samplingSeconds: config.samplingSeconds)
        var attempt = MeasurementAttempt(request: request)
        do {
            try probe.start(request)
            try await clock.sleep(seconds: config.settlingSeconds + config.samplingSeconds)
            try Task.checkCancellation()
            try display.validate()
            let samples = try probe.finish(request)
            attempt.samples = samples
            let result = try MeasurementCollector(minimumCount: config.minimumSamples).collect(samples, for: request)
            record.attempts.append(attempt)
            record.measurements.append(result)
            return result
        } catch {
            attempt.failure = String(describing: error)
            if !(error is CancellationError) { record.failedPhase = patch.name }
            let pending = probe.stop()
            if attempt.samples.isEmpty { attempt.samples = pending }
            record.attempts.append(attempt)
            throw error
        }
    }

    private func correct(white: XYZ, ambient: XYZ, record: inout ExperimentRecord,
                         display: any CalibrationDisplay, probe: any CalibrationProbe,
                         presenter: any PatchPresenter, clock: any CalibrationClock) async throws {
        let config = record.configuration
        let metric = config.metric, target = try config.whiteTarget()
        let before = metric.whiteError(white, target: target)
        if before <= config.gate.minimumPreCorrectionDeltaE {
            record.outcome = .confirmed
            record.bestGains = .identity; record.bestDeltaE = before
            record.terminationReason = "Display already within tolerance"
            return
        }
        let full = WhitePointSolver.gains(measuredWhite: white, target: target)
        var selected: RGBGains?
        for step in stride(from: 20, through: 1, by: -1) {
            let candidate = CorrectionRequest(gains: full, alpha: Double(step) / 20).resolved()
            let predicted = WhitePointSolver.predictedWhite(after: candidate, measuredWhite: white)
            if config.gate.verdict(preDeltaE: before, postDeltaE: metric.whiteError(predicted, target: target),
                                   luminanceScale: predicted.y / white.y) == .improved {
                selected = candidate
                break
            }
        }
        guard var cumulative = selected else {
            record.outcome = .rejected
            record.terminationReason = "No predicted correction passed the quality gate"
            return
        }
        var previous = before
        // Best state is local to this run. Baseline remains best if every correction regresses.
        record.bestDeltaE = before; record.bestGains = .identity
        for number in 1...config.maximumPasses {
            transition(.applying, record: &record)
            onProgress?(.applying(pass: number, gains: cumulative))
            try apply(cumulative, record: &record, display: display, clock: clock)
            transition(.verifying, record: &record)
            onProgress?(.verifying(pass: number))
            let measured = try await measure(.white, record: &record, display: display, probe: probe,
                presenter: presenter, clock: clock).subtracting(ambient)
            guard measured.y > 0 else { throw CalibrationError.invalidMeasurement }
            let error = metric.whiteError(measured, target: target)
            let pass = CorrectionPass(number: number, gains: cumulative, measured: measured, deltaE: error)
            record.passes.append(pass)
            onProgress?(.passMeasured(pass))
            guard measured.y / white.y >= 1 - config.gate.maximumLuminanceLoss else {
                record.outcome = .rejected
                record.terminationReason = "Measured luminance loss exceeded the quality gate"
                return
            }
            if error < (record.bestDeltaE ?? .infinity) {
                record.bestDeltaE = error; record.bestGains = cumulative
            }
            if error <= config.targetDeltaE {
                record.outcome = .converged
                record.terminationReason = "Measured white reached target tolerance"
                return
            }
            if error >= previous - 0.3 {
                record.outcome = .stoppedImproving
                record.terminationReason = "Measured improvement was below 0.3 ΔE00"
                return
            }
            if number == config.maximumPasses { break }
            let residual = WhitePointSolver.gains(measuredWhite: measured, target: target)
            cumulative = RGBGains(r: cumulative.r * residual.r, g: cumulative.g * residual.g, b: cumulative.b * residual.b)
            let predicted = WhitePointSolver.predictedWhite(after: residual, measuredWhite: measured)
            guard predicted.y / white.y >= 1 - config.gate.maximumLuminanceLoss else {
                record.outcome = .rejected
                record.terminationReason = "Residual correction would exceed cumulative luminance loss"
                return
            }
            previous = error
        }
        record.outcome = .exhausted
        record.terminationReason = "Maximum correction passes reached above target tolerance"
    }

    private func apply(_ gains: RGBGains, record: inout ExperimentRecord,
                       display: any CalibrationDisplay, clock: any CalibrationClock) throws {
        var application = GainApplication(gains: gains, gamma: record.gamma, attemptedAt: clock.now)
        defer { record.applications.append(application) }
        do { try display.setCumulativeGains(gains, gamma: record.gamma) }
        catch { application.failure = String(describing: error); throw error }
    }

    private func writeControl(_ code: UInt8, value: UInt16, purpose: String, record: inout ExperimentRecord,
                              display: any CalibrationDisplay, clock: any CalibrationClock) throws {
        var attempt = ControlWriteAttempt(code: code, value: value, purpose: purpose, attemptedAt: clock.now)
        defer { record.controlWrites.append(attempt) }
        do { try display.writeControl(code, value: value) }
        catch { attempt.failure = String(describing: error); throw error }
    }

    private func fitGamma(_ emitted: [String: XYZ]) -> Double {
        guard let white = emitted["white"], white.y > 0 else { return 2.2 }
        var xx = 0.0, xy = 0.0, count = 0
        for (name, level) in [("grey20", 0.2), ("grey40", 0.4), ("grey60", 0.6), ("grey80", 0.8)] {
            guard let y = emitted[name]?.y, y > 0.5, y < white.y else { continue }
            let x = log(level)
            xx += x * x; xy += x * log(y / white.y); count += 1
        }
        return count >= 3 ? min(2.8, max(1.6, xy / xx)) : 2.2
    }

    /// CIEDE2000 white error at Y=1, the default metric. Sessions use their configured metric.
    public static func whiteError(_ white: XYZ) -> Double { WhiteErrorMetric.ciede2000.whiteError(white) }

    /// The baseline and best measured white under every metric, so a session can be compared in each.
    static func metricReports(baseline: XYZ?, record: ExperimentRecord) -> [MetricReport]? {
        guard let baseline, let target = try? record.configuration.whiteTarget() else { return nil }
        let chosen = record.configuration.metric
        let bestPass = record.bestGains.flatMap { gains in record.passes.last { $0.gains == gains } }
        let best = bestPass?.measured ?? baseline
        return WhiteErrorMetric.allCases.map { metric in
            MetricReport(metric: metric, baseline: metric.whiteError(baseline, target: target),
                         best: metric == chosen ? (record.bestDeltaE ?? metric.whiteError(best, target: target))
                                                : metric.whiteError(best, target: target))
        }
    }

    private func testControl(_ code: UInt8, value: UInt16, ambient: XYZ, record: inout ExperimentRecord,
                             display: any CalibrationDisplay, probe: any CalibrationProbe,
                             presenter: any PatchPresenter, clock: any CalibrationClock) async throws {
        let original = try display.readControl(code)
        let baseline = try await measure(.white, record: &record, display: display, probe: probe,
            presenter: presenter, clock: clock).subtracting(ambient)
        guard baseline.y > 0 else { throw CalibrationError.invalidMeasurement }
        // Treat even a failed write as potentially effective: always attempt restoration.
        var restoredByValue = false
        do {
            transition(.applying, record: &record)
            try writeControl(code, value: value, purpose: "test", record: &record, display: display, clock: clock)
            transition(.verifying, record: &record)
            let after = try await measure(.white, record: &record, display: display, probe: probe,
                presenter: presenter, clock: clock).subtracting(ambient)
            transition(.restoring, record: &record)
            try writeControl(code, value: original.current, purpose: "restore", record: &record, display: display, clock: clock)
            restoredByValue = true
            var restored = try await measure(.white, record: &record, display: display, probe: probe,
                presenter: presenter, clock: clock).subtracting(ambient)
            if code == 0x10, !Self.matches(restored, baseline) {
                // Brightness readback may not describe the baseline. Search the measured response.
                var low = 0, high = Int(min(original.maximum, 100))
                for _ in 0..<8 where low <= high {
                    let midpoint = (low + high) / 2
                    try writeControl(code, value: UInt16(midpoint), purpose: "measured restore", record: &record, display: display, clock: clock)
                    restored = try await measure(.white, record: &record, display: display, probe: probe,
                        presenter: presenter, clock: clock).subtracting(ambient)
                    if Self.matches(restored, baseline) { break }
                    if restored.y < baseline.y { low = midpoint + 1 } else { high = midpoint - 1 }
                }
            }
            guard Self.matches(restored, baseline) else { throw CalibrationError.restorationUnverified(code) }
            record.controls.append(ControlExperiment(code: code, original: original.current, requested: value,
                baseline: baseline, after: after, restored: restored,
                effective: abs(after.y / baseline.y - 1) > 0.05 || Self.xyDistance(after, baseline) > 0.002))
        } catch {
            if !restoredByValue {
                do { try writeControl(code, value: original.current, purpose: "restore", record: &record, display: display, clock: clock) }
                catch { record.restorationErrors.append("VCP \(code): \(error)") }
            }
            record.restorationErrors.append("VCP \(code): sensor restoration could not be verified")
            throw error
        }
    }
    private static func xyDistance(_ a: XYZ, _ b: XYZ) -> Double {
        guard let a = a.chromaticity, let b = b.chromaticity else { return .infinity }
        return hypot(a.x - b.x, a.y - b.y)
    }
    private static func matches(_ value: XYZ, _ baseline: XYZ) -> Bool {
        abs(value.y / baseline.y - 1) <= 0.05 && xyDistance(value, baseline) <= 0.002
    }
}
