import D65Core
import D65Display
import Foundation

@MainActor
final class CalibrationViewModel: ObservableObject {
    @Published var status: String = "Idle"
    @Published var gains: RGBGains = .identity
    @Published var lastDeltaE: Double?

    /// Placeholder until the macOS output adapter lands.
    private let output: any DisplayOutput = NullDisplayOutput()

    func applyDemoCorrection() {
        // A deliberately warm white, used to exercise the solver without a probe.
        let measured = Chromaticity(x: 0.3320, y: 0.3470).xyz(luminance: 200)
        let solved = WhitePointSolver.gains(measuredWhite: measured)
        let corrected = WhitePointSolver.predictedWhite(after: solved, measuredWhite: measured)

        gains = solved
        lastDeltaE = ColorDifference.deltaE00(measured, corrected)
        status = "Demo correction applied to a simulated measurement"

        do {
            try output.apply(solved)
        } catch {
            status = "Output rejected the correction: \(error.localizedDescription)"
        }
    }

    func reset() {
        gains = .identity
        lastDeltaE = nil
        status = "Reset"
        try? output.reset()
    }
}
