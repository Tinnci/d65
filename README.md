# D65

White-point balance for external displays, measured with an iPhone as a probe.

D65 is not a colourimeter replacement and not an ICC profiling tool. It does one thing: measure a
display's white, solve for three per-channel gains, and apply them — with a quality gate that
refuses corrections that do not measurably help.

> Status: **scaffold**. The colour maths, CLI and link framing work and are self-tested. The two
> app targets are shells; probe acquisition and the macOS output adapter are not implemented yet.
> See the roadmap at the bottom.

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
```

```
measured   x=0.3144 y=0.3344  CCT≈6382 K
gains      R=0.9721 G=0.9500 B=1.0000  (alpha 1.00)
predicted  x=0.3127 y=0.3290  CCT≈6508 K
ΔE00      3.521  (measured → corrected, relative luminance ×0.958)
```

`swift test` additionally requires a full Xcode installation, because XCTest is not shipped with
the Command Line Tools. CI runs both.

## Layout

```
Sources/D65Core          XYZ, Lab, CIEDE2000, primaries, white-point solver, gains, quality gate
Sources/D65Measurement   measurement model and normalisation
Sources/D65Link          wire protocol and length-prefixed framing
Sources/D65Display       display output abstraction and mode key
Sources/d65              CLI: selftest, gains, cct, verify
Apps/D65Mac              macOS app shell (SwiftUI)
Apps/D65Probe            iPhone probe shell (SwiftUI)
docs/architecture.md     module boundaries and data flow
docs/research/           what Apple's Color Balance does, and how it reads the ALS
project.yml              XcodeGen spec for the two apps
```

## Apps

The app targets are defined in `project.yml` and generated with XcodeGen:

```sh
brew install xcodegen
xcodegen generate
open D65.xcodeproj
```

They need Xcode 16 or later. Nothing in the app targets is load-bearing yet — `D65Mac` can run the
solver against a simulated measurement and print the gains; `D65Probe` is a placeholder screen.

## Design

Four libraries, one direction of dependency:

- **D65Core** — colour maths only, no I/O. This is where a bug is a maths bug.
- **D65Measurement** — samples and robust averaging.
- **D65Link** — the message enum and framing; the same file is compiled into both apps.
- **D65Display** — the only place that knows how a correction reaches a screen.

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

- [ ] macOS output adapter: render-server colour matrix, with per-display-mode persistence
- [ ] Probe acquisition: external sensor (supported) or sideloaded IOHID ALS (experimental, see docs/research/als-iohid.md)
- [ ] End-to-end session over `D65Link` (Bonjour + framing)
- [ ] Calibration store keyed by `DisplayModeKey`, with the `QualityGate` verdict recorded
- [ ] Golden-dataset validation against a real colorimeter

## Licence

MIT. See [LICENSE](LICENSE).
