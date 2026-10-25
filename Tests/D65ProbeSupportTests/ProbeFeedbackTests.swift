import D65Measurement
import D65ProbeSupport
import XCTest

final class ProbeFeedbackTests: XCTestCase {
    func testPatternsStayShortAndPerceptibleAtBothEnabledStrengths() {
        for cue in ProbeHapticCue.allCases {
            for strength in [ProbeHapticStrength.subtle, .clear] {
                let plan = cue.plan(strength: strength)
                XCTAssertFalse(plan.pulses.isEmpty)
                XCTAssertLessThanOrEqual(plan.duration, 0.31)
                for pulse in plan.pulses {
                    XCTAssertGreaterThanOrEqual(pulse.intensity, 0.3, "\(cue) would be lost on the hardware")
                    XCTAssertLessThanOrEqual(pulse.intensity, 0.9)
                    XCTAssertTrue((0.3...0.6).contains(pulse.sharpness))
                }
            }
        }
        XCTAssertGreaterThan(ProbeHapticCue.measurementStarted.plan(strength: .clear).pulses[0].intensity,
                             ProbeHapticCue.measurementStarted.plan(strength: .subtle).pulses[0].intensity)
        XCTAssertNotEqual(ProbeHapticCue.success.plan(strength: .subtle).pulses,
                          ProbeHapticCue.failure.plan(strength: .subtle).pulses)
    }

    func testBurstsAndRepeatedTerminalEventsDoNotBecomeVibrationLoops() {
        var policy = ProbeFeedbackPolicy()
        XCTAssertNotNil(policy.request(.connected, at: 0))
        XCTAssertNil(policy.request(.placement, at: 0.1), "connection and placement often arrive together")
        XCTAssertNotNil(policy.request(.placement, at: 0.4))
        XCTAssertNil(policy.request(.placement, at: 0.8))
        XCTAssertNotNil(policy.request(.success, at: 1))
        XCTAssertNil(policy.request(.cancelled, at: 1.1), "sessionEnded must not duplicate a result")
        XCTAssertNil(policy.request(.success, at: 5))
        policy.beginPlacement()
        XCTAssertNotNil(policy.request(.success, at: 6), "a new session can report the same outcome")
    }

    func testAutomaticConnectionRetriesStayQuietUntilAPlacementIsAccepted() {
        var policy = ProbeFeedbackPolicy()
        XCTAssertNotNil(policy.request(.disconnected, at: 0))
        for time in [10.0, 20, 30] {
            XCTAssertNil(policy.request(.connected, at: time))
            XCTAssertNil(policy.request(.refused, at: time + 0.1))
            XCTAssertNil(policy.request(.disconnected, at: time + 0.2))
        }
        policy.beginPlacement()
        XCTAssertNotNil(policy.request(.placement, at: 40))
        XCTAssertNotNil(policy.request(.disconnected, at: 41))
    }

    func testARefusalAfterAnEarlierOutcomeAlsoSilencesAutomaticRetries() {
        var policy = ProbeFeedbackPolicy()
        XCTAssertNotNil(policy.request(.success, at: 0))
        XCTAssertNil(policy.request(.refused, at: 5))
        XCTAssertNil(policy.request(.connected, at: 10))
        XCTAssertNil(policy.request(.disconnected, at: 11))
        policy.beginPlacement()
        XCTAssertNotNil(policy.request(.connected, at: 20))
    }

    func testOptOutAndBackgroundSuppressCuesWithoutQueueingThem() {
        var policy = ProbeFeedbackPolicy(strength: .off)
        XCTAssertNil(policy.request(.measurementStarted, at: 0))
        XCTAssertTrue(policy.permitsColourSample(at: 0))
        policy.strength = .subtle
        policy.setActive(false)
        XCTAssertNil(policy.request(.failure, at: 1))
        XCTAssertFalse(policy.permitsColourSample(at: 1))
        policy.setActive(true)
        XCTAssertTrue(policy.permitsColourSample(at: 2))
        XCTAssertNotNil(policy.request(.selection, at: 2))
    }

    func testColourSamplesWaitForActualPlaybackEndAndSettling() {
        var policy = ProbeFeedbackPolicy()
        _ = policy.request(.connected, at: 0)
        policy.playbackBegan()
        XCTAssertFalse(policy.permitsColourSample(at: 50), "an assumed duration cannot release the guard")
        policy.playbackEnded(at: 51)
        XCTAssertFalse(policy.permitsColourSample(at: 51.24))
        XCTAssertTrue(policy.permitsColourSample(at: 51.25))
        policy.strength = .off
        XCTAssertTrue(policy.permitsColourSample(at: 52))
    }

    func testDisablingHapticsCannotReleaseAnAlreadyPlayingVibration() {
        var policy = ProbeFeedbackPolicy()
        policy.playbackBegan()
        policy.strength = .off
        XCTAssertFalse(policy.permitsColourSample(at: 5))
        policy.playbackEnded(at: 6)
        XCTAssertFalse(policy.permitsColourSample(at: 6.1))
        XCTAssertTrue(policy.permitsColourSample(at: 6.25))
    }

    func testPatchCuesFitOnlyInSettlingAndNeverReplayForDuplicateRequests() throws {
        var policy = ProbeFeedbackPolicy()
        let first = UUID(), next = UUID()
        XCTAssertEqual(try XCTUnwrap(policy.openWindow(id: first, first: true, verification: false, settlingSeconds: 0.5, at: 0)).cue, .measurementStarted)
        XCTAssertNil(policy.openWindow(id: first, first: true, verification: false, settlingSeconds: 0.5, at: 1))
        XCTAssertNil(policy.request(.selection, at: 1))
        XCTAssertNil(policy.request(.alignmentFinished, at: 1))
        policy.closeWindow(id: UUID())
        XCTAssertNil(policy.request(.selection, at: 2), "a stale close cannot unlock a current window")
        policy.closeWindow(id: first)
        XCTAssertEqual(try XCTUnwrap(policy.openWindow(id: next, first: false, verification: true, settlingSeconds: 0.5, at: 3)).cue, .verification)
        policy.closeWindow(id: next)
        XCTAssertNotNil(policy.request(.selection, at: 4))
    }

    func testShortSettlingWindowsAndActivePlaybackSkipPatchFeedback() {
        var policy = ProbeFeedbackPolicy()
        XCTAssertNil(policy.openWindow(id: UUID(), first: false, verification: false, settlingSeconds: 0.1, at: 0))
        XCTAssertNil(policy.request(.selection, at: 2))
        policy.endWindows()
        policy.playbackBegan()
        XCTAssertNil(policy.openWindow(id: UUID(), first: true, verification: false, settlingSeconds: 0.5, at: 3))
        XCTAssertFalse(policy.permitsColourSample(at: 10))
    }

    func testContinuousAlignmentFramesProduceOnlySustainedMilestones() throws {
        var policy = ProbeFeedbackPolicy()
        _ = policy.alignment(.init(status: .starting, message: "Starting"), at: 0)
        let tilted = DepthAlignmentReading(status: .estimate, distanceMeters: 0.5, tiltDegrees: 12, message: "Surface")
        XCTAssertNil(policy.alignment(tilted, at: 1))
        XCTAssertNil(policy.alignment(tilted, at: 1.5))
        XCTAssertEqual(try XCTUnwrap(policy.alignment(tilted, at: 1.61)).cue, .surfaceFound)
        for i in 0..<20 { XCTAssertNil(policy.alignment(tilted, at: 2 + Double(i) * 0.2)) }
        let level = DepthAlignmentReading(status: .estimate, distanceMeters: 0.5, tiltDegrees: 2, message: "Surface")
        XCTAssertNil(policy.alignment(level, at: 7))
        XCTAssertEqual(try XCTUnwrap(policy.alignment(level, at: 7.61)).cue, .surfaceLevel)
        for i in 0..<20 {
            let jitter = DepthAlignmentReading(status: .estimate, distanceMeters: 0.5, tiltDegrees: i % 2 == 0 ? 2.9 : 3.2, message: "Surface")
            XCTAssertNil(policy.alignment(jitter, at: 8 + Double(i) * 0.2))
        }
        let near = DepthAlignmentReading(status: .estimate, distanceMeters: 0.28, tiltDegrees: 2, message: "Surface")
        XCTAssertNil(policy.alignment(near, at: 13))
        XCTAssertEqual(try XCTUnwrap(policy.alignment(near, at: 13.61)).cue, .alignmentNear)
        XCTAssertNil(policy.alignment(near, at: 16))
    }

    func testMissingDepthWarnsOnceAndNeverClaimsContactOrRepeatsAtCameraRate() throws {
        var policy = ProbeFeedbackPolicy()
        _ = policy.alignment(.init(status: .starting, message: "Starting"), at: 0)
        let missing = DepthAlignmentReading(status: .noReliableDepth, message: "No reliable depth")
        XCTAssertNil(policy.alignment(missing, at: 1))
        XCTAssertNil(policy.alignment(missing, at: 1.8))
        XCTAssertEqual(try XCTUnwrap(policy.alignment(missing, at: 2.1)).cue, .alignmentUnavailable)
        for i in 0..<30 { XCTAssertNil(policy.alignment(missing, at: 3 + Double(i) * 0.2)) }
        let contact = DepthAlignmentReading(status: .estimate, distanceMeters: 0.005, tiltDegrees: 0, message: "Invalid close depth")
        XCTAssertNil(policy.alignment(contact, at: 12))
    }

    func testOrdinaryPatchesAreSilentButStillBlockOtherCues() {
        var policy = ProbeFeedbackPolicy(strength: .clear)
        XCTAssertNotNil(policy.openWindow(id: UUID(), first: true, verification: false, settlingSeconds: 0.5, at: 0))
        policy.playbackEnded(at: 0.2)
        let patch = UUID()
        XCTAssertNil(policy.openWindow(id: patch, first: false, verification: false, settlingSeconds: 0.5, at: 5))
        XCTAssertNil(policy.request(.connected, at: 6), "an open sample window still blocks other cues")
        policy.closeWindow(id: patch)
        XCTAssertNotNil(policy.request(.selection, at: 7))
    }
}
