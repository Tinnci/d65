import D65Core
import D65Link
import D65Measurement
import Foundation

struct SelfTest {
    private var failures = 0

    static func runAll() -> Bool {
        var test = SelfTest()
        return test.run()
    }

    private mutating func run() -> Bool {
        check("CIEDE2000 matches Sharma reference pairs") {
            let pairs: [(Lab, Lab, Double)] = [
                (Lab(l: 50, a: 2.6772, b: -79.7751), Lab(l: 50, a: 0, b: -82.7485), 2.0425),
                (Lab(l: 50, a: 3.1571, b: -77.2803), Lab(l: 50, a: 0, b: -82.7485), 2.8615),
                (Lab(l: 50, a: 2.8361, b: -74.0200), Lab(l: 50, a: 0, b: -82.7485), 3.4412),
                (Lab(l: 50, a: -1.3802, b: -84.2814), Lab(l: 50, a: 0, b: -82.7485), 1.0000),
            ]
            return pairs.allSatisfy { lhs, rhs, expected in
                abs(ColorDifference.deltaE00(lhs, rhs) - expected) < 1e-4
            }
        }

        check("D65 is neutral in Lab") {
            let lab = Lab(xyz: Chromaticity.d65.xyz())
            return abs(lab.a) < 1e-9 && abs(lab.b) < 1e-9 && abs(lab.l - 100) < 1e-9
        }

        check("identity gains for a display already at D65") {
            let gains = WhitePointSolver.gains(measuredWhite: Chromaticity.d65.xyz())
            return gains.isIdentity
        }

        check("warm white is corrected onto D65") {
            let warm = Chromaticity(x: 0.3320, y: 0.3470).xyz(luminance: 200)
            let gains = WhitePointSolver.gains(measuredWhite: warm)
            let corrected = WhitePointSolver.predictedWhite(after: gains, measuredWhite: warm)
            guard let c = corrected.chromaticity else { return false }
            return gains.r < 1 && abs(c.x - 0.3127) < 1e-6 && abs(c.y - 0.3290) < 1e-6
        }

        check("correction never brightens and clamps to (0, 1]") {
            let measured = Chromaticity(x: 0.345, y: 0.355).xyz(luminance: 120)
            let gains = WhitePointSolver.gains(measuredWhite: measured)
            return gains.r <= 1 && gains.g <= 1 && gains.b <= 1
                && max(gains.r, gains.g, gains.b) > 0.999
        }

        check("blend moves halfway toward identity") {
            let gains = RGBGains(r: 0.8, g: 0.9, b: 1).blended(alpha: 0.5)
            return abs(gains.r - 0.9) < 1e-12 && abs(gains.g - 0.95) < 1e-12
        }

        check("diagonal matrix layout is column-major 4×4") {
            let matrix = RGBGains(r: 0.5, g: 0.75, b: 1).diagonalMatrix
            return matrix.count == 16 && matrix[0] == 0.5 && matrix[5] == 0.75 && matrix[15] == 1
        }

        check("quality gate accepts an improvement and rejects a regression") {
            let gate = QualityGate()
            return gate.verdict(preDeltaE: 15, postDeltaE: 2) == .improved
                && gate.verdict(preDeltaE: 1.2, postDeltaE: 1.0) == .confirmed
                && gate.verdict(preDeltaE: 15, postDeltaE: 2, luminanceScale: 0.7) == .rejected
        }

        check("link framing round-trips and drains partial buffers") {
            let sample = MeasurementSample(
                xyz: XYZ(x: 0.9505, y: 1, z: 1.089),
                lux: 120,
                channels: [0.4, 0.5, 0.6],
                reportedCCT: 6504,
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let messages: [CalibrationMessage] = [
                .hello(deviceModel: "iPhone15,2", build: "21A360"),
                .sample(sample),
                .result(gains: RGBGains(r: 0.92, g: 0.97, b: 1), preDeltaE: 12, postDeltaE: 2.1, verdict: .improved),
            ]
            var buffer = Data()
            for message in messages {
                buffer.append(try MessageFraming.encode(message))
            }
            let drained = try MessageFraming.drain(&buffer)
            return drained == messages && buffer.isEmpty
        }

        print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
        return failures == 0
    }

    private mutating func check(_ name: String, _ body: () throws -> Bool) {
        do {
            if try body() {
                print("  ok    \(name)")
            } else {
                failures += 1
                print("  FAIL  \(name)")
            }
        } catch {
            failures += 1
            print("  FAIL  \(name) — \(error)")
        }
    }
}
