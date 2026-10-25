# Implementation

## Modules

```
D65Core        colour maths, no I/O
D65Measurement samples and normalisation
D65Link        wire protocol and framing
D65Display     output adapters (gamma table, DDC)
d65            CLI
```

Dependencies point upward only: `D65Link → D65Core, D65Measurement`, `D65Display → D65Core`.
Nothing in the libraries imports the CLI or the apps.

### D65Core

| Type | Purpose |
|---|---|
| `XYZ`, `Chromaticity` | tristimulus and xy; xyY conversion; McCamy CCT |
| `Lab`, `ColorDifference.deltaE00` | CIEDE2000, validated against Sharma's reference pairs |
| `Matrix3x3`, `DisplayPrimaries` | RGB↔XYZ derived from primaries (sRGB, Display P3) |
| `WhitePointSolver` | measured white → per-channel gains; predicted white after gains |
| `RGBGains` | three gains + blend alpha; `blended`, `attenuated`, `diagonalMatrix`, `luminanceScale` |
| `QualityGate` | accept/reject thresholds: 2.5 pre, 5.0 post, 20 % luminance loss |
| `GammaTable` | scale a transfer table; `scaledLinear` compensates display gamma (`gain^(1/γ)`) |

The solver works in linear RGB: `gains = (M⁻¹·target) / (M⁻¹·measured)`, then attenuates so the
brightest channel is 1. Solving in XYZ instead would be subtly wrong for wide-gamut primaries.

### D65Measurement

`MeasurementSample` (XYZ, lux, channels, reported CCT, timestamp, device) and
`MeasurementNormalizer` (lux plausibility plus a median-centred robust mean).

### D65Link

`CalibrationMessage` is the whole protocol as a `Codable` enum:

```swift
case hello(deviceModel:build:)
case sensorCalibration(channels:wavelengths:)
case ready(options:)
case sample(MeasurementSample)
case phasedSample(phase:sample:)      // sample tagged with the patch on screen
case progress(phase:fraction:)
case result(gains:preDeltaE:postDeltaE:verdict:)
case failure(code:message:)
```

Framing is a 4-byte big-endian length followed by JSON; `MessageFraming.drain` consumes complete
frames and leaves partial tails. Dates use `secondsSince1970` so round-trips are exact.

### D65Display

- `DisplayOutput` — `apply(gains)`, `reset()`.
- `DisplayModeKey` — resolution, refresh, dynamic range, chroma; stable persistence key.
- `MacDisplayOutput` — scales the display's gamma table via `CGSetDisplayTransferByTable`,
  restores with `CGDisplayRestoreColorSyncSettings`.
- `DDCDisplay` — DDC/CI over `IOAVService`, ported from MonitorControl's Arm64DDC (MIT).

## CLI reference

```
d65 selftest                         built-in checks (13 assertions, no XCTest needed)
d65 gains <X> <Y> <Z>                solve gains for a measured white
d65 cct <x> <y>                      CCT of a chromaticity
d65 verify <pre> <post>              run the quality gate
d65 display probe                    read the gamma table (no changes)
d65 display apply --r --g --b [--hold N]
d65 display reset                    restore ColorSync settings
d65 ddc probe                        read luminance, contrast, RGB gain, input
d65 ddc gain --r --g --b             write gains and verify the read-back
d65 ddc writable                     one-step write probe: is this panel writable?
d65 serve [--port] [--apply] [--ddc-test] [--gamma-test]
```

`serve` flags: `--apply` applies a solved correction; `--ddc-test` writes a -25 red gain and
re-measures; `--gamma-test` applies a fixed B=0.70 gain and re-measures; `--brightness-test` writes
brightness 100, re-measures white, restores the previous value and re-measures again.

## Calibration session

`d65 serve` advertises `_d65._tcp`. On `hello` it runs one session:

1. Twelve patches, 2 s each: black, white, red, green, blue, yellow, cyan, magenta, then grey
   20/40/60/80 %. The greys are used to fit the panel gamma (`Y/Y_white = level^γ`) before any
   correction is computed. The probe is
   told which patch is live via `progress`, and only samples during those windows.
2. Ambient is subtracted from every patch using the black reading.
3. White → gains → predicted ΔE00 → quality gate.
4. If the full correction is rejected, alpha steps down from 1.0 in 0.05 increments until the gate
   passes (largest usable blend).
5. If applied, the white patch is re-measured **in the same session**, so the phone cannot move
   between the before and after readings. The residual is solved and applied again, up to three
   passes, stopping at ΔE00 ≤ 2 or when a pass stops improving. The best pass is reported, and the
   gamma table is restored at the end.

The full-screen patch window is AppKit at `.screenSaver` level, created lazily on the main thread.

## Probe (not in this repository)

`local/als-probe` is a sideloaded SwiftUI app. It creates an IOHID monitor client, reads the ALS
event, gates on CoreMotion stability, and streams `phasedSample` messages over Bonjour. It holds no
colour maths. See [research/als-iohid.md](research/als-iohid.md).

## Tests

- 13 XCTest cases across `D65CoreTests` and `D65LinkTests`.
- `d65 selftest` re-checks the same invariants without XCTest, so the maths can be verified with
  only the Command Line Tools installed.
- CI runs `swift build`, `swift run d65 selftest` and `swift test` on `macos-15`.
