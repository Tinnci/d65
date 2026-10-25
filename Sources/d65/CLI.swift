import AppKit
import D65Core
import D65Display
import D65Link
import D65Calibration
import D65MacRuntime
import Foundation

@main
struct D65CLI {
    @MainActor static func main() {
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

              d65 display list
                  List display IDs for --display-id.

              d65 display probe [--display-id <id>]
                  Read the current gamma table of the selected display (no changes).

              d65 display apply --r <g> --g <g> --b <g> [--alpha <a>]
                  Scale the selected display's gamma table by the given gains.

              d65 display reset
                  Restore the system ColorSync display settings.

              d65 serve [--port <p>] [--display-id <id>] [--apply]
                  Advertise _d65._tcp and solve gains from probe measurements.

              d65 ddc probe [--display-id <id>]
                  Read the guarded settings, gains, input, display mode and MCCS version, with timings.

              d65 ddc capabilities [--display-id <id>]
                  Read and parse the monitor's MCCS capabilities string.

              d65 ddc gain --r <n> --g <n> --b <n>
                  Write RGB gain (VCP 0x16/0x18/0x1A) and verify the read-back.
            """
        )
    }

    static func selectedDisplayID(_ options: [String: Double]) -> UInt32 {
        guard let id = options["display-id"] else { return CGMainDisplayID() }
        guard id.isFinite, id.rounded() == id, id >= 0, id <= Double(UInt32.max) else { fail("invalid display ID") }
        return UInt32(id)
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
        print(String(format: "gains      R=%.4f G=%.4f B=%.4f  (alpha %.2f)", gains.r, gains.g, gains.b, alpha))
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

    @MainActor static func runDisplay(_ arguments: [String]) {
        #if os(macOS)
        guard let subcommand = arguments.first else {
            fail("display expects probe, apply or reset")
        }
        let options = parseOptions(arguments)
        let output = MacDisplayOutput(displayID: selectedDisplayID(options))

        switch subcommand {
        case "list":
            for screen in NSScreen.screens {
                let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                print("\(id)  \(screen.localizedName)\(id == CGMainDisplayID() ? " (main)" : "")")
            }
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
            let gains = CorrectionRequest(gains: RGBGains(r: r, g: g, b: b), alpha: options["alpha"] ?? 1).resolved()
            let transaction = TransferTableTransaction(backend: output)
            do {
                try transaction.begin()
                try transaction.setCumulativeGains(gains, gamma: output.gamma)
                print(String(format: "applied  R=%.4f  G=%.4f  B=%.4f", gains.r, gains.g, gains.b))

                let hold = options["hold"] ?? 0
                if hold > 0 {
                    print(String(format: "holding for %.1fs — macOS reverts the table when this process exits", hold))
                    Thread.sleep(forTimeInterval: hold)
                    try transaction.restore()
                    print("restored captured display tables")
                } else {
                    print("note: macOS restores the table as soon as this process exits; use --hold to keep it")
                }
                try transaction.restore()
            } catch {
                do { try transaction.restore() }
                catch { fail("display restoration failed: \(error)") }
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

    @MainActor static func runServe(_ arguments: [String]) {
        #if os(macOS)
        setvbuf(stdout, nil, _IOLBF, 0)
        let options = parseOptions(arguments)
        let requestedPort = options["port"] ?? 50515
        guard requestedPort.isFinite, requestedPort.rounded() == requestedPort,
              requestedPort >= 1, requestedPort <= 65535 else { fail("port must be 1...65535") }
        if let id = options["display-id"], (!id.isFinite || id.rounded() != id || id < 0 || id > Double(UInt32.max)) {
            fail("invalid display ID")
        }
        let port = UInt16(requestedPort)
        let apply = arguments.contains("--apply")

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        do {
            let flags: [(String, CalibrationMode)] = [("--apply", .calibrate), ("--ddc-test", .ddcTest),
                ("--gamma-test", .gammaTest), ("--brightness-test", .brightnessTest), ("--effect-test", .effectTest)]
            let selected = flags.filter { arguments.contains($0.0) }
            guard selected.count <= 1 else { fail("choose only one calibration/test mode") }
            let config = CalibrationConfiguration(mode: selected.first?.1 ?? .measureOnly)
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("local/experiments", isDirectory: true)
            let revisionProcess = Process()
            revisionProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            revisionProcess.arguments = ["describe", "--always", "--dirty"]
            let revisionOutput = Pipe()
            revisionProcess.standardOutput = revisionOutput
            revisionProcess.standardError = FileHandle.nullDevice
            try revisionProcess.run()
            revisionProcess.waitUntilExit()
            let revision = String(data: revisionOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            let server = try CalibrationService(port: port, recordDirectory: directory,
                softwareRevision: revision.isEmpty ? "unknown" : revision)
            let displayID = options["display-id"].map { UInt32($0) }
                ?? DisplayDirectory.preferred(in: DisplayDirectory.online())?.id ?? CGMainDisplayID()
            var lastPlacement: PlacementState?
            server.onEvent = { event in
                switch event {
                case .listening: print("advertising _d65._tcp; target display \(displayID); waiting for a protocol-v\(Link.protocolVersion) probe")
                case .listenerFailed(let text), .probeRejected(let text), .runFailed(let text): print(text)
                case .probeConnected(let identity):
                    print("probe \(identity.model) (\(identity.build)) connected — place it on the outline")
                    server.beginPlacement(displayID: displayID)
                case .probeDisconnected: print("probe disconnected")
                case .placement(let reading):
                    if reading.state != lastPlacement { print("placement: \(reading.state.rawValue)"); lastPlacement = reading.state }
                    if reading.state == .settled { server.run(configuration: config, displayID: displayID) }
                case .startRequested:
                    if server.isPlacing { server.run(configuration: config, displayID: displayID) }
                case .cancelRequested: print("cancelled from the overlay")
                case .progress(let progress):
                    if case .patch(let index, let count, let patch) = progress { print("  \(index + 1)/\(count) \(patch.name)") }
                case .finished(let record, let saveError):
                    print(record.consoleSummary)
                    if let saveError { print("RECORD NOT SAVED: \(saveError)") }
                    else { print("record: \(directory.appendingPathComponent(record.id.uuidString + ".json").path)") }
                    print("reconnect the probe to run another session")
                }
            }
            server.start()
            print("apply to display: \(apply ? "yes" : "no")")
            // Handle Ctrl-C through the same async restoration path as cancellation.
            let terminationSignals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { Task { @MainActor in await server.stop(); exit(0) } }
                source.resume()
                return source
            }
            defer { terminationSignals.forEach { $0.cancel() } }
            RunLoop.main.run()
        } catch {
            fail("serve failed: \(error)")
        }
        #else
        fail("serve is macOS only")
        #endif
    }

    @MainActor static func runDDC(_ arguments: [String]) {
        #if os(macOS)
        guard let subcommand = arguments.first else {
            fail("ddc expects probe, capabilities, gain or writable")
        }
        let selection = parseOptions(arguments)
        // DDC only exists on external displays, so default to the first external one rather than the main display.
        let displayID = selection["display-id"] != nil ? selectedDisplayID(selection)
            : DisplayDirectory.preferred(in: DisplayDirectory.online())?.id ?? CGMainDisplayID()
        guard let display = DDCDisplay.matching(displayID: displayID) else {
            fail("no unique DDC endpoint for the selected display; use display list and --display-id")
        }

        func describe(_ vcp: UInt8) -> String {
            let label = String(format: "0x%02X %@", vcp, MCCS.name(of: vcp)).padding(toLength: 34, withPad: " ", startingAt: 0)
            guard let value = display.read(vcp) else { return label + "no reply" }
            let time = String(format: "%4.0f ms", display.statistics.lastDuration * 1000)
            let preset = vcp == MCCS.colorPreset ? MCCS.presetName(value.current).map { "  (\($0))" } ?? "" : ""
            return label + String(format: "%5d / %-5d  ", value.current, value.maximum) + time + preset
        }
        func summary() -> String {
            let stats = display.statistics
            return String(format: "%d exchanges, %d retries, %d failed, longest %.0f ms",
                          stats.exchanges, stats.retries, stats.failures, stats.longestDuration * 1000)
        }

        switch subcommand {
        case "probe":
            for vcp in [MCCS.luminance, MCCS.contrast, MCCS.colorPreset, DDCDisplay.redGain, DDCDisplay.greenGain,
                        DDCDisplay.blueGain, MCCS.inputSource, MCCS.displayMode, MCCS.vcpVersion] {
                print(describe(vcp))
            }
            print(summary())

        case "capabilities":
            guard let raw = display.readCapabilitiesString() else {
                print("no capabilities string (the monitor did not answer, or answered invalid chunks)")
                print(summary())
                return
            }
            print("raw: \(raw)")
            guard let capabilities = MCCSCapabilities(raw) else { print("could not parse the string"); return }
            print("model \(capabilities.model ?? "?")  type \(capabilities.type ?? "?")  MCCS \(capabilities.mccsVersion ?? "?")")
            for code in capabilities.vcp.keys.sorted() {
                let values = capabilities.values(for: code).map { list in
                    "  values " + list.map { value in
                        code == MCCS.colorPreset ? (MCCS.presetName(value).map { String(format: "%02X=%@", value, $0) } ?? String(format: "%02X", value))
                            : String(format: "%02X", value)
                    }.joined(separator: " ")
                } ?? ""
                let caution = MCCS.disruptive.contains(code) ? "  [never written automatically]" : ""
                print(String(format: "  0x%02X %@", code, MCCS.name(of: code)) + values + caution)
            }
            print(summary())

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
