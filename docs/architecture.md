# Architecture

D65 is a modular monolith: one repository, one Swift package, four libraries with a strict
dependency direction. Nothing here may import the apps, and the apps may not contain colour maths.

```
D65Core        ← pure maths, zero I/O, zero UI
  ↑
D65Measurement ← samples, normalisation
  ↑
D65Link        ← protocol + framing (depends on Core, Measurement)
D65Display     ← output adapters (depends on Core only)
  ↑
Apps/D65Mac, Apps/D65Probe
```

## Modules

### D65Core

The only place that knows about colour.

- `XYZ`, `Chromaticity` — tristimulus and xy, with xyY conversion and a McCamy CCT approximation.
- `Lab`, `ColorDifference.deltaE00` — CIEDE2000, validated against the Sharma reference pairs.
- `Matrix3x3`, `DisplayPrimaries` — RGB↔XYZ for sRGB / Display P3, derived from primaries rather
  than hard-coded.
- `WhitePointSolver` — converts a measured white into per-channel gains, in linear RGB space:
  `gains = (M⁻¹·target) / (M⁻¹·measured)`, then attenuated so the brightest channel is 1.
- `RGBGains` — the correction itself: three gains plus a blend factor, with the column-major 4×4
  diagonal matrix a render-server colour matrix expects.
- `QualityGate` — the accept/reject thresholds (2.5 / 5.0 ΔE00, 20 % luminance loss).

### D65Measurement

- `MeasurementSample` — XYZ, lux, raw channels, optional reported CCT, timestamp, device.
- `MeasurementNormalizer` — plausibility filtering plus a median-centred robust mean, so one bad
  frame cannot move the result.

### D65Link

- `CalibrationMessage` — the entire wire protocol as a `Codable` enum.
- `MessageFraming` — 4-byte big-endian length prefix, JSON payload, partial-frame draining.

### D65Display

- `DisplayOutput` — the only abstraction the UI sees: `apply(gains)` / `reset()`.
- `DisplayModeKey` — the mode attributes a calibration is valid for (resolution, refresh rate,
  dynamic range, chroma), with a stable persistence key.
- `NullDisplayOutput` — for tests and previews.

## Output adapter (macOS)

`MacDisplayOutput` scales the display's existing transfer table with
`CGSetDisplayTransferByTable`, reads it back with `CGGetDisplayTransferByTable`, and restores with
`CGDisplayRestoreColorSyncSettings()`. All public API.

Two properties matter:

- It multiplies the **encoded** table, not linear light. That keeps the display's existing
  calibration curve intact and makes identity gains an exact no-op; a colorimetrically pure version
  would decode, scale, and re-encode, and would also need to know the panel's actual gamma.
- **macOS reverts the table when the process that set it exits.** Verified on this machine: while
  the setter is alive, another process reads the scaled table; once it exits, the original table is
  back. So `d65 display apply` needs `--hold`, and the shipping app has to be a persistent agent
  (menu bar) rather than a fire-and-forget command.

### DDC/CI (external monitors)

`DDCDisplay` speaks DDC/CI over `IOAVService`, ported from MonitorControl's `Arm64DDC` (MIT):
same packet layout, XOR checksum, retries and sleeps, minus the display-matching heuristics.

On this panel (HAN K27, USB-C) reads are stable and writes are ignored — the monitor acknowledges
the I2C write but the value never changes, which is common. So DDC is an **inspection** path today,
not an output path:

```
luminance 0/100   contrast 50/100   R 49   G 46   B 42
```

That read is still useful: it tells us the monitor is already configured warm-ish, which directly
contradicts the probe's white-patch reading of ~10,800 K and strengthens the suspicion that the
ALS channel triple is not colorimetric.

ICC output is a separate adapter by design: a profile only affects colour-managed apps, while the
gamma table affects everything on the display. They are not interchangeable, and the code should
never silently substitute one for the other.

## Data flow

```
probe samples ──▶ MeasurementNormalizer ──▶ WhitePointSolver ──▶ QualityGate
                                                                     │
                                                          accepted?  ▼
                                                              DisplayOutput
```

The probe never computes a correction. The Mac never talks to a sensor directly. That split is
deliberate: it mirrors the reference implementation, and it lets the sensor be swapped without
touching the maths.

## Non-goals

- Gamut or transfer-function correction. A diagonal gain matrix cannot do it, and pretending
  otherwise would repeat the overclaim the reference implementation's name invites.
- An ICC profile pipeline. It is a possible future adapter, not the first one.
- Hardware calibration. If you need a measured profile, use ArgyllCMS/DisplayCAL and a colorimeter.

## Status of the adapters

| Piece | State |
|---|---|
| Core maths, tests, CLI | working |
| Link framing | working |
| Probe acquisition | not implemented (needs an ALS source) |
| macOS output adapter | not implemented (render-server matrix or ColorSync) |
| Calibration persistence | not implemented (`DisplayModeKey` is the key format) |
