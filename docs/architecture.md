# Architecture

D65 remains a modular monolith. The colour maths is independent of I/O; one calibration engine
owns the workflow used by the CLI and Mac app. Platform and transport adapters supply its inputs.

## Dependency boundaries

| Target | Responsibility | Dependencies |
|---|---|---|
| D65Core | XYZ/Lab/ΔE, solver, resolved gains, quality gate | Foundation |
| D65Measurement | samples, tagged measurement windows, validation and statistics | Core |
| D65Display | transfer-table transactions, mode keys, macOS gamma and DDC transport | Core |
| D65Calibration | session lifecycle, correction passes, effect tests, experiment records | Core, Measurement, Display |
| D65ProbeSupport | pure probe haptic patterns, scene timing and sampling guard | Measurement |
| D65Link | versioned messages and bounded length-prefixed JSON framing | Core, Measurement |
| D65Host | the probe service: connection lease, placement, runs, completion messages | Calibration, Link, Measurement |
| D65MacRuntime | Network.framework listener, AppKit patch window, selected display | Host, Calibration, Link, Display |
| D65WindowsRuntime | Winsock listener with DNS-SD, Win32 patch window, GDI gamma ramps, dxva2 DDC/CI | Host, Calibration, Link, Display |
| d65 / D65Mac | command/UI configuration and presentation of results | libraries above |

The probe reads the ambient-light sensor through a private IOHID monitor client, restricted by
service matching to the built-in light sensor (`Apps/D65Probe/AmbientLightSensor.swift`); in the
Simulator it uses a labelled simulated source. The original acquisition experiment stays in the
ignored `local/als-probe` directory and shares its network client from `Apps/D65Probe/LinkClient.swift`. The probe
never solves a correction.

## Desktop hosts

`D65Host.CalibrationService` is the same on every desktop platform. A platform supplies a
`ProbeListener` (TCP on 50515, advertised as `_d65._tcp`), and a `HostPlatform` that makes the
patch window (`HostOverlay`) and the `CalibrationDisplay` for a display ID. macOS uses
Network.framework, AppKit and CoreGraphics; Windows uses Winsock and `DnsServiceRegister`, a
topmost Win32 window, `SetDeviceGammaRamp` and the dxva2 monitor configuration API. One difference
matters for safety: macOS reverts gamma tables when the process exits, Windows keeps them, so the
Windows host restores on Ctrl-C and console close as well as at the end of every run.

## Session ownership

`CalibrationEngine` is main-actor isolated, with injected `CalibrationProbe`, `CalibrationDisplay`,
`PatchPresenter`, `CalibrationClock`, and `ExperimentRecorder` boundaries. No library imports AppKit
except the macOS adapters. Network callbacks enter the main actor before changing session data.

The lifecycle records `idle → measuring → applying/verifying → restoring → finished`. A run has
one cleanup path for success, rejection, cancellation, failed writes, missing samples, and errors.
Concurrent runs are rejected. Best-pass state belongs to a single run.

Outcomes distinguish measurement-only completion, an already acceptable white, convergence,
quality-gate rejection, stopped improvement, exhausted passes, cancellation, and failure. Reaching
the pass limit does not count as convergence. Sessions are temporary: their correction is restored
at the end, and the record identifies the best measured pass for review.

The network host grants one connection a lease. A second connection cannot change the active
probe, inject samples, or take over while the first session is restoring. Disconnects cancel the
engine. Malformed frames terminate the connection; idle handshakes time out.

## Correction and restoration contracts

`RGBGains` contains effective linear-light channel gains only. `CorrectionRequest` contains a
requested alpha and resolves it once. Prediction, hardware application and experiment records all
use the resolved values. Residual solves are multiplied into cumulative gains by the engine.

`TransferTableTransaction` captures the exact starting tables once. `setCumulativeGains` always
scales that baseline using `gain^(1/gamma)`; applying the same correction twice is idempotent.
Restoration writes the captured tables to that display only, preserving pre-existing curves. A
read-only session does not write gamma tables. Failed writes are considered potentially partial
and still trigger restoration. A failed restoration remains visible and can be retried.

The low-level `MacDisplayOutput.apply` is explicitly residual relative to the current table; the
workflow does not call it. The standalone `display reset` command intentionally restores global
ColorSync defaults and is not the session cleanup mechanism.

DDC restoration is separate. A test always attempts the original control value after a failed
write or measurement. Successful tests verify both luminance and xy after restoring. Brightness
can use a bounded measured binary search when the original readback does not reproduce the
baseline (assuming a monotonic 0…100 brightness response). Failure to measure or reproduce the
baseline is recorded as unverified restoration; the session stops instead of claiming success.
A disconnected sensor cannot prove restoration. Process termination by SIGKILL cannot run cleanup.

## Display selection and validity

`SelectedDisplay` binds one `CGDirectDisplayID`, stable display UUID, `NSScreen`, transfer-table
transaction and DDC endpoint. The patch window uses that screen, with explicit sRGB colours.
DDC endpoints are matched by checksum-valid EDID vendor/product/serial. Missing or ambiguous matches
disable DDC; there is no first-external-display fallback.

The persisted `DisplayContext` includes UUID, screen name, current pixel dimensions/refresh rate,
and available brightness, contrast, preset and input readbacks. Readbacks are diagnostic state,
not evidence of optical effect. The mode is checked before/after measurements and before writes;
a changed/disconnected display aborts the run. Restoring a table captured in another mode is
refused and reported. HDR/chroma/range remain unknown unless supplied as a `DisplayModeKey`.
`CorrectionStore` now saves explicit GUI Keep decisions per display identity and a mode signature
of pixel dimensions plus rounded refresh rate. It falls back to the most recent correction for that
display when the mode differs; the agent flags it stale rather than guaranteeing it is valid.
Contrast/preset changes also make it stale. HDR/chroma/range are not included in that signature, so
it is not a complete signal-mode validity check. This partial-key replay policy needs hardware
validation; do not infer validity from a successful load.

## Measurement boundary

Protocol v3 adds the placement preview and stillness handshake to the tagged windows introduced
in v2. For each measurement the host issues a `MeasurementRequest` with session ID, unique patch ID, settling time and
sampling duration. Samples echo both IDs. The host rejects stale/foreign tags and caps buffered
samples. The collector uses receiver-local arrival time, avoiding a phone/Mac clock-sync requirement.
It excludes settling samples, invalid/nonfinite/negative readings, luminance and chromaticity
outliers, and requires a configurable minimum count. Black samples may be zero.

Every accepted patch records its samples, mean, standard error and rejection count. Every attempt
also retains received tagged samples and any failure. Black supplies ambient subtraction; the grey
ramp fits gamma with at least three usable levels. The ALS's absolute colour accuracy remains
unvalidated, and the solver currently uses sRGB primaries.

New white-point ΔE00 values compare stimuli normalized to Y=1. This prevents probe distance or
exposure from changing a chromaticity error. They are not directly comparable to the historical
absolute-Y values in `experiments.md`. Actual/predicted luminance loss is checked separately against
the session baseline.

## Records and verification

`ExperimentRecord` is versioned and contains configuration, software revision, display/probe
identities, raw attempts, patch statistics, fitted gamma, cumulative passes, control effects, state
history, termination reason and restoration errors. `JSONExperimentRecorder` writes one atomic
JSON file per session. Console summaries are derived from this record, including failed sessions.
Storage failure is surfaced to the caller rather than reported as a saved experiment.

The CLI obtains `git describe --always --dirty`; the Mac app build stamps the same revision into
its bundle. CLI artifacts live in `local/experiments`; app artifacts live in
`~/Library/Application Support/D65/Experiments`.

Deterministic tests inject probes, displays, clocks and presenters. They cover missing samples,
disconnects, cancellation, failed/partial writes, exact restoration, consecutive and concurrent
sessions, brightness restoration, foreign sample tags, connection admission, DDC read failures and
record round trips. Revision `b219ab6` additionally completed a real CLI/probe session on the K27:
normalized ΔE00 4.56 → 1.40 in one pass, no reported restoration errors. See
[experiment §13](experiments.md#13-first-real-session-after-the-shared-engine-and-app-changes).
The GUI Keep/Discard path and sensor accuracy against a reference remain unverified on hardware.

## Non-goals

No distributed services, ICC profiling, gamut correction, or reference-colorimeter accuracy claims.
The Mac agent owns explicitly kept corrections through `CorrectionHold`, restores on normal quit,
and can reapply stored corrections when launched or when a display returns. Engine sessions still
restore before Review; preview/Keep is separate from measurement. Full mode validity and crash
recovery beyond macOS process-exit behavior remain limitations.

## Probe tactile feedback

`D65ProbeSupport` keeps haptic scene/timing policy separate from measurement maths and native
playback. The iOS adapter uses low-intensity Core Haptics transients with a soft UIKit fallback.
Local sampling-window events allow only boundary cues that fit in settling; colour samples wait
for playback completion and a quiet interval. The default Subtle setting, optional Clear/Off,
geometry hysteresis and retry/terminal deduplication are described in [probe-haptics.md](probe-haptics.md).
