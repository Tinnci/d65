import D65Core
import Foundation

/// What a finished session means for the user: one sentence, a reason, and whether the result can be kept.
public struct SessionSummary: Sendable, Equatable {
    public enum Tone: String, Sendable { case success, partial, info, warning, critical }

    public let tone: Tone
    public let title: String
    public let detail: String
    public let suggestion: String?
    /// The best measured pass improved on the baseline and passes the gate's ceiling.
    public let canKeep: Bool
    /// The phone can be placed again and the session retried without reconnecting.
    public let canRetry: Bool

    public init(record: ExperimentRecord) {
        let display = record.display.name
        let before = record.baselineDeltaE, best = record.bestDeltaE
        let improved = record.bestGains.map { !$0.isIdentity } == true && before != nil && best != nil
            && best! < before! && best! <= record.configuration.gate.maximumPostCorrectionDeltaE
        let fmt = { (value: Double) in String(format: "%.1f", value) }

        if !record.restorationErrors.isEmpty {
            tone = .critical
            title = "D65 couldn’t confirm \(display) was restored"
            detail = record.restorationErrors.joined(separator: "\n")
            suggestion = "Reset the display’s colours, then check the monitor’s own settings."
            canKeep = false; canRetry = false
            return
        }
        switch record.outcome {
        case .converged:
            tone = .success; title = "White is within tolerance"
            detail = "ΔE00 to D65 went from \(fmt(before ?? .nan)) to \(fmt(best ?? .nan)), measured in this session."
            suggestion = nil; canKeep = improved; canRetry = true
        case .stoppedImproving, .exhausted:
            tone = improved ? .partial : .info
            title = improved ? "Improved, then levelled off" : "No pass improved the white"
            detail = improved
                ? "ΔE00 went from \(fmt(before!)) to \(fmt(best!)). Further passes didn’t help, so the best pass is shown."
                : "Every measured correction was no better than the original, so nothing is applied."
            suggestion = improved ? nil : "Make sure the phone stays flat and still, then try again."
            canKeep = improved; canRetry = true
        case .confirmed:
            tone = .success; title = "Already within tolerance"
            detail = "White measured ΔE00 \(fmt(before ?? .nan)) from D65, inside the \(fmt(record.configuration.gate.minimumPreCorrectionDeltaE)) threshold. No correction is needed."
            suggestion = nil; canKeep = false; canRetry = true
        case .rejected:
            tone = .info; title = "No correction passed the quality gate"
            detail = record.terminationReason.contains("luminance")
                ? "Fixing this white would dim the screen by more than \(Int(record.configuration.gate.maximumLuminanceLoss * 100)) %. \(display) is unchanged."
                : "No correction was predicted to help enough. \(display) is unchanged."
            suggestion = "Try the monitor’s 6500 K or sRGB picture preset, then calibrate again."
            canKeep = false; canRetry = true
        case .measured:
            tone = .info; title = "Measurement complete"
            detail = before.map { "White measured ΔE00 \(fmt($0)) from D65. Nothing was changed." } ?? "Nothing was changed."
            suggestion = nil; canKeep = false; canRetry = true
        case .cancelled:
            tone = .info; title = "Cancelled"
            detail = "\(display) is back to its original white."
            suggestion = nil; canKeep = false; canRetry = true
        case .failed:
            let phase = record.failedPhase ?? "a patch"
            canKeep = false; canRetry = true; suggestion = nil
            switch record.failure {
            case .noConsensus, .insufficientSamples:
                tone = .warning; title = "Readings for \(phase) disagreed"
                detail = "The phone probably moved during the patch. \(display) is back to its original white."
            case .invalidMeasurement:
                tone = .warning; title = "The phone read almost no light"
                detail = "Its top edge, where the sensor is, must sit inside the outline, pressed flat against the screen."
            case .disconnected:
                tone = .warning; title = "The iPhone disconnected during \(phase)"
                detail = "Keep D65 Probe open and the phone on the same Wi-Fi. \(display) is back to its original white."
            case .displayChanged:
                tone = .warning; title = "\(display) changed mode during the session"
                detail = "Leave resolution and refresh rate unchanged while measuring. The display was restored."
            default:
                tone = .warning; title = "The session stopped"
                detail = record.terminationReason
            }
        }
    }

    /// The verdict the probe shows. Only a kept-worthy result is reported as improved.
    public static func probeVerdict(for record: ExperimentRecord) -> CalibrationVerdict {
        if record.outcome == .confirmed { return .confirmed }
        return SessionSummary(record: record).canKeep ? .improved : .rejected
    }
}
