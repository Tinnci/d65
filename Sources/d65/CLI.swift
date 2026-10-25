import D65Core
import Foundation

@main
struct D65CLI {
    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            printUsage()
            exit(0)
        }
        arguments.removeFirst()

        switch command {
        case "selftest":
            exit(SelfTest.runAll() ? 0 : 1)
        case "gains":
            runGains(arguments)
        case "cct":
            runCCT(arguments)
        case "verify":
            runVerification(arguments)
        case "-h", "--help", "help":
            printUsage()
        default:
            FileHandle.standardError.write(Data("unknown command: \(command)\n".utf8))
            printUsage()
            exit(2)
        }
    }

    static func printUsage() {
        print(
            """
            d65 — white-point gains for a display

            USAGE
              d65 selftest
                  Run the built-in checks (CIEDE2000 references, solver invariants).

              d65 gains <X> <Y> <Z> [--target-x <x>] [--target-y <y>] [--alpha <a>]
                  Per-channel gains that move a measured white to the target
                  chromaticity (D65 by default).

              d65 cct <x> <y>
                  Correlated colour temperature of a chromaticity.

              d65 verify <preDeltaE> <postDeltaE> [--luminance-scale <s>]
                  Apply the quality gate and print the verdict.
            """
        )
    }

    // MARK: - Commands

    static func runGains(_ arguments: [String]) {
        guard let values = parseDoubles(arguments, expected: 3) else {
            fail("gains expects three numbers: X Y Z")
        }
        let options = parseOptions(arguments)
        let target = Chromaticity(
            x: options["target-x"] ?? Chromaticity.d65.x,
            y: options["target-y"] ?? Chromaticity.d65.y
        )
        let alpha = options["alpha"] ?? 1

        let measured = XYZ(x: values[0], y: values[1], z: values[2])
        let gains = WhitePointSolver.gains(measuredWhite: measured, target: target).blended(alpha: alpha)
        let predicted = WhitePointSolver.predictedWhite(after: gains, measuredWhite: measured)

        print(String(format: "measured   x=%.4f y=%.4f  CCT≈%.0f K",
                     measured.chromaticity?.x ?? 0,
                     measured.chromaticity?.y ?? 0,
                     measured.chromaticity?.correlatedColorTemperature() ?? 0))
        print(String(format: "gains      R=%.4f G=%.4f B=%.4f  (alpha %.2f)", gains.r, gains.g, gains.b, gains.alpha))
        if let predictedChromaticity = predicted.chromaticity {
            let deltaE = ColorDifference.deltaE00(measured, predicted)
            print(String(format: "predicted  x=%.4f y=%.4f  CCT≈%.0f K",
                         predictedChromaticity.x,
                         predictedChromaticity.y,
                         predictedChromaticity.correlatedColorTemperature()))
            print(String(format: "ΔE00      %.3f  (measured → corrected, relative luminance ×%.3f)",
                         deltaE, gains.luminanceScale))
        }
    }

    static func runCCT(_ arguments: [String]) {
        guard let values = parseDoubles(arguments, expected: 2) else {
            fail("cct expects two numbers: x y")
        }
        let chromaticity = Chromaticity(x: values[0], y: values[1])
        print(String(format: "%.0f K", chromaticity.correlatedColorTemperature()))
    }

    static func runVerification(_ arguments: [String]) {
        guard let values = parseDoubles(arguments, expected: 2) else {
            fail("verify expects two numbers: preDeltaE postDeltaE")
        }
        let options = parseOptions(arguments)
        let gate = QualityGate()
        let verdict = gate.verdict(
            preDeltaE: values[0],
            postDeltaE: values[1],
            luminanceScale: options["luminance-scale"] ?? 1
        )
        print(verdict.rawValue)
    }

    // MARK: - Parsing

    static func parseDoubles(_ arguments: [String], expected: Int) -> [Double]? {
        let positional = arguments.prefix { !$0.hasPrefix("--") }
        guard positional.count == expected else { return nil }
        let values = positional.compactMap(Double.init)
        return values.count == expected ? values : nil
    }

    static func parseOptions(_ arguments: [String]) -> [String: Double] {
        var options: [String: Double] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--"), index + 1 < arguments.count, let value = Double(arguments[index + 1]) {
                options[String(argument.dropFirst(2))] = value
                index += 2
            } else {
                index += 1
            }
        }
        return options
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }
}
