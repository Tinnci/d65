<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/banner-dark.png">
  <img src="docs/images/banner-light.png" width="100%" alt="D65: White-point balance for external displays, measured with an iPhone. The ring-and-dot mark sits on an arc of the Planckian locus that runs from cool blue to warm orange across the banner.">
</picture>

<p align="center">
  <a href="https://github.com/Tinnci/d65/actions/workflows/ci.yml"><img src="https://github.com/Tinnci/d65/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-555555" alt="macOS 14+">
  <img src="https://img.shields.io/badge/iOS-17%2B-555555" alt="iOS 17+">
  <img src="https://img.shields.io/badge/Swift-6-555555" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/badge/licence-MIT-555555" alt="MIT licence"></a>
</p>

D65 measures a display's white with the iPhone's ambient-light sensor, solves three per-channel
gains, and applies them through the Mac's gamma table. A quality gate refuses any correction that
doesn't measurably help. It isn't a colorimeter replacement or an ICC profiling tool: it moves
white, and says so.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/whitepoint-dark.svg">
  <img src="docs/images/whitepoint-light.svg" alt="CIE xy close-up around D65: two sessions on a HAN K27 move from ΔE00 4.18 and 4.56 to 1.69 and 1.40 in one pass, inside the ΔE00 2 ring." width="100%">
</picture>

> **Status: experimental.** The Mac app, iPhone probe and CLI share one tested engine, and the full
> flow has run on one display (a HAN K27 over USB-C). The probe's light sensor is uncalibrated, so
> the numbers show convergence against that sensor, not colorimeter accuracy. See
> [status](docs/status.md) and [experiments](docs/experiments.md).

## How it works

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/poster-dark.png">
  <img src="docs/images/poster-light.png" width="100%" alt="D65 poster. How a calibration runs: 1 Place, the phone face-down on an outline until readings hold within 3 % for 1.5 s; 2 Measure, twelve patches with black for ambient light and four greys for gamma; 3 Solve, gains = M⁻¹·D65 ÷ M⁻¹·white with a quality gate (2.5 already fine, above 5.0 or more than 20 % dimmer refused); 4 Apply and verify, the gamma table scaled by gain^(1/γ) and white re-measured, ΔE00 4.18 to 1.69 against a target of 2; 5 Keep, the menu-bar agent holds the correction and guards contrast, preset and mode. Where each part runs: iPhone probe with the ambient-light sensor, the Mac running the engine, and the external display's gamma table.">
</picture>

1. **Measure.** The Mac shows twelve full-screen patches while the phone lies face-down on an
   outline. Black gives the ambient light; four greys fit the panel's response.
2. **Solve.** The white is compared with D65 at equal luminance, using CIEDE2000 or CAM16-UCS (you
   choose; both are recorded). Gains are solved
   in linear light and raised to 1/γ for the encoded table.
3. **Verify and keep.** The correction is applied, white is measured again, and at most three
   passes run. Review shows the result on the real display; Keep hands it to a menu-bar agent that
   holds it, reapplies it when the display returns, and flags it when contrast, preset or mode
   change.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/gamma-dark.svg">
  <img src="docs/images/gamma-light.svg" alt="Relative luminance of four grey patches with a fitted gamma of 2.108 and 2.114 from two sessions, slightly above the assumed 2.2 curve." width="100%">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/primaries-dark.svg">
  <img src="docs/images/primaries-light.svg" alt="CIE xy: measured red, green and blue of the HAN K27 against the sRGB and Display P3 triangles; red and blue near sRGB, green less saturated." width="60%">
</picture>

The figures are generated from the recorded sessions by `python3 scripts/make-figures.py`.

## The Mac app

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/icon-dark.png">
  <img align="right" src="docs/images/icon-light.png" width="104" height="104" alt="D65 app icon">
</picture>

A menu-bar agent with a five-step calibration window. The icon's ring holds the white point on D65;
behind it runs the Planckian locus, cool to warm.

<table>
  <tr>
    <td valign="top" width="42%"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/app-menu-dark.png"><img src="docs/images/app-menu-light.png" alt="Menu-bar panel: the K27 row reads Corrected, ΔE00 1.7, with an on/off switch; Calibrate Display, History & Settings and Quit below." width="100%"></picture>
      <p><sub><b>Menu bar.</b> Each display shows whether its correction is held and still valid.</sub></p></td>
    <td valign="top"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/app-review-dark.png"><img src="docs/images/app-review-light.png" alt="Review step: White is within tolerance, ΔE00 4.2 to 1.7, a chromaticity plot around D65, and Discard / Keep Correction buttons." width="100%"></picture>
      <p><sub><b>Review.</b> The correction is already showing on the display; hold Space for the original.</sub></p></td>
  </tr>
  <tr>
    <td valign="top"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/app-place-dark.png"><img src="docs/images/app-place-light.png" alt="Place step: probe iPhone18,4, reading Y 141.9, steadiness bar at 1.0 of 1.5 s." width="100%"></picture>
      <p><sub><b>Place.</b> Measuring starts once the phone has been still for 1.5 s.</sub></p></td>
    <td valign="top"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/app-measure-dark.png"><img src="docs/images/app-measure-light.png" alt="Measure step: patch 5 of 12, blue, with the twelve patch tiles filling in." width="100%"></picture>
      <p><sub><b>Measure.</b> Twelve patches, then up to three verified passes.</sub></p></td>
  </tr>
</table>

<sub>Rendered from the app's own views with the recorded K27 session, the stored correction and live
monitor reads (`scripts/make-screenshots.sh`). Window title bars are omitted.</sub>

## The iPhone probe

The phone is the sensor. A first-run guide draws the icon's parts as line figures; during a session
the icon's mark is the status: its dot drifts along the locus while looking for the Mac and settles
on D65 once connected. While measuring, the screen goes dark so it adds no light of its own.

<table>
  <tr>
    <td valign="top" width="50%" align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/probe-guide-dark.gif"><img src="docs/images/probe-guide-light.gif" alt="First-run guide paging through five line figures: a monitor with the mark, the phone placed on the screen, twelve patch tiles lighting in turn, the mark's dot settling onto D65, and the ring held ready." width="300"></picture>
      <p><sub><b>First run.</b> Five pages, each a moving figure in the icon's line style.</sub></p></td>
    <td valign="top" width="50%" align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/probe-session-dark.gif"><img src="docs/images/probe-session-light.gif" alt="A session on the phone: Looking for your Mac with the mark's dot drifting, Connected with the dot settled, the dark placement and measuring screens, then Measured and corrected with ΔE00 counting down from 4.2 to 1.7." width="300"></picture>
      <p><sub><b>A session.</b> Connect, place, measure; the result counts down to the corrected ΔE.</sub></p></td>
  </tr>
</table>

<sub>Recorded on an iPhone Air from the app's own window by a Debug-only demo
(`-demo guide|session -record <seconds> <name>`); the session's timings are scripted and no sensor or
display is touched.</sub>

## Limits worth knowing first

- **Sideload only.** The probe reads the ambient-light sensor through private IOHID calls, so it
  can't ship on the App Store. That reader stays out of this repository (`local/`, git-ignored); a
  clean clone builds a probe that says it has no sensor, or a labelled simulation in the Simulator.
- **One panel so far.** Behaviour on other monitors, connections and HDR is unknown. A
  [monitor report](.github/ISSUE_TEMPLATE/monitor-report.md) helps most.
- **Software correction.** The gamma table only applies while D65 runs, and macOS reverts it when
  D65 quits. Hardware gain over DDC/CI is ignored by the test panel.
- **White only.** A diagonal gain can't fix gamut or tone response.

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
swift run d65 observers       # D65 targets for CIE 1931 2°, CIE 2015 2° and 10°
swift run d65 gains 0.94 1.00 1.05
swift run d65 display list                                   # find --display-id
swift run d65 display probe                                  # read-only
swift run d65 display apply --r 0.97 --g 0.95 --b 1.0 --hold 10
swift run d65 display reset
swift run d65 serve            # advertise _d65._tcp, solve gains from a probe
swift run d65 serve --apply --metric cam16-ucs   # score the white in CAM16-UCS instead of CIEDE2000
swift run d65 error 0.3097 0.3218                # a white's distance from D65 in both metrics
swift run d65 target primaries.csv               # the white each observer sees as D65 on this display
swift run d65 ddc probe        # read monitor controls over DDC/CI, with timings
swift run d65 ddc capabilities # the monitor's MCCS capabilities string, parsed
```

`--hold` matters: macOS restores the gamma table as soon as the process that set it exits, so an
un-held `apply` is effectively a no-op. Calibration sessions restore their starting tables when they finish. The Mac app's menu-bar
agent can separately keep and hold an accepted correction.

```
measured   x=0.3144 y=0.3344  CCT≈6382 K
gains      R=0.9721 G=0.9500 B=1.0000  (alpha 1.00)
predicted  x=0.3127 y=0.3290  CCT≈6508 K
ΔE00      3.521  (measured → corrected, relative luminance ×0.958)
```

`swift test` additionally requires a full Xcode installation, because XCTest is not shipped with
the Command Line Tools. CI runs both.

Hardware sessions: the CLI run at `b219ab6` reached normalized ΔE00 **4.56 → 1.40** and the
Mac-app run at `3da5340` **4.18 → 1.69**, each in one pass. See
[experiments §13–14](docs/experiments.md#13-first-real-session-after-the-shared-engine-and-app-changes)
and the [session runbook](docs/runbook.md).

## Documentation

| Document | Contents |
|---|---|
| [docs/runbook.md](docs/runbook.md) | build/install the real probe and reproduce a hardware session |
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
scripts/                 icon and README-figure generators, revision stamp
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
- **D65Probe** is the iPhone side, speaking protocol v4. The tracked app contains no private sensor
  code: in the iOS Simulator it uses a clearly labelled simulated sensor, and on a device it uses the
  private ALS reader only when `local/probe-sensor/` exists; `project.yml` lists that directory, so a clean
  clone still builds.
  Without it the app says that no sensor is available. Optional **Use TrueDepth alignment** gives
  advisory distance/tilt before contact, visible on the Mac too. Colour sampling waits for the depth
  camera to stop; unsupported/denied capture falls back to the outline. See the
  [alignment notes](docs/truedepth-alignment.md). Its [haptic cues](docs/probe-haptics.md) cover
  connection, alignment milestones, the start of measuring and outcomes, with Subtle/Clear/Off controls
  and a sampling guard around vibration.

Both apps' icons, accent colour and the probe's launch colour are generated by
`swift scripts/make-icons.swift`, which rewrites only those sets in each `Assets.xcassets`.
README figures come from `python3 scripts/make-figures.py`, the poster from
`swift scripts/make-poster.swift`, and app screenshots from
`scripts/make-screenshots.sh` (a Debug-only showcase mode that never writes a gamma table). The
probe GIFs are recorded on a connected phone by the Debug build's `-demo … -record …` arguments and
copied out of its Documents folder with `xcrun devicectl device copy from`.

## Releasing

Versions come from git tags; nothing in the repository holds a version number. The build stamps
each app with the latest `v*` tag (`0.2.0`), the commit count as its build number, and the exact
revision (`scripts/version.sh`). To release:

```sh
git tag -a v0.2.0-alpha.2 -m "D65 0.2.0-alpha.2"
git push origin v0.2.0-alpha.2
```

The [release workflow](.github/workflows/release.yml) runs the tests, builds the Mac app and the
arm64 CLI with `scripts/package-release.sh`, and publishes a GitHub release with checksums. Tags
with a suffix (`-alpha.N`, `-beta.N`, `-rc.N`) become pre-releases. CI builds are signed ad hoc and
not notarized; run the same script locally with `D65_TEAM_ID` set to sign for your own team.

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
- [x] End-to-end session over `D65Link` (Bonjour, protocol v4 with placement and optional depth alignment)
- [x] Correction store keyed by display identity and mode, with the monitor settings it was measured at
- [ ] Golden-dataset validation against a real colorimeter

## Licence

Source code: MIT. See [LICENSE](LICENSE). Bundled CIE datasets are CC BY-SA 4.0;
see their [attribution and license notice](Sources/D65Core/Resources/CIE/README.md). The DDC/CI transport is ported from MonitorControl (MIT); see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
