# D65

White-point balance for external displays, measured with an iPhone as a probe.

D65 is not a colourimeter replacement and not an ICC profiling tool. It does one thing: measure a
display's white, solve for three per-channel gains, and apply them — with a quality gate that
refuses corrections that do not measurably help.

> Status: **experimental end-to-end workflow**. The CLI and Mac app share a tested calibration
> engine, with exact gamma-table restoration and versioned experiment records. The sideloaded ALS
> experiment supplies measurements; its absolute colour accuracy still needs reference validation.
> See [status](docs/status.md) and [architecture](docs/architecture.md).

## Why the name

A white-point correction is defined by its target. Apple's own implementation optimises toward
6504 K, which is D65 to within rounding. Naming the project after the target is honest about the
scope: this moves a display's white, and does not claim to characterise the panel.

It is also deliberately not called *Calibrate*, *Gamut* or *Spectra*. Those names would promise
work this project does not do.

## Quick start

Requires macOS 14+ and a Swift 6 toolchain. The package and CLI build with the Command Line Tools
alone:

```sh
swift build
swift run d65 selftest
swift run d65 gains 0.94 1.00 1.05
swift run d65 display list                                   # find --display-id
swift run d65 display probe                                  # read-only
swift run d65 display apply --r 0.97 --g 0.95 --b 1.0 --hold 10
swift run d65 display reset
swift run d65 serve            # advertise _d65._tcp, solve gains from a probe
swift run d65 ddc probe        # read the monitor's hardware RGB gain over DDC/CI
```

`--hold` matters: macOS restores the gamma table as soon as the process that set it exits, so an
un-held `apply` is effectively a no-op. Calibration sessions restore their starting tables when they finish. A persistent correction agent is future work.

```
measured   x=0.3144 y=0.3344  CCT≈6382 K
gains      R=0.9721 G=0.9500 B=1.0000  (alpha 1.00)
predicted  x=0.3127 y=0.3290  CCT≈6508 K
ΔE00      3.521  (measured → corrected, relative luminance ×0.958)
```

`swift test` additionally requires a full Xcode installation, because XCTest is not shipped with
the Command Line Tools. CI runs both.

## Documentation

| Document | Contents |
|---|---|
| [docs/status.md](docs/status.md) | what works, what does not, next steps |
| [docs/implementation.md](docs/implementation.md) | modules, CLI, wire protocol |
| [docs/experiments.md](docs/experiments.md) | every measurement, with numbers |
| [docs/hardware.md](docs/hardware.md) | display, DDC matrix, gamma behaviour |
| [docs/architecture.md](docs/architecture.md) | why the code is split this way |
| [docs/research/](docs/research/) | Apple's Color Balance and the ALS path |

## Layout

```
Sources/D65Core          XYZ, Lab, CIEDE2000, primaries, white-point solver, gains, quality gate
Sources/D65Measurement   measurement model and normalisation
Sources/D65Link          wire protocol and length-prefixed framing
Sources/D65Display       gamma transactions, DDC and mode keys
Sources/D65Calibration   shared session engine, measurements, structured records
Sources/D65MacRuntime    selected screen, patch presenter and Bonjour host
Sources/d65              CLI: selftest, gains, cct, verify
Apps/D65Mac              menu-bar agent and calibration session (SwiftUI)
Apps/D65Probe            iPhone probe (SwiftUI); sensor injected locally
docs/status.md           what works, what does not, next steps
docs/implementation.md   modules, CLI reference, wire protocol
docs/experiments.md      every measurement, with numbers
docs/hardware.md         display, DDC capability matrix, gamma behaviour
docs/architecture.md     module boundaries and data flow
docs/research/           Apple's Color Balance, and how the ALS is read
project.yml              XcodeGen spec for the two apps
```

## Apps

The app targets are defined in `project.yml` and generated with XcodeGen:

```sh
brew install xcodegen
xcodegen generate
open D65.xcodeproj
```

They need Xcode 16 or later.

- **D65Mac** is a menu-bar agent. It holds each display's kept correction while it runs, reapplies it
  when the display returns, and marks it stale when contrast, preset or display mode changes.
  *Calibrate Display…* opens a five-step session (Prepare, Connect, Place, Measure, Review): the
  phone is placed on a life-size outline, measuring starts when its readings settle, and Review
  previews the result on the real display before you keep or discard it. Esc always cancels, and
  quitting restores every display.
- **D65Probe** is the iPhone side, speaking protocol v3. The tracked app contains no private sensor
  code: in the iOS Simulator it uses a clearly labelled simulated sensor, and on a device it uses the
  private ALS reader only when `local/als-probe` exists, through optional sources in `project.yml`.
  Without it the app says that no sensor is available.

## Design

The maths, measurements, transport and hardware remain separate libraries:

- **D65Core** — colour maths only, no I/O. This is where a bug is a maths bug.
- **D65Measurement** — samples and robust averaging.
- **D65Link** — the message enum and framing; the same file is compiled into both apps.
- **D65Display** — transfer-table transactions and hardware transport.
- **D65Calibration** — actor-isolated session workflow and versioned experiment records.
- **D65MacRuntime** — AppKit and Bonjour adapters shared by CLI and app.

The probe is treated as a sensor, not a calibrator. It never computes gains, and the Mac never
talks to a sensor directly. More detail in [docs/architecture.md](docs/architecture.md).

### Scope boundary

A diagonal RGB gain matrix can move a white point and cannot fix a gamut or a transfer function.
That is a deliberate limit, not an oversight: the measured evidence for the feature this project
learns from shows exactly this shape of correction, and the quality gate exists to stop it making
a good display worse.

## Background

This project exists because of a static analysis of Apple's iPhone-assisted *Color Balance*: an
iPhone ambient-light sensor reads patches, the Apple TV fits a white point, and the result is
applied as per-channel gains through the render server. The full write-up — components, protocol,
ΔE00 gates, per-iPhone sensor models — is in
[docs/research/apple-color-balance.md](docs/research/apple-color-balance.md).

## Roadmap

- [x] macOS output adapter: gamma-table gains, verified apply/read-back/reset
- [x] Menu-bar agent that holds the correction across process lifetime
- [x] Per-display-mode persistence; macOS reverts on exit and the agent reapplies at launch
- [ ] Calibrate the probe's channel triple against a reference before trusting it as XYZ
- [x] DDC/CI read path for monitor hardware gains (writes are ignored by this panel)
- [x] Sideloaded IOHID ALS acquisition experiment (absolute accuracy unvalidated; see docs/research/als-iohid.md)
- [x] End-to-end session over `D65Link` (Bonjour, protocol v3 with placement handshake)
- [x] Correction store keyed by display identity and mode, with the monitor settings it was measured at
- [ ] Golden-dataset validation against a real colorimeter

## Licence

MIT. See [LICENSE](LICENSE).
