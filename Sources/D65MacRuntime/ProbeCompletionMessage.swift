import D65Calibration
import D65Core
import D65Link

/// Preserve outcome semantics even when a failed/cancelled run contains earlier good passes.
enum ProbeCompletionMessage {
    static func make(for record: ExperimentRecord) -> CalibrationMessage {
        let title = SessionSummary(record: record).title
        if !record.restorationErrors.isEmpty || record.outcome == .failed {
            return .failure(code: LinkFailure.session.rawValue, message: title)
        }
        if record.outcome == .cancelled || record.outcome == .measured {
            let code: LinkFailure = record.outcome == .cancelled ? .cancelled : .measurementComplete
            return .failure(code: code.rawValue, message: title)
        }
        if let before = record.baselineDeltaE {
            return .result(gains: record.bestGains ?? .identity, preDeltaE: before,
                postDeltaE: record.bestDeltaE ?? before, verdict: SessionSummary.probeVerdict(for: record))
        }
        return .failure(code: LinkFailure.session.rawValue, message: title)
    }
}
