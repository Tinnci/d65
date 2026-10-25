# Status

Last updated 2026-10-25, after the experiments in [experiments.md](experiments.md).

## Verified working

| Capability | Evidence |
|---|---|
| iPhone ALS measurement (X/Y/Z/CCT, ~4 Hz) | sideloaded probe, cover test, 3 stable sessions within 85 K |
| Motion gating | samples dropped while moving, kept when still |
| Bonjour link and framing | 8-patch session end to end, 2 Hz samples |
| Ambient subtraction from black patch | emissive values consistent across patches |
| White-point solve + quality gate | ΔE00 17–19 → predicted 0.2–0.5 |
| Alpha search | largest blend that passes the gate |
| Gamma output | apply/read-back/reset; closed-loop shift of −1760 K |
| Panel gamma fit | grey ramp → γ = 2.11 (least squares), fed into the adapter |
| Convergence | ΔE00 24.0 → 2.8 → 1.4 in two passes, in one session |
| DDC reads | luminance, contrast, RGB gain, input, preset |
| DDC brightness write | write 100 raised measured Y by 93 % — genuinely effective |
| DDC contrast write | 50→80 measured: Y +17.5 %, Δxy 0.0247, restored |
| DDC writes (partial) | preset and input accepted; input not effect-tested |

## Known not working

| Problem | Cause | Consequence |
|---|---|---|
| Contrast changes invalidate a calibration | contrast shifts Δxy by 0.02, well beyond the correction size | poll 0x12 and mark stored calibrations stale when it changes |
| DDC readback is untrustworthy | brightness reads 0 while lit; restoring by value dimmed the panel 34 % | every write must be verified with the sensor; restores are closed-loop on luminance |
| DDC RGB gain writes have no effect | panel firmware ignores 0x16/0x18/0x1A, even in User preset | no hardware white-point correction on this display |
| ~~One pass does not land on target~~ | fixed: `scaledLinear` compensates display gamma, then the loop iterates | 18.75 → 2.36 ΔE00 in two passes |
| Blue/cyan unmeasurable in daylight | ambient Y ≈ 14 vs blue Y ≈ 10 | primaries incomplete unless the room is dark |
| Cross-session repeatability | phone is hand-held | ±1200 K between sessions; in-session verification is the workaround |
| App Store distribution | private IOHID and IOAVService | sideload only, 7-day signing |

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

1. **Effect-verified DDC harness.** `d65 ddc effect-test`: for each candidate VCP, measure white,
   write a large value, re-measure, restore by measured luminance, and classify the result as
   effective / read-only / different semantics. Cache the outcome per display (EDID identity) so it
   is probed once.
2. **Menu-bar agent.** The gamma table is reverted when the setting process exits, so the shipping
   app must be a persistent agent that holds the correction and restores on quit.
3. **Manual controls.** Hardware (DDC) and software (gamma) sections, each with reset, with the
   hardware section disabled unless `d65 ddc writable` says the panel accepts writes.
4. **Persistence.** Store per `DisplayModeKey` with a schema version, plus crash recovery to the
   previous known-good table.
5. **Alignment.** A stand or an on-screen outline, mirroring why Apple's flow asks the user to align
   the phone and checks for motion.

## Risks

- Private APIs mean no App Store path and no guarantee across OS updates; both are isolated behind
  `MeasurementSource` / `DisplayOutput`.
- The probe must be re-signed every 7 days with a free team.
- Applying a correction while the display mode changes is untested; treat the applied state as
  unknown after a mode switch until re-read.
