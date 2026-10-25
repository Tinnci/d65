import D65Calibration
import D65Core
import D65Display
import D65Measurement
import XCTest

@MainActor final class PlacementMonitorTests: XCTestCase {
    private func sample(_ y: Double) -> MeasurementSample { MeasurementSample(xyz: XYZ(x: y * 0.95, y: y, z: y * 1.09), lux: y) }

    func testSettlesAfterSteadyReadings() {
        var monitor = PlacementMonitor()
        let start = Date(timeIntervalSince1970: 0)
        var last = PlacementReading(state: .waiting)
        for i in 0...7 { last = monitor.add(sample(128 + Double(i % 2)), stable: true, at: start.addingTimeInterval(Double(i) * 0.25)) }
        XCTAssertEqual(last.state, .settled)
        XCTAssertEqual(last.steadyFraction, 1)
    }

    func testMotionAndJumpsRestartTheRun() {
        var monitor = PlacementMonitor()
        let t = Date(timeIntervalSince1970: 0)
        _ = monitor.add(sample(128), stable: true, at: t)
        XCTAssertEqual(monitor.add(sample(128), stable: false, at: t.addingTimeInterval(0.25)).state, .moving)
        _ = monitor.add(sample(128), stable: true, at: t.addingTimeInterval(0.5))
        let jumped = monitor.add(sample(90), stable: true, at: t.addingTimeInterval(1.9))
        XCTAssertEqual(jumped.state, .settling)
        XCTAssertEqual(jumped.steadyFraction, 0)
    }

    func testDarkAndSilentStates() {
        var monitor = PlacementMonitor()
        let t = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(monitor.tick(at: t).state, .waiting)
        XCTAssertEqual(monitor.add(sample(1), stable: true, at: t).state, .tooDark)
        _ = monitor.add(sample(128), stable: true, at: t.addingTimeInterval(0.1))
        XCTAssertEqual(monitor.tick(at: t.addingTimeInterval(2)).state, .moving)
    }
}

private final class MemoryBackend: TransferTableBackend, @unchecked Sendable {
    var table = DisplayTransferSnapshot(displayID: 1, red: [0, 0.5, 1], green: [0, 0.5, 1], blue: [0, 0.5, 1])
    let original: DisplayTransferSnapshot
    init() { original = table }
    func probe() throws -> DisplayTransferSnapshot { table }
    func restore(_ snapshot: DisplayTransferSnapshot) throws { table = snapshot }
    var isOriginal: Bool { table.blue == original.blue }
}

@MainActor final class CorrectionHoldTests: XCTestCase {
    func testPreviewKeepPauseAndRelease() throws {
        let backend = MemoryBackend()
        let hold = CorrectionHold(backend: backend)
        try hold.preview(RGBGains(r: 1, g: 1, b: 0.85), gamma: 2.2)
        XCTAssertEqual(hold.state, .previewing)
        XCTAssertFalse(backend.isOriginal)
        hold.keep()
        XCTAssertEqual(hold.state, .held)
        try hold.showOriginal(true)
        XCTAssertTrue(backend.isOriginal)
        try hold.showOriginal(false)
        XCTAssertFalse(backend.isOriginal)
        try hold.setPaused(true)
        XCTAssertEqual(hold.state, .paused)
        XCTAssertTrue(backend.isOriginal)
        try hold.setPaused(false)
        XCTAssertEqual(hold.state, .held)
        try hold.release()
        XCTAssertEqual(hold.state, .none)
        XCTAssertTrue(backend.isOriginal)
    }

    func testReassertDoesNotCompoundTheCorrection() throws {
        let backend = MemoryBackend()
        let hold = CorrectionHold(backend: backend)
        try hold.hold(RGBGains(r: 1, g: 1, b: 0.8), gamma: 2.2)
        let corrected = backend.table.blue
        try hold.reassert()
        XCTAssertEqual(backend.table.blue, corrected)
    }
}

@MainActor final class CorrectionStoreTests: XCTestCase {
    private func record(contrast: UInt16 = 50) -> ExperimentRecord {
        var record = ExperimentRecord(startedAt: Date(), softwareRevision: "t", configuration: .init(mode: .calibrate),
            display: DisplayContext(identity: "uuid-1", name: "HAN K27", displayID: 2, width: 3840, height: 2160,
                refreshRate: 60, monitorSettings: ["contrast": contrast, "preset": 5]),
            probe: ProbeIdentity(model: "iPhone18,4", build: "t"))
        record.gamma = 2.11; record.baselineDeltaE = 4.8; record.bestDeltaE = 0.6
        record.bestGains = RGBGains(r: 0.99, g: 1, b: 0.86); record.outcome = .converged
        return record
    }

    func testRoundTripAndLookup() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/c.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let r = record()
        try CorrectionStore(url: url).save(StoredCorrection(record: r, gains: r.bestGains!))
        let reloaded = CorrectionStore(url: url)
        let found = try XCTUnwrap(reloaded.correction(for: "uuid-1", modeSignature: "3840×2160@60"))
        XCTAssertEqual(found.gains, r.bestGains)
        XCTAssertEqual(found.gamma, 2.11)
        XCTAssertNotNil(reloaded.correction(for: "uuid-1", modeSignature: "1920×1080@60"), "falls back to the display's latest")
        try reloaded.remove(displayIdentity: "uuid-1")
        XCTAssertNil(CorrectionStore(url: url).correction(for: "uuid-1", modeSignature: "3840×2160@60"))
    }

    func testStaleness() {
        let r = record()
        let stored = StoredCorrection(record: r, gains: r.bestGains!)
        XCTAssertNil(stored.staleReason(modeSignature: "3840×2160@60", monitorSettings: ["contrast": 50, "preset": 5]))
        XCTAssertNil(stored.staleReason(modeSignature: "3840×2160@60", monitorSettings: [:]), "unknown is not stale")
        XCTAssertEqual(stored.staleReason(modeSignature: "3840×2160@60", monitorSettings: ["contrast": 65]),
                       .settingChanged(name: "contrast", from: 50, to: 65))
        XCTAssertEqual(stored.staleReason(modeSignature: "2560×1440@60", monitorSettings: [:]),
                       .modeChanged(from: "3840×2160@60", to: "2560×1440@60"))
    }
}

final class SessionSummaryTests: XCTestCase {
    private func record(_ outcome: CalibrationOutcome, before: Double? = 4.8, best: Double? = 0.6,
                        gains: RGBGains? = RGBGains(r: 1, g: 1, b: 0.86)) -> ExperimentRecord {
        var record = ExperimentRecord(startedAt: Date(), softwareRevision: "t", configuration: .init(mode: .calibrate),
            display: DisplayContext(identity: "d", name: "HAN K27", displayID: 2, width: 1, height: 1, refreshRate: 60),
            probe: ProbeIdentity(model: "p", build: "b"))
        record.outcome = outcome; record.baselineDeltaE = before; record.bestDeltaE = best; record.bestGains = gains
        return record
    }

    func testOnlyImprovingOutcomesCanBeKept() {
        XCTAssertTrue(SessionSummary(record: record(.converged)).canKeep)
        XCTAssertTrue(SessionSummary(record: record(.exhausted, best: 2.6)).canKeep)
        XCTAssertFalse(SessionSummary(record: record(.stoppedImproving, best: 4.8, gains: .identity)).canKeep)
        XCTAssertFalse(SessionSummary(record: record(.confirmed, before: 1.2, best: 1.2, gains: .identity)).canKeep)
        XCTAssertFalse(SessionSummary(record: record(.rejected, gains: .identity)).canKeep)
        XCTAssertFalse(SessionSummary(record: record(.exhausted, before: 9, best: 6)).canKeep, "above the gate ceiling")
    }

    func testRestorationErrorsDominate() {
        var r = record(.converged)
        r.restorationErrors = ["displayChanged"]
        let summary = SessionSummary(record: r)
        XCTAssertEqual(summary.tone, .critical)
        XCTAssertFalse(summary.canKeep)
    }

    func testFailureNamesThePhase() {
        var r = record(.failed, before: nil, best: nil, gains: nil)
        r.failure = .noConsensus; r.failedPhase = "blue"
        XCTAssertEqual(SessionSummary(record: r).title, "Readings for blue disagreed")
    }

    func testProbeVerdictReportsLevelledOffImprovementAsImproved() {
        XCTAssertEqual(SessionSummary.probeVerdict(for: record(.stoppedImproving, best: 2.6)), .improved)
        XCTAssertEqual(SessionSummary.probeVerdict(for: record(.rejected, gains: .identity)), .rejected)
    }
}
