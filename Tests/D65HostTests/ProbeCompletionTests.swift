import D65Calibration
import D65Core
import D65Link
import XCTest
@testable import D65Host

final class ProbeCompletionTests: XCTestCase {
    private func record(_ outcome: CalibrationOutcome) -> ExperimentRecord {
        var record = ExperimentRecord(startedAt: Date(), softwareRevision: "test", configuration: .init(mode: .calibrate),
            display: .init(identity: "d", name: "test", displayID: 1, width: 1920, height: 1080, refreshRate: 60),
            probe: .init(model: "test", build: "test"))
        record.outcome = outcome
        record.baselineDeltaE = 8
        record.bestDeltaE = 1
        record.bestGains = .init(r: 0.95, g: 1, b: 0.9)
        return record
    }
    func testCancelledRunWithAnEarlierGoodPassStillAnnouncesCancellation() {
        guard case .failure(let code, _) = ProbeCompletionMessage.make(for: record(.cancelled)) else {
            return XCTFail("cancel must not become an improved result")
        }
        XCTAssertEqual(code, LinkFailure.cancelled.rawValue)
    }
    func testMeasurementOnlyUsesInformationalCompletion() {
        guard case .failure(let code, _) = ProbeCompletionMessage.make(for: record(.measured)) else {
            return XCTFail("expected a typed informational completion")
        }
        XCTAssertEqual(code, LinkFailure.measurementComplete.rawValue)
    }
    func testRestorationFailureOverridesAGoodMeasuredResult() {
        var record = record(.converged)
        record.restorationErrors = ["restore failed"]
        guard case .failure(let code, _) = ProbeCompletionMessage.make(for: record) else {
            return XCTFail("restoration errors cannot announce success")
        }
        XCTAssertEqual(code, LinkFailure.session.rawValue)
    }
    func testFailedRunWithEarlierGoodGainsStillAnnouncesFailure() {
        guard case .failure(let code, _) = ProbeCompletionMessage.make(for: record(.failed)) else {
            return XCTFail("failed runs cannot announce success")
        }
        XCTAssertEqual(code, LinkFailure.session.rawValue)
    }
    func testPredictionRejectionWithoutAnyAppliedPassIsANoChangeResult() {
        var record = record(.rejected)
        record.bestGains = nil; record.bestDeltaE = nil
        guard case .result(let gains, let before, let after, let verdict) = ProbeCompletionMessage.make(for: record) else {
            return XCTFail("a rejected prediction is not a sensor failure")
        }
        XCTAssertEqual(gains, .identity)
        XCTAssertEqual(before, after)
        XCTAssertEqual(verdict, .rejected)
    }
}
