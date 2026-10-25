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
| D65Link | versioned messages and bounded length-prefixed JSON framing | Core, Measurement |
| D65MacRuntime | selected display, patch window, network probe and service | Calibration, Link, Display |
| d65 / D65Mac | command/UI configuration and presentation of results | libraries above |

The private ALS acquisition experiment remains in the ignored `local/als-probe` directory. Its
network client is shared from `Apps/D65Probe/LinkClient.swift`; the checked-in probe app is still a
sensor-free shell. The probe never solves a correction.

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
Records with incomplete mode information must not become automatic calibration-cache entries.
There is no automatic replay or calibration cache yet.

## Measurement boundary

Protocol v2 issues a `MeasurementRequest` with session ID, unique patch ID, settling time and
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
record round trips. Actual sensor accuracy and physical effects still require hardware experiments.

## Non-goals

No distributed services, ICC profiling, gamut correction, automatic replay, or reference-colorimeter
accuracy claims. Persistent correction ownership and crash recovery remain future app work.
