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
| DDC reads | luminance, contrast, RGB gain, input, preset |
| DDC writes (partial) | luminance, contrast, preset, input accepted |

## Known not working

| Problem | Cause | Consequence |
|---|---|---|
| DDC RGB gain writes have no effect | panel firmware ignores 0x16/0x18/0x1A, even in User preset | no hardware white-point correction on this display |
| One pass does not land on target | gains applied to the encoded table, solver works in linear light | 6805 K → 6438 K, ΔE 9.8 instead of ~0.2 |
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

1. **Iterate to convergence.** After the verify pass, solve the residual against the corrected
   measurement and apply again, up to three passes or until ΔE00 stops improving. All within one
   session, phone stationary.
2. **Linearise the application.** Build the new table as
   `encode(decode(base[i]) × gain)` with a fitted gamma instead of multiplying encoded values.
   Compare with iteration; keep whichever converges in fewer passes.
3. **Menu-bar agent.** The gamma table is reverted when the setting process exits, so the shipping
   app must be a persistent agent that holds the correction and restores on quit.
4. **Manual controls.** Hardware (DDC) and software (gamma) sections, each with reset, with the
   hardware section disabled unless `d65 ddc writable` says the panel accepts writes.
5. **Persistence.** Store per `DisplayModeKey` with a schema version, plus crash recovery to the
   previous known-good table.
6. **Alignment.** A stand or an on-screen outline, mirroring why Apple's flow asks the user to align
   the phone and checks for motion.

## Risks

- Private APIs mean no App Store path and no guarantee across OS updates; both are isolated behind
  `MeasurementSource` / `DisplayOutput`.
- The probe must be re-signed every 7 days with a free team.
- Applying a correction while the display mode changes is untested; treat the applied state as
  unknown after a mode switch until re-read.
