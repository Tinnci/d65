# Status

Last updated 2026-10-25, after the experiments in [experiments.md](experiments.md).

## Architecture update and first hardware validation

The CLI and Mac app now share `D65Calibration` through `D65MacRuntime`. Sessions are main-actor
isolated, restore captured gamma tables, distinguish termination outcomes and save schema-v1 JSON
records. Protocol v4 requires rebuilding the local probe; legacy sessions are rejected. Tests cover
failure/cancellation paths, consecutive sessions, connection isolation, DDC read errors and measured
brightness restoration. See [architecture.md](architecture.md) and [implementation.md](implementation.md).
The first real run at revision `b219ab6` converged in one pass: normalized ΔE00 4.56 → 1.40,
with fitted gamma 2.114 and no reported restoration errors. See [experiment §13](experiments.md#13-first-real-session-after-the-shared-engine-and-app-changes). New white-error
metrics normalize Y=1 and must not be compared directly with historical absolute-Y numbers below.

Reproduce the session with [runbook.md](runbook.md). Before the run, 60 XCTest cases, the CLI
self-checks, the Mac app build and the signed physical-probe build passed. GUI Keep/Discard and
persistence have software coverage, but were not exercised in this hardware session.

## Observer target data

Official CIE 2015 2° and 10° CMFs and the D65 SPD are now bundled, with matching published MD5
and SHA-256 hashes, wavelength/metadata checks and independently verified integration. Their D65
xy targets are (0.313452449326, 0.330801828024) and (0.313786279487, 0.331274762958).
Use `d65 observers` to inspect them. The live iPhone remains a 1931-assumed source; these targets
do not convert its XYZ or establish physical 2015 calibration accuracy. See
[observer data and validation](research/cie-observers.md).

## Optional TrueDepth aid (software verification)

The probe can estimate pre-contact distance/tilt for an approximately flat surface and relay it to
the Mac. Camera permission is opt-in. Colour samples wait for depth capture shutdown and settling;
missing/denied depth falls back to the outline. This does not establish contact or change the
observer. Geometry/gating tests and app builds cover the software; physical TrueDepth validation
is still pending. See [alignment notes](truedepth-alignment.md).

## Verified working

| Capability | Evidence |
|---|---|
| iPhone ALS measurement (X/Y/Z/CCT, ~4 Hz) | sideloaded probe, cover test, 3 stable sessions within 85 K |
| Motion gating | samples dropped while moving, kept when still |
| Bonjour link and framing | protocol-v3 placement, twelve patches plus verification in experiment §13 |
| Ambient subtraction from black patch | emissive values consistent across patches |
| White-point solve + quality gate | ΔE00 17–19 → predicted 0.2–0.5 |
| Alpha search | largest blend that passes the gate |
| Gamma output | apply/read-back/reset; closed-loop shift of −1760 K |
| Panel gamma fit | grey ramp → γ = 2.11 (least squares), fed into the adapter |
| Convergence | normalized ΔE00 4.56 → 1.40 in one pass (§13); earlier absolute-Y runs are separate evidence |
| DDC reads | luminance, contrast, RGB gain, input, preset |
| DDC brightness write | write 100 raised measured Y by 93 % — genuinely effective |
| DDC contrast write | 50→80 measured: Y +17.5 %, Δxy 0.0247, restored |
| DDC writes (partial) | preset and input accepted; input not effect-tested |

## Known not working

| Problem | Cause | Consequence |
|---|---|---|
| Contrast changes invalidate a calibration | contrast shifts Δxy by 0.02, well beyond the correction size | poll 0x12 and mark stored calibrations stale when it changes |
| DDC readback is untrustworthy | brightness reads 0 while lit; restoring by value dimmed the panel 34 % | every write must be verified with the sensor; brightness test restores use measured luminance when the sensor remains available |
| DDC RGB gain writes have no effect | panel firmware ignores 0x16/0x18/0x1A, even in User preset | no hardware white-point correction on this display |
| ~~One pass does not land on target~~ | fixed: `scaledLinear` compensates display gamma, then the loop iterates | 18.75 → 2.36 ΔE00 in two passes |
| Blue/cyan unmeasurable in daylight | ambient Y ≈ 14 vs blue Y ≈ 10 | primaries incomplete unless the room is dark |
| Cross-session repeatability | phone is hand-held | ±1200 K between sessions; in-session verification is the workaround |
| App Store distribution | private IOHID and IOAVService | sideload only: an unsigned IPA per release, 7-day signing on a free Apple ID |

## Open questions

1. **Are the ALS channels colorimetric?** After USB-C the white reading (≈6800–7100 K) is plausible
   against the monitor's warm hardware gains, which supports treating them as XYZ. But cyan
   additivity is off by ΔE 18.6 while yellow and magenta are fine, so something in the blue path is
   not understood. Resolve with a controlled blue ramp.
2. **`0x0C` semantics.** Wrote 201, read back 2; restored to 1. Not usable until the mapping is known.
3. **tvOS version drift.** The TV-side analysis is 26.6, the phone-side is 14.5. The compute split is
   stable across those, but the parameter tables may not be.
4. **Does the correction survive a display mode change?** Not tested. The gamma table is global, so
   it should, but the stored calibration is keyed by mode by design.

## Next steps, in order

1. **Hardware validation of the new harness.** `d65 serve --effect-test` now records measurements
   and verifies restoration; `--brightness-test` adds measured restoration search. Run it with the
   rebuilt protocol-v3 probe. Per-display capability caching and richer classifications remain future work.
2. **Hardware run of the GUI flow.** The menu-bar agent, placement handshake, review preview and
   correction store are built and unit-tested, not yet exercised on the HAN K27. Check that the
   bottom-edge progress strip and the placement outline do not move the white reading (expect
   ΔE00 difference < 0.2), and re-baseline the gate thresholds on the Y = 1 metric.
3. **Manual controls.** Hardware (DDC) and software (gamma) sections, each with reset, with the
   hardware section disabled unless `d65 ddc writable` says the panel accepts writes.
4. **DDC follow-ups.** The capabilities string, serialized endpoints, cached EDID matching and the
   three-state guard are in place, and the guard's reads take about 0.3 s on the K27. Still open:
   whether DDC survives sleep and re-plug (watch for `unverified` after wake), using `0x52`/`0x02`
   to detect menu changes in one read, a sensor sweep for brightness and contrast, black-level tests
   on dark patches, and HDR.
5. **Stale-correction policy.** A stale correction stays applied and is flagged. Measure once after a
   contrast change to confirm it is still closer than none.

## Risks

- Private APIs mean no App Store path and no guarantee across OS updates; both are isolated behind
  `MeasurementSource` / `DisplayOutput`.
- The probe must be re-signed every 7 days with a free team.
- Applying a correction while the display mode changes is untested; treat the applied state as
  unknown after a mode switch until re-read.
