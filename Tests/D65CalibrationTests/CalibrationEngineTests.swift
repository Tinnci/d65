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
