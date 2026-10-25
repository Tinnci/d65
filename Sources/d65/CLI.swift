import AppKit
import D65Core
import D65Display
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
        case "display":
            runDisplay(arguments)
        case "serve":
            runServe(arguments)
        case "ddc":
            runDDC(arguments)
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

              d65 display probe
                  Read the current gamma table of the main display (no changes).

              d65 display apply --r <g> --g <g> --b <g> [--alpha <a>]
                  Scale the main display's gamma table by the given gains.

              d65 display reset
                  Restore the system ColorSync display settings.

              d65 serve [--port <p>] [--apply]
                  Advertise _d65._tcp and solve gains from probe measurements.

              d65 ddc probe
                  Read brightness, contrast, RGB gain and input over DDC/CI.

              d65 ddc gain --r <n> --g <n> --b <n>
                  Write RGB gain (VCP 0x16/0x18/0x1A) and verify the read-back.
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

    static func runDisplay(_ arguments: [String]) {
        #if os(macOS)
        guard let subcommand = arguments.first else {
            fail("display expects probe, apply or reset")
        }
        let options = parseOptions(arguments)
        let output = MacDisplayOutput()

        switch subcommand {
        case "probe":
            do {
                let snapshot = try output.probe()
                print("display \(snapshot.displayID)  table entries=\(snapshot.count)")
                let indices: [Int] = [0, snapshot.count / 4, snapshot.count / 2, 3 * snapshot.count / 4, snapshot.count - 1]
                func formatted(_ name: String, _ table: [Double]) -> String {
                    let values = indices.map { String(format: "%.4f", table[$0]) }
                    return "  " + name + ": " + values.joined(separator: "  ")
                }
                print(formatted("R", snapshot.red))
                print(formatted("G", snapshot.green))
                print(formatted("B", snapshot.blue))
                print("  (positions: 0, 25%, 50%, 75%, 100%)")
            } catch {
                fail("probe failed: \(error)")
            }

        case "apply":
            guard let r = options["r"], let g = options["g"], let b = options["b"] else {
                fail("apply needs --r, --g and --b")
            }
            let gains = RGBGains(r: r, g: g, b: b, alpha: options["alpha"] ?? 1).blended()
            do {
                try output.apply(gains)
                print(String(format: "applied  R=%.4f  G=%.4f  B=%.4f", gains.r, gains.g, gains.b))

                let hold = options["hold"] ?? 0
                if hold > 0 {
                    print(String(format: "holding for %.1fs — macOS reverts the table when this process exits", hold))
                    Thread.sleep(forTimeInterval: hold)
                    try output.reset()
                    print("restored ColorSync display settings")
                } else {
                    print("note: macOS restores the table as soon as this process exits; use --hold to keep it")
                }
            } catch {
                fail("apply failed: \(error)")
            }

        case "reset":
            do {
                try output.reset()
                print("restored ColorSync display settings")
            } catch {
                fail("reset failed: \(error)")
            }

        default:
            fail("unknown display subcommand: \(subcommand)")
        }
        #else
        fail("display commands are macOS only")
        #endif
    }

    static func runServe(_ arguments: [String]) {
        #if os(macOS)
        setvbuf(stdout, nil, _IOLBF, 0)
        let options = parseOptions(arguments)
        let port = UInt16(options["port"] ?? 50515)
        let apply = arguments.contains("--apply")

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        do {
            let server = try CalibrationServer(
                port: port,
                applyToDisplay: apply,
                ddcTest: arguments.contains("--ddc-test"),
                gammaTest: arguments.contains("--gamma-test"),
                brightnessTest: arguments.contains("--brightness-test"),
                effectTest: arguments.contains("--effect-test")
            )
            server.start()
            print("apply to display: \(apply ? "yes" : "no (use --apply)")")
            print("press Ctrl-C to stop")
            RunLoop.main.run()
        } catch {
            fail("serve failed: \(error)")
        }
        #else
        fail("serve is macOS only")
        #endif
    }

    static func runDDC(_ arguments: [String]) {
        #if os(macOS)
        guard let subcommand = arguments.first else {
            fail("ddc expects probe, gain or writable")
        }
        guard let display = DDCDisplay.external() else {
            fail("no external display with a DCPAVServiceProxy found")
        }

        func describe(_ name: String, _ vcp: UInt8) -> String {
            guard let value = display.read(vcp) else { return name + ": no reply" }
            return String(format: "%@: %d / %d", name, value.current, value.maximum)
        }

        switch subcommand {
        case "probe":
            print(describe("luminance ", DDCDisplay.luminance))
            print(describe("contrast  ", DDCDisplay.contrast))
            print(describe("red gain  ", DDCDisplay.redGain))
            print(describe("green gain", DDCDisplay.greenGain))
            print(describe("blue gain ", DDCDisplay.blueGain))
            print(describe("input     ", DDCDisplay.inputSource))

        case "writable":
            guard let original = display.read(DDCDisplay.redGain)?.current else {
                fail("could not read red gain")
            }
            let probeValue = original > 0 ? original - 1 : original + 1
            _ = display.write(DDCDisplay.redGain, value: probeValue)
            usleep(300_000)
            let after = display.read(DDCDisplay.redGain)?.current
            _ = display.write(DDCDisplay.redGain, value: original)
            usleep(200_000)
            let restored = display.read(DDCDisplay.redGain)?.current
            if after == probeValue {
                print("writable: red \(original) -> \(probeValue) accepted, restored to \(restored.map(String.init) ?? "?")")
            } else {
                print("read-only: wrote \(probeValue), read back \(after.map(String.init) ?? "nil"); value ignored by the monitor")
            }

        case "gain":
            let options = parseOptions(arguments)
            let channels: [(String, UInt8, Double?)] = [
                ("red", DDCDisplay.redGain, options["r"]),
                ("green", DDCDisplay.greenGain, options["g"]),
                ("blue", DDCDisplay.blueGain, options["b"]),
            ]
            for (name, vcp, requested) in channels {
                guard let requested else { continue }
                let value = UInt16(max(0, min(100, requested.rounded())))
                let before = display.read(vcp)?.current
                let acknowledged = display.write(vcp, value: value)
                usleep(250_000)
                let after = display.read(vcp)?.current
                let beforeText = before.map(String.init) ?? "nil"
                let afterText = after.map(String.init) ?? "nil"
                print("\(name) \(beforeText) -> \(value)  ack=\(acknowledged ? "yes" : "no")  readback=\(afterText)")
                if after != value {
                    print("  note: the monitor did not accept the write (common; many panels are read-only)")
                }
            }

        default:
            fail("unknown ddc subcommand: \(subcommand)")
        }
        #else
        fail("ddc commands are macOS only")
        #endif
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
