import D65Calibration
import D65Core
import D65Display
import D65Link
import D65Measurement
import XCTest

@MainActor final class CalibrationEngineTests: XCTestCase {
    func testConvergenceRestoresExactBaselineAndRecordsResolvedGains() async throws {
        let fixture = Fixture()
        fixture.probe.verification = { _ in Chromaticity.d65.xyz(luminance: 95) }
        let record = try await fixture.run(.calibrate)
        XCTAssertEqual(record.outcome, .converged)
        XCTAssertEqual(record.passes.count, 1)
        XCTAssertEqual(record.gamma, 2.2, accuracy: 1e-10)
        XCTAssertEqual(record.passes[0].gains, fixture.display.applied[0])
        XCTAssertEqual(fixture.display.table, [0.1, 0.4, 0.8])
        XCTAssertEqual(fixture.display.restores, 1)
        XCTAssertTrue(fixture.presenter.closed)
        XCTAssertEqual(record.stateHistory.suffix(2), [.restoring, .finished])
        XCTAssertEqual(fixture.recorder.records.count, 1)
    }

    func testAlreadyAcceptableWhiteDoesNotApplyCorrection() async throws {
        let fixture = Fixture()
        fixture.probe.initialWhite = Chromaticity.d65.xyz(luminance: 100)
        let record = try await fixture.run(.calibrate)
        XCTAssertEqual(record.outcome, .confirmed)
        XCTAssertTrue(fixture.display.applied.isEmpty)
        XCTAssertEqual(record.bestGains, .identity)
    }

    func testRegressionKeepsBaselineAndDoesNotClaimConvergence() async throws {
        let fixture = Fixture()
        fixture.probe.verification = { _ in Chromaticity(x: 0.28, y: 0.30).xyz(luminance: 95) }
        let record = try await fixture.run(.calibrate)
        XCTAssertEqual(record.outcome, .stoppedImproving)
        XCTAssertEqual(record.bestGains, .identity)
        XCTAssertEqual(record.bestDeltaE, record.baselineDeltaE)
        XCTAssertEqual(fixture.display.restores, 1)
    }

    func testMeasuredLuminanceLossRejectsEvenAWhiteOnTarget() async throws {
        let fixture = Fixture()
        fixture.probe.verification = { _ in Chromaticity.d65.xyz(luminance: 60) }
        let record = try await fixture.run(.calibrate)
        XCTAssertEqual(record.outcome, .rejected)
        XCTAssertEqual(record.bestGains, .identity)
        XCTAssertEqual(fixture.display.restores, 1)
    }

    func testMissingGammaVerificationStillRestores() async throws {
        let fixture = Fixture()
        fixture.probe.missingAt = 13
        let record = try await fixture.run(.gammaTest)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(fixture.display.applied.count, 1)
        XCTAssertEqual(record.applications.count, 1)
        XCTAssertNotNil(record.attempts.last?.failure)
        XCTAssertEqual(fixture.display.restores, 1)
        XCTAssertEqual(fixture.display.table, [0.1, 0.4, 0.8])
    }

    func testDisconnectAfterDDCWriteAttemptsRestoration() async throws {
        let fixture = Fixture()
        fixture.probe.disconnectAt = 14 // 12 initial patches, baseline, then post-write reading
        let record = try await fixture.run(.brightnessTest)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(fixture.display.writes.map(\.1), [100, 30])
        XCTAssertFalse(record.restorationErrors.isEmpty)
        XCTAssertEqual(fixture.display.restores, 1)
    }

    func testFailedWriteStillRestoresPotentiallyChangedControl() async throws {
        let fixture = Fixture()
        fixture.display.failNextWrite = true
        let record = try await fixture.run(.brightnessTest)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(fixture.display.writes.map(\.1), [100, 30])
        XCTAssertEqual(fixture.display.controls[0x10], 30)
        XCTAssertEqual(record.controlWrites.count, 2)
        XCTAssertNotNil(record.controlWrites.first?.failure)
        XCTAssertEqual(record.controlWrites.last?.purpose, "restore")
    }

    func testGammaApplyFailureRestores() async throws {
        let fixture = Fixture()
        fixture.display.failApply = true
        let record = try await fixture.run(.calibrate)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(fixture.display.restores, 1)
    }

    func testCancellationRestoresAndRecordsCancelledOutcome() async throws {
        let fixture = Fixture()
        let clock = PausingClock(pauseAt: 13)
        let task = Task { @MainActor in
            try await fixture.engine.run(configuration: .init(mode: .gammaTest), display: fixture.display,
                probe: fixture.probe, presenter: fixture.presenter, clock: clock, recorder: fixture.recorder,
                softwareRevision: "test")
        }
        await clock.waitForPause()
        task.cancel()
        clock.release()
        let record = try await task.value
        XCTAssertEqual(record.outcome, .cancelled)
        XCTAssertEqual(fixture.display.restores, 1)
        XCTAssertTrue(fixture.presenter.closed)
    }

    func testBestPassDoesNotLeakAcrossConsecutiveSessions() async throws {
        let fixture = Fixture()
        fixture.probe.verification = { _ in Chromaticity.d65.xyz(luminance: 95) }
        let first = try await fixture.run(.calibrate)
        fixture.probe.count = 0
        fixture.probe.verification = { _ in Chromaticity(x: 0.307, y: 0.325).xyz(luminance: 95) }
        var config = CalibrationConfiguration(mode: .calibrate)
        config.maximumPasses = 1
        config.targetDeltaE = 0.01
        let second = try await fixture.run(config)
        XCTAssertEqual(first.outcome, .converged)
        XCTAssertEqual(second.outcome, .exhausted)
        XCTAssertGreaterThan(try XCTUnwrap(second.bestDeltaE), try XCTUnwrap(first.bestDeltaE))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(fixture.display.restores, 2)
    }

    func testBusyEngineRejectsSecondRunWithoutTouchingHardware() async throws {
        let fixture = Fixture()
        let clock = PausingClock(pauseAt: 1)
        let task = Task { @MainActor in
            try await fixture.engine.run(configuration: .init(), display: fixture.display, probe: fixture.probe,
                presenter: fixture.presenter, clock: clock, recorder: fixture.recorder, softwareRevision: "test")
        }
        await clock.waitForPause()
        do { _ = try await fixture.run(.measureOnly); XCTFail("second run accepted") }
        catch { XCTAssertEqual(error as? CalibrationError, .busy) }
        task.cancel(); clock.release()
        _ = try await task.value
        XCTAssertEqual(fixture.display.begins, 1)
    }

    func testRestorationFailureIsReported() async throws {
        let fixture = Fixture()
        fixture.display.failRestore = true
        let record = try await fixture.run(.measureOnly)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.restorationErrors.count, 1)
        XCTAssertEqual(fixture.recorder.records.count, 1)
    }

    func testBrightnessRestorationUsesMeasuredResponse() async throws {
        let fixture = Fixture()
        fixture.display.controls[0x10] = 0 // readback does not represent baseline luminance
        fixture.probe.verification = { index in
            let ys: [Double] = [100, 200, 60, 150, 96]
            return Fixture.white.scaled(by: ys[min(index, ys.count - 1)] / 100)
        }
        let record = try await fixture.run(.brightnessTest)
        XCTAssertEqual(record.outcome, .measured)
        XCTAssertEqual(fixture.display.writes.map(\.1), [100, 0, 50, 24])
        XCTAssertEqual(record.controls.count, 1)
        XCTAssertEqual(try XCTUnwrap(record.controls.first).restored.y, 96, accuracy: 0.001)
    }

    func testDisplayModeChangeAbortsBeforeApplying() async throws {
        let fixture = Fixture()
        fixture.display.failValidationAt = 3
        let record = try await fixture.run(.calibrate)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertTrue(fixture.display.applied.isEmpty)
        XCTAssertEqual(fixture.display.restores, 1)
    }

    func testInvalidDiagnosticSamplesCanStillBeRecorded() async throws {
        let fixture = Fixture()
        fixture.probe.verification = { _ in XYZ(x: .nan, y: 100, z: 109) }
        let record = try await fixture.run(.gammaTest)
        XCTAssertEqual(record.outcome, .failed)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try JSONExperimentRecorder(directory: directory).save(record)
        let data = try Data(contentsOf: directory.appendingPathComponent(record.id.uuidString + ".json"))
        let decoded = try ExperimentRecord.decode(data)
        XCTAssertTrue(try XCTUnwrap(decoded.attempts.last?.samples.first).sample.xyz.x.isNaN)
        XCTAssertNotNil(decoded.attempts.last?.failure)
        XCTAssertEqual(decoded.applications.count, 1)
    }

    func testProgressReportsEveryPatchAndPass() async throws {
        let fixture = Fixture()
        fixture.probe.verification = { _ in Chromaticity.d65.xyz(luminance: 95) }
        var patches: [String] = [], passes: [Int] = [], restoring = false
        fixture.engine.onProgress = { progress in
            switch progress {
            case .patch(_, _, let patch): patches.append(patch.name)
            case .passMeasured(let pass): passes.append(pass.number)
            case .restoring: restoring = true
            default: break
            }
        }
        _ = try await fixture.run(.calibrate)
        XCTAssertEqual(patches, CalibrationPatch.sequence.map(\.name))
        XCTAssertEqual(passes, [1])
        XCTAssertTrue(restoring)
    }

    func testFailureKindAndPhaseAreRecorded() async throws {
        let fixture = Fixture()
        fixture.probe.missingAt = 5 // blue
        let record = try await fixture.run(.calibrate)
        XCTAssertEqual(record.failure, .insufficientSamples)
        XCTAssertEqual(record.failedPhase, "blue")
    }

    func testSaveFailureStillHandsBackTheRestoredRecord() async throws {
        let fixture = Fixture()
        fixture.recorder.fail = true
        do {
            _ = try await fixture.run(.measureOnly)
            XCTFail("save failure not reported")
        } catch let error as RecordSaveError {
            XCTAssertEqual(error.record.outcome, .measured)
            XCTAssertEqual(fixture.display.restores, 1)
        }
    }

    func testWhiteErrorDoesNotDependOnLuminanceScale() async {
        let white = Chromaticity(x: 0.30, y: 0.315).xyz()
        XCTAssertEqual(CalibrationEngine.whiteError(white.scaled(by: 10)),
                       CalibrationEngine.whiteError(white.scaled(by: 1000)), accuracy: 1e-10)
    }

    func testRecordRoundTripRetainsConfigurationAndMeasurements() async throws {
        let fixture = Fixture()
        let record = try await fixture.run(.measureOnly)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try JSONExperimentRecorder(directory: directory).save(record)
        let data = try Data(contentsOf: directory.appendingPathComponent(record.id.uuidString + ".json"))
        let restored = try ExperimentRecord.decode(data)
        XCTAssertEqual(restored.id, record.id)
        XCTAssertEqual(restored.schemaVersion, 1)
        XCTAssertEqual(restored.softwareRevision, "test-revision")
        XCTAssertEqual(restored.display.identity, "display-1")
        XCTAssertEqual(restored.display.monitorSettings["contrast"], 50)
        XCTAssertEqual(restored.measurements.count, 12)
        XCTAssertEqual(restored.measurements[0].samples.count, 4)
        XCTAssertEqual(restored.attempts[0].samples[0].receivedAt.timeIntervalSince1970, record.attempts[0].samples[0].receivedAt.timeIntervalSince1970, accuracy: 0.000001)
        XCTAssertEqual(restored.attempts.count, 12)
        XCTAssertEqual(restored.outcome, .measured)
    }
}

@MainActor private final class Fixture {
    static let white = Chromaticity(x: 0.300, y: 0.315).xyz(luminance: 100)
    let engine = CalibrationEngine()
    let display = FakeDisplay()
    let probe = FakeProbe()
    let presenter = FakePresenter()
    let recorder = MemoryRecorder()
    func run(_ mode: CalibrationMode) async throws -> ExperimentRecord { try await run(.init(mode: mode)) }
    func run(_ configuration: CalibrationConfiguration) async throws -> ExperimentRecord {
        try await engine.run(configuration: configuration, display: display, probe: probe, presenter: presenter,
            clock: ImmediateClock(), recorder: recorder, softwareRevision: "test-revision")
    }
}
@MainActor private class ImmediateClock: CalibrationClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func sleep(seconds: Double) async throws { now.addTimeInterval(seconds) }
}
@MainActor private final class PausingClock: ImmediateClock {
    let pauseAt: Int
    var count = 0
    var paused = false
    var continuation: CheckedContinuation<Void, Never>?
    var waiter: CheckedContinuation<Void, Never>?
    init(pauseAt: Int) { self.pauseAt = pauseAt }
    override func sleep(seconds: Double) async throws {
        count += 1; now.addTimeInterval(seconds)
        if count == pauseAt {
            await withCheckedContinuation { continuation = $0; paused = true; waiter?.resume(); waiter = nil }
        }
    }
    func waitForPause() async {
        if paused { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor private final class FakeProbe: CalibrationProbe {
    let identity = ProbeIdentity(model: "test-probe", build: "test-os")
    var request: MeasurementRequest?
    var count = 0
    var missingAt: Int?
    var disconnectAt: Int?
    var verification: ((Int) -> XYZ)?
    var initialWhite = Fixture.white
    func start(_ request: MeasurementRequest) throws { self.request = request; count += 1 }
    func finish(_ request: MeasurementRequest) throws -> [TaggedMeasurement] {
        if count == disconnectAt { throw CalibrationError.disconnected }
        if count == missingAt { return [] }
        let xyz: XYZ
        if count > 12 { xyz = verification?(count - 13) ?? Fixture.white }
        else if request.phase == "black" { xyz = .zero }
        else if request.phase.hasPrefix("grey"), let level = Double(request.phase.dropFirst(4)) {
            xyz = initialWhite.scaled(by: pow(level / 100, 2.2))
        } else { xyz = initialWhite }
        return (0..<4).map { i in
            TaggedMeasurement(sessionID: request.sessionID, patchID: request.patchID,
                sample: MeasurementSample(xyz: xyz, lux: xyz.y),
                receivedAt: request.startedAt.addingTimeInterval(request.settlingSeconds + 0.1 + Double(i) * 0.4))
        }
    }
    @discardableResult func stop() -> [TaggedMeasurement] { request = nil; return [] }
}
@MainActor private final class FakeDisplay: CalibrationDisplay {
    let context = DisplayContext(identity: "display-1", name: "test", displayID: 1,
        width: 1920, height: 1080, refreshRate: 60, monitorSettings: ["contrast": 50])
    var table = [0.1, 0.4, 0.8]
    var baseline: [Double] = []
    var applied: [RGBGains] = []
    var begins = 0, restores = 0, validations = 0
    var failApply = false, failRestore = false, failNextWrite = false
    var failValidationAt: Int?
    var controls: [UInt8: UInt16] = [0x10: 30, 0x12: 50, 0x16: 49, 0x6C: 50]
    var writes: [(UInt8, UInt16)] = []
    func begin() throws { baseline = table; begins += 1 }
    func validate() throws {
        validations += 1
        if validations == failValidationAt { throw CalibrationError.displayChanged }
    }
    func setCumulativeGains(_ gains: RGBGains, gamma: Double) throws {
        applied.append(gains)
        table = GammaTable.scaledLinear(baseline, by: gains.b, gamma: gamma)
        if failApply { throw CalibrationError.invalidConfiguration }
    }
    func restore() throws {
        restores += 1
        if failRestore { throw CalibrationError.displayChanged }
        table = baseline
    }
    func readControl(_ code: UInt8) throws -> DDCValue {
        guard let value = controls[code] else { throw CalibrationError.controlUnavailable(code) }
        return DDCValue(current: value, maximum: 100)
    }
    func writeControl(_ code: UInt8, value: UInt16) throws {
        writes.append((code, value)); controls[code] = value
        if failNextWrite { failNextWrite = false; throw CalibrationError.writeFailed(code) }
    }
}
@MainActor private final class FakePresenter: PatchPresenter {
    var closed = false
    func show(_ patch: CalibrationPatch) async throws { closed = false }
    func close() { closed = true }
}
@MainActor private final class MemoryRecorder: ExperimentRecorder {
    var records: [ExperimentRecord] = []
    var fail = false
    func save(_ record: ExperimentRecord) throws {
        if fail { throw CocoaError(.fileWriteOutOfSpace) }
        records.append(record)
    }
}

@MainActor final class MetricAndObserverTests: XCTestCase {
    private func run(_ configuration: CalibrationConfiguration, verification: @escaping (Int) -> XYZ) async throws -> ExperimentRecord {
        let display = MetricFakeDisplay(), probe = MetricFakeProbe(verification: verification)
        return try await CalibrationEngine().run(configuration: configuration, display: display, probe: probe,
            presenter: MetricFakePresenter(), clock: MetricClock(), recorder: MetricRecorder(), softwareRevision: "t")
    }

    func testCAM16UCSSessionsScoreAndReportInBothMetrics() async throws {
        var configuration = CalibrationConfiguration(mode: .calibrate)
        configuration.metric = .cam16ucs
        let record = try await run(configuration) { _ in Chromaticity.d65.xyz(luminance: 95) }
        XCTAssertEqual(record.outcome, .converged)
        XCTAssertEqual(record.whiteErrorMetric, WhiteErrorMetric.cam16ucs.definition)
        XCTAssertEqual(record.observer, .cie1931TwoDegree)
        let baseline = try XCTUnwrap(record.baselineDeltaE)
        XCTAssertEqual(baseline, WhiteErrorMetric.cam16ucs.whiteError(MetricFakeProbe.white), accuracy: 1e-9)
        let reports = try XCTUnwrap(record.metricReports)
        XCTAssertEqual(reports.map(\.metric), [.ciede2000, .cam16ucs])
        XCTAssertEqual(reports[1].baseline, baseline, accuracy: 1e-9)
        XCTAssertEqual(reports[0].baseline, CalibrationEngine.whiteError(MetricFakeProbe.white), accuracy: 1e-9)
        XCTAssertEqual(reports[0].best, 0, accuracy: 1e-6, "verified white is D65 itself")
        XCTAssertTrue(SessionSummary(record: record).detail.contains("ΔE CAM16-UCS"))
    }

    func testCIE2015ObserverTargetsAreEnabledAndUsedForSolvingAndReporting() async throws {
        for observer in [Observer.cie2015TwoDegree, .cie2015TenDegree] {
            let target = try XCTUnwrap(observer.d65)
            for metric in WhiteErrorMetric.allCases {
                var configuration = CalibrationConfiguration(mode: .calibrate)
                configuration.observer = observer
                configuration.metric = metric
                let display = MetricFakeDisplay()
                let record = try await CalibrationEngine().run(configuration: configuration, display: display,
                    probe: MetricFakeProbe(observer: observer) { _ in target.xyz(luminance: 95) }, presenter: MetricFakePresenter(),
                    clock: MetricClock(), recorder: MetricRecorder(), softwareRevision: "t")
                XCTAssertEqual(record.outcome, .converged)
                XCTAssertEqual(display.begins, 1)
                XCTAssertEqual(record.observer, observer)
                XCTAssertEqual(try XCTUnwrap(record.baselineDeltaE), metric.whiteError(metricWhite, target: target), accuracy: 1e-10)
                XCTAssertEqual(try XCTUnwrap(display.applied.first), WhitePointSolver.gains(measuredWhite: metricWhite, target: target))
                XCTAssertEqual(try XCTUnwrap(record.bestDeltaE), 0, accuracy: 1e-9)
                for report in try XCTUnwrap(record.metricReports) { XCTAssertEqual(report.best, 0, accuracy: 1e-9) }
            }
        }
    }

    func testResidualSolveKeepsTheSelectedObserverTarget() async throws {
        let observer = Observer.cie2015TenDegree
        let target = try XCTUnwrap(observer.d65)
        let initial = try XCTUnwrap(metricWhite.chromaticity)
        let halfway = Chromaticity(x: (initial.x + target.x) / 2, y: (initial.y + target.y) / 2).xyz(luminance: 95)
        var configuration = CalibrationConfiguration(mode: .calibrate)
        configuration.observer = observer
        configuration.targetDeltaE = 0.1
        let display = MetricFakeDisplay()
        let record = try await CalibrationEngine().run(configuration: configuration, display: display,
            probe: MetricFakeProbe(observer: observer) { $0 == 0 ? halfway : target.xyz(luminance: 93) },
            presenter: MetricFakePresenter(), clock: MetricClock(), recorder: MetricRecorder(), softwareRevision: "t")
        XCTAssertEqual(record.outcome, .converged)
        XCTAssertEqual(record.passes.count, 2)
        let first = try XCTUnwrap(display.applied.first)
        let second = try XCTUnwrap(display.applied.dropFirst().first)
        let expectedResidual = WhitePointSolver.gains(measuredWhite: halfway, target: target)
        XCTAssertEqual(second.r, first.r * expectedResidual.r, accuracy: 1e-12)
        XCTAssertEqual(second.g, first.g * expectedResidual.g, accuracy: 1e-12)
        XCTAssertEqual(second.b, first.b * expectedResidual.b, accuracy: 1e-12)
    }

    func testChangingTheObserverCannotRelabelAnExisting1931Probe() async throws {
        var configuration = CalibrationConfiguration(mode: .calibrate)
        configuration.observer = .cie2015TenDegree
        let display = MetricFakeDisplay()
        let record = try await CalibrationEngine().run(configuration: configuration, display: display,
            probe: MetricFakeProbe { _ in .zero }, presenter: MetricFakePresenter(), clock: MetricClock(),
            recorder: MetricRecorder(), softwareRevision: "t")
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.failure, .invalidConfiguration)
        XCTAssertEqual(display.begins, 0)
    }

    func testOlderRecordsAndStoresDecodeWithDefaults() throws {
        let configuration = try JSONDecoder().decode(CalibrationConfiguration.self, from: Data("""
            {"mode":"calibrate","settlingSeconds":0.5,"samplingSeconds":2,"minimumSamples":3,"maximumPasses":3,
             "targetDeltaE":2,"gate":{"minimumPreCorrectionDeltaE":2.5,"maximumPostCorrectionDeltaE":5,"maximumLuminanceLoss":0.2}}
            """.utf8))
        XCTAssertEqual(configuration.metric, .ciede2000)
        XCTAssertEqual(configuration.observer, .cie1931TwoDegree)
        let stored = try JSONDecoder().decode(StoredCorrection.self, from: Data("""
            {"id":"05C682F6-10F3-459E-A4E0-6D319CC6680D","displayIdentity":"d","displayName":"K27","width":3840,
             "height":2160,"refreshRate":60,"gains":{"r":0.98,"g":1,"b":0.93},"gamma":2.1,"baselineDeltaE":4.18,
             "deltaE":1.69,"createdAt":0,"monitorSettings":{"contrast":50}}
            """.utf8))
        XCTAssertNil(stored.metric)
    }
}

private let metricWhite = Chromaticity(x: 0.300, y: 0.315).xyz(luminance: 100)
@MainActor private final class MetricClock: CalibrationClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func sleep(seconds: Double) async throws { now.addTimeInterval(seconds) }
}
@MainActor private final class MetricFakeProbe: CalibrationProbe {
    static let white = metricWhite
    let identity = ProbeIdentity(model: "test", build: "test")
    let verification: (Int) -> XYZ
    let observer: Observer
    var count = 0
    init(observer: Observer = .cie1931TwoDegree, verification: @escaping (Int) -> XYZ) {
        self.observer = observer; self.verification = verification
    }
    func start(_ request: MeasurementRequest) throws { count += 1 }
    func finish(_ request: MeasurementRequest) throws -> [TaggedMeasurement] {
        let xyz: XYZ
        if count > 12 { xyz = verification(count - 13) }
        else if request.phase == "black" { xyz = .zero }
        else if request.phase.hasPrefix("grey"), let level = Double(request.phase.dropFirst(4)) {
            xyz = metricWhite.scaled(by: pow(level / 100, 2.2))
        } else { xyz = metricWhite }
        return (0..<4).map { i in
            TaggedMeasurement(sessionID: request.sessionID, patchID: request.patchID, sample: MeasurementSample(xyz: xyz, lux: xyz.y),
                receivedAt: request.startedAt.addingTimeInterval(request.settlingSeconds + 0.1 + Double(i) * 0.4))
        }
    }
    @discardableResult func stop() -> [TaggedMeasurement] { [] }
}
@MainActor private final class MetricFakeDisplay: CalibrationDisplay {
    let context = DisplayContext(identity: "d", name: "test", displayID: 1, width: 1, height: 1, refreshRate: 60)
    var begins = 0
    var applied: [RGBGains] = []
    func begin() throws { begins += 1 }
    func validate() throws {}
    func setCumulativeGains(_ gains: RGBGains, gamma: Double) throws { applied.append(gains) }
    func restore() throws {}
    func readControl(_ code: UInt8) throws -> DDCValue { throw CalibrationError.controlUnavailable(code) }
    func writeControl(_ code: UInt8, value: UInt16) throws { throw CalibrationError.controlUnavailable(code) }
}
@MainActor private final class MetricFakePresenter: PatchPresenter {
    func show(_ patch: CalibrationPatch) async throws {}
    func close() {}
}
@MainActor private final class MetricRecorder: ExperimentRecorder {
    func save(_ record: ExperimentRecord) throws {}
}
