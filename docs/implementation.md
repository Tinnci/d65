# Implementation

See [architecture.md](architecture.md) for ownership, contracts, limitations and the module map.

## Entry points

`D65Calibration.CalibrationEngine.run` is the reusable workflow. Callers supply a configuration,
selected display, probe, patch presenter, clock, recorder, and software revision. It returns a
structured `ExperimentRecord` after cleanup; an attempt to overlap runs or a record-storage failure
throws to the caller. Measurement/hardware failures and cancellation are recorded as outcomes.

The engine reports `CalibrationProgress` through `onProgress`, records a structured `failure` and
`failedPhase`, and throws `RecordSaveError` (carrying the restored record) when a record cannot be
written.

`D65MacRuntime.CalibrationService` hosts protocol v3 over Bonjour `_d65._tcp` and emits typed
`SessionEvent`s. One probe connection is kept across sessions; the engine runs only when the client
calls `run(configuration:displayID:)`, normally after `beginPlacement` reports `.settled`. The patch
overlay takes key focus: Esc cancels (the engine restores), Space asks to start now. `d65 serve` and
`Apps/D65Mac/SessionModel` both drive it.

Keeping a result is separate from the engine, which always restores. `D65Calibration.CorrectionHold`
previews, holds, pauses and releases one display's correction over a `TransferTableBackend`;
`CorrectionStore` persists kept corrections (`Application Support/D65/Corrections.json`, schema 1)
per display identity and mode, with the contrast/preset snapshot used by `staleReason`.
`SessionSummary` turns a record into the user-facing verdict and decides whether it can be kept.

White error has two metrics (`WhiteErrorMetric`): CIEDE2000 at Y = 1 (the default) and CAM16-UCS
ΔE' (`CAM16`, checked against the published CAM16 example to 10⁻⁶) for a viewer adapted to D65,
at 64 cd/m² with a 20 % background and average surround. `CalibrationConfiguration.metric` picks the
one the gate, target and stopping rule use; every record also carries `metricReports` with the
baseline and best white in both. Each measurement records its `Observer`. The iPhone sensor's XYZ
is taken as CIE 1931 2°. The CIE 2015 2° and 10° observers are named, but the engine refuses them
until their colour-matching functions are added, so values from different observers are never compared.
Older records and stores decode as CIEDE2000 and CIE 1931 2°.

## CLI

```sh
swift run d65 selftest
swift run d65 gains <X> <Y> <Z> [--alpha <a>]
swift run d65 cct <x> <y>
swift run d65 verify <pre> <post> [--luminance-scale <s>]
swift run d65 display list
swift run d65 display probe [--display-id <id>]
swift run d65 display apply --r <g> --g <g> --b <g> [--alpha <a>] [--hold <seconds>] [--display-id <id>]
swift run d65 display reset
swift run d65 ddc probe [--display-id <id>]
swift run d65 ddc gain --r <n> --g <n> --b <n> [--display-id <id>]
swift run d65 ddc writable [--display-id <id>]
swift run d65 serve [--port <p>] [--display-id <id>]
```

`serve` and `ddc` default to the preferred external display, falling back to an available screen.
`display` commands default to the main display. DDC requires a unique EDID match to the selection;
use `display list` to find a screen's ID. `ddc capabilities` reads and parses the MCCS capabilities
string; `ddc probe` names each control and reports per-read timing and retries.

`serve` accepts at most one action flag:

| Flag | Action |
|---|---|
| none | measure all patches, fit gamma, save record; no correction |
| `--apply` | gated, measured correction, up to three passes, then restore |
| `--gamma-test` | fixed B=0.70 linear-light gain, measure, restore |
| `--ddc-test` | reduce hardware red gain by up to 25, measure, restore/verify |
| `--brightness-test` | brightness 100, measure, restore against measured luminance |
| `--effect-test` | test contrast 80 and VCP 0x6C=100, restoring between candidates |

Ctrl-C and SIGTERM cancel through the same cleanup path. The standalone `display apply` is temporary and
restores the captured tables after `--hold`; without a hold its effect is effectively instantaneous.
`display reset` explicitly resets global ColorSync defaults. Raw `ddc gain` is a persistent manual
write; `ddc writable` probes readback only and cannot establish optical effectiveness. Use the
sensor-backed effect tests for that distinction.

## Sampling and protocol

A session shows black, white, red, green, blue, yellow, cyan, magenta, and 20/40/60/80% grey patches.
Each window defaults to 0.5 seconds settling plus 2 seconds sampling, with at least three accepted
readings. The black mean is subtracted from emitted patches. The gamma fit uses a log-domain slope
with at least three usable greys and bounds 1.6…2.8; otherwise gamma remains 2.2.

Wire frames remain 4-byte big-endian length plus JSON, bounded to 1 MiB. Version 3 keeps the v2
messages below and adds a placement handshake: the Mac sends `placementRequest`/`placementEnd`,
the probe streams `previewSample(sessionID:sample:stable:)` with its motion-gate flag, and
`PlacementMonitor` decides when 1.5 s of steady readings have passed. Refusals are sent to the phone
as `failure` with a `LinkFailure` code (`busy`, `incompatible`) before the connection closes.
Version 2 introduced:

```swift
case helloV2(deviceModel: String, build: String, protocolVersion: Int)
case measurementRequest(MeasurementRequest)
case taggedSample(sessionID: UUID, patchID: UUID, sample: MeasurementSample)
case measurementEnd(sessionID: UUID, patchID: UUID)
case sessionEnded(sessionID: UUID)
```

The legacy handshake is rejected with a rebuild diagnostic. Legacy messages remain decodable for
historical data/tests; they do not feed a new session. Only the leased connection's correctly tagged
samples enter the current request. The phone dims through the full session and restores its screen
brightness on completion, failure, explicit stop or disconnect.

The ignored experiment project compiles the shared client from `Apps/D65Probe/LinkClient.swift`,
so it speaks v3 after a rebuild. `D65Probe` finds a sensor through `SensorRegistry`: the class
`D65LocalSensorFactory` (compiled from `local/probe-sensor/` when that directory exists), else a
labelled simulated sensor in the iOS Simulator, else none.

## Output and records

`TransferTableTransaction` owns gamma-table capture, cumulative application and exact restoration.
`SelectedDisplay` adds mode checks and EDID-matched DDC access. DDC reply parsing validates transport
success, checksum, reply opcode, control code and result status. Failed I2C reads return failure even
if sending the request succeeded.

DDC is split in two. `DDCDisplay` (no IOKit) is the protocol over an injected `DDCTransport`: Get/Set
VCP, the chunked capabilities request (0xF3, tried with the spec checksum, then the ported Get quirk),
`DDCStatistics`, and a lock that serializes every exchange on an endpoint with at least 50 ms between
exchanges. `DDCRegistry` maps displays to endpoints by EDID vendor/product/serial, refusing ambiguous
matches. It caches matches until CoreGraphics reports a reconfiguration, a cached endpoint fails three
times in a row, or a "no endpoint" result is 10 s old, and it keeps one `DDCDisplay` per I/O registry
entry so all users share that endpoint's lock. `MCCS` holds VCP names, preset values, the codes
never written automatically, and the guarded settings (contrast, preset, display mode).

The settings guard is three-state. `StoredCorrection.check` compares the mode and the guarded
settings recorded at calibration with a `MonitorReading` and answers `unchanged`, `changed`,
`unverified` (endpoint unreachable or a recorded setting unreadable), or `unguarded` (nothing was
readable at calibration). The agent polls every 30 s, skips sleeping displays and running sessions,
refreshes EDID matches on wake and waits 5 s before polling again.

Each session saves schema-v1 JSON in `local/experiments/<session UUID>.json` (CLI), or the app's
Application Support directory. White-point ΔE00 in new records uses Y=1 normalization; historical
records used the sensor's absolute Y. Dates use fractional Unix seconds, and nonfinite diagnostic
values use explicit `NaN`/`+Infinity`/`-Infinity` strings (read with `ExperimentRecord.decode`). Measurement statistics and raw tagged attempts are preserved
so the evidence is available beyond the printed summary.

## Build and checks

```sh
swift build
swift run d65 selftest
swift test
xcodegen generate
xcodebuild -project D65.xcodeproj -scheme D65Mac CODE_SIGNING_ALLOWED=NO build
xcodebuild -project D65.xcodeproj -scheme D65Probe -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The app build stamps `git describe --always --dirty` into `D65SoftwareRevision` using
`scripts/stamp-revision.sh`. Core/measurement/session code uses Swift 6. Platform host and CLI remain
in Swift 5 language mode with explicit main-actor isolation at workflow boundaries.

Tests cover colour reference pairs, effective-gain resolution, framing including v3, measurement
window filtering, transactional gamma tables, engine outcomes/cleanup, DDC failures, connection
isolation, measured brightness restoration and atomic record round trips. They do not substitute
for a physical reference-colorimeter run.

## Hardware validation

The CLI plus physical D65 Probe were exercised at `b219ab6` on 2026-10-25: normalized ΔE00
4.56 → 1.40 in one pass, fitted gamma 2.114, and no reported restoration errors. The run included
protocol-v3 placement, twelve patches, a correction and verification, record saving, and table
restoration. It did not exercise GUI persistence or reference-colorimeter accuracy. Full numbers
are in [experiment §13](experiments.md#13-first-real-session-after-the-shared-engine-and-app-changes);
[runbook.md](runbook.md) documents how to reproduce the session.
