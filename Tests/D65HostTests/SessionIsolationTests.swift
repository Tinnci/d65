import D65Calibration
import D65Core
import D65Measurement
import XCTest
@testable import D65Host

/// A connection that records what was sent and never touches the network.
@MainActor private final class RecordingConnection: ProbeConnection {
    var sent: [Data] = []
    var cancelled = false
    func start(onData: @escaping (Data) -> Void, onClose: @escaping () -> Void) {}
    func send(_ data: Data, completion: (() -> Void)?) { sent.append(data); completion?() }
    func cancel() { cancelled = true }
}

@MainActor final class SessionIsolationTests: XCTestCase {
    func testSecondConnectionCannotReplaceOwnerOrReleaseItsLease() async {
        let first = NSObject(), second = NSObject()
        var lease = ProbeConnectionLease()
        XCTAssertTrue(lease.claim(ObjectIdentifier(first)))
        XCTAssertFalse(lease.claim(ObjectIdentifier(second)))
        lease.release(ObjectIdentifier(second))
        XCTAssertEqual(lease.owner, ObjectIdentifier(first))
        // The host releases the first lease only after its task finishes restoration.
        lease.release(ObjectIdentifier(first))
        XCTAssertTrue(lease.claim(ObjectIdentifier(second)))
    }
    func testProbeDropsSamplesFromOtherSessionsAndPreviousPatches() async throws {
        let connection = RecordingConnection()
        let probe = NetworkProbe(identity: .init(model: "test", build: "test"), connection: connection)
        let first = MeasurementRequest(sessionID: UUID(), phase: "white", startedAt: Date(), settlingSeconds: 0, samplingSeconds: 2)
        let second = MeasurementRequest(sessionID: first.sessionID, phase: "white", startedAt: Date(), settlingSeconds: 0, samplingSeconds: 2)
        let sample = MeasurementSample(xyz: .init(x: 95, y: 100, z: 109), lux: 100)
        try probe.start(first)
        probe.append(sessionID: first.sessionID, patchID: first.patchID, sample: sample)
        try probe.start(second)
        probe.append(sessionID: first.sessionID, patchID: first.patchID, sample: sample)
        probe.append(sessionID: UUID(), patchID: second.patchID, sample: sample)
        probe.append(sessionID: second.sessionID, patchID: second.patchID, sample: sample)
        let kept = try probe.finish(second)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].patchID, second.patchID)
        probe.connected = false
        XCTAssertThrowsError(try probe.start(first))
        XCTAssertFalse(connection.sent.isEmpty, "requests and ends are sent to the phone")
    }
}
