# Experiments

Everything measured on 2026-10-25, in the order it happened. §§1–12 reproduce the numbers recorded
from `d65 serve` and `d65 ddc`. §13 also includes statistics from the structured JSON record,
rounded to the displayed precision; the local JSON retains full precision.

Hardware: iPhone Air (iPhone18,4) running current iOS, signed with a free personal team; Mac with
Apple M6; display `HAN K27`, 3840×2160, attached over USB-C. Room lighting was not controlled
except where noted.

## 1. First contact with the ALS

The first build read zeros because the ALS event is the **fourth** callback argument on this OS,
not the third (the third is a vendor event, type `0x01000001`). Once corrected:

```
ALS #1 lux=11.0000  X=11.3772  Y=11.4852  Z=9.4385  CCT=4726.67
ALS #2 lux=11.0000  X=11.2035  Y=11.4223  Z=8.9977  CCT=4727.90
```

Four doubles decode as **X, Y, Z and CCT**, not four sensor channels: chromaticity from the first
three is `x=0.352 y=0.356`, McCamy gives ≈4750 K against a reported 4727 K.

Sample rate is roughly 4 Hz. `iohid` details are in [research/als-iohid.md](research/als-iohid.md).

## 2. Cover test

Shading the sensor area drove `lux` from 11 to 3–6; uncovering under a brighter, cooler light:

```
ALS #85 lux=6.0    X=6.80    Y=6.12    Z=4.91    CCT=3953
ALS #90 lux=489.0  X=463.00  Y=489.51  Z=492.72  CCT=5462
```

`Y` tracks `lux`, `Z` crosses above `X` for a cool illuminant, CCT moves 3950 → 5500 K. The sensor
is live and responds to illumination. At 3–5 lux CCT becomes noisy — this is what the normaliser is
for.

## 3. First white-patch sessions and a wrong turn

Early sessions over **HDMI** produced white points of ≈10,800 K, which is not a plausible display
white. After moving the display to **USB-C**, the same code reported 6832 K. The HDMI path was
almost certainly mishandling RGB range; the lesson is that the link matters as much as the code.

Three consecutive sessions with the phone held still:

```
6832 K    6761 K    6846 K        (spread 85 K)
```

That spread is acceptable. Earlier apparent instability (6832 / 8085 / 5106) came from the phone
being picked up between sessions.

## 4. Primaries and secondaries

With the room darkened (ambient `Y=1.18`), all eight patches measured:

```
white    Y=128.56  x=0.3075  y=0.3185   6911 K
red      Y= 32.46  x=0.6229  y=0.3419
green    Y= 95.88  x=0.2717  y=0.5134
blue     Y= 10.22  x=0.1705  y=0.0610
yellow   Y=120.55  x=0.3837  y=0.4542
cyan     Y= 98.40  x=0.2233  y=0.2650
magenta  Y= 36.38  x=0.3322  y=0.1515
```

Primary comparison:

```
red   vs sRGB: Δx=-0.017  Δy=+0.012
green vs sRGB: Δx=-0.028  Δy=-0.087     (between sRGB and P3)
blue  vs sRGB: Δx=+0.021  Δy=+0.001
```

Additivity (secondary vs the sum of its primaries):

```
yellow  vs red+green   ΔE00  3.2    ok
magenta vs red+blue    ΔE00  3.7    ok
cyan    vs green+blue  ΔE00 18.6    anomalous, reproduced twice
```

The cyan anomaly did not affect white-point work (white is all three channels near full scale) but
is recorded as an open question in [status.md](status.md).

## 5. Gamma control: does the pipeline see a real change?

In one session, with the phone untouched, a fixed gain was applied through the gamma table and
white was re-measured:

```
baseline   CCT 6945 K   x=0.3075 y=0.3185
apply      R=1.000 G=1.000 B=0.700
verify     CCT 5185 K   x=0.3413 y=0.3731    ΔE00 18.96 → 32.16
```

A 1760 K shift, in the expected direction. The measurement chain is sensitive to real changes,
which makes the next result meaningful.

## 6. DDC control: does a gain write change anything?

Same construction, but the Mac wrote the monitor's hardware red gain from 49 to 24 (half) over DDC:

```
baseline   CCT 6911 K   x=0.3075 y=0.3185
write      DDC 0x16: 49 → 24
verify     CCT 6936 K   x=0.3071 y=0.3185    ΔE00 18.49 → 18.48
```

25 K, inside the noise. **The panel ignores DDC gain writes.** Read-back also stays at 49, so this
is not a caching artefact — the value never reaches the panel.

Contrast this with the writes that do work (see [hardware.md](hardware.md)): luminance, contrast,
input source and colour preset all accept writes and read back correctly.

## 7. Alpha search and a single-pass limitation

With the gate in place, a full correction was applied and verified in one session:

```
baseline   CCT 6805 K   x=0.3089 y=0.3202   ΔE00 17.28
solve      R=0.978 G=1.000 B=0.921          predicted ΔE00 0.24, luminance ×0.990
apply      alpha = 1.00 (no blend needed)
verify     CCT 6438 K   x=0.3136 y=0.3325   ΔE00 17.28 → 9.78
```

Two observations:

- The correction overshoots: 6805 K → 6438 K, past the 6504 K target.
- The prediction (0.24) and the result (9.78) disagree.

Cause: gains are multiplied into the **encoded** gamma table while the solver computes in **linear
light**. The two agree only when the transfer function is linear. This was measured, then fixed in
§8.

## 8. Gamma compensation and convergence

Two changes followed from §7:

- `GammaTable.scaledLinear` scales the encoded table by `gain^(1/γ)` instead of `gain`, so the
  solver's linear-light assumption holds. `MacDisplayOutput` uses γ = 2.2.
- `d65 serve` now iterates: after each application it re-measures white in the same session,
  solves the residual, and applies again — up to three passes, stopping at ΔE00 ≤ 2 or when a pass
  stops improving.

First run after the change:

```
baseline   CCT 7238 K                          ΔE00 22.19
pass 1     gains B=0.8653    → CCT 6591 K      ΔE00  3.37
pass 2     residual B=0.9802 → CCT 6522 K      ΔE00  0.99
CONVERGED after 2 passes, cumulative R=0.997 G=0.991 B=0.848
```

Second run, a little further from target:

```
baseline                                                ΔE00 18.75
pass 1     R=0.9842 G=1.0000 B=0.9051  → 6607 K         ΔE00  6.44
pass 2     R=0.9984 G=1.0000 B=0.9765  → 6548 K         ΔE00  2.36
pass 3     R=1.0000 G=0.9990 B=0.9908  → 6537 K         ΔE00  2.93
CONVERGED after 3 passes, best ΔE00 2.36 (pass 2)
```

The third pass drifts up by 0.57, inside measurement noise, so the loop reports the **best** pass
rather than the last one. Convergence is now 18.75 → 2.36 in two passes, against 17.28 → 9.78
before the gamma compensation.

Remaining error was dominated by the assumed γ. That was measured next — see §9.

## 9. Fitting the panel gamma

Four grey patches (20/40/60/80 %) were added to the session. Emitted luminance relative to white:

```
grey20  0.200 → 0.034
grey40  0.400 → 0.141
grey60  0.600 → 0.325
grey80  0.800 → 0.618
gamma fit 2.11
```

A least-squares slope through `log(Y/Y_white) = γ·log(level)` gives **γ = 2.11**, not the assumed
2.2. The fit is fed straight into `MacDisplayOutput.gamma` before any correction is applied.

Same session, with the fitted gamma:

```
baseline                              ΔE00 24.02   (CCT 7411 K)
pass 1  B=0.8415   → 6572 K           ΔE00  2.82
pass 2  B=0.9842   → 6520 K           ΔE00  1.44
CONVERGED after 2 passes, best ΔE00 1.44
```

Compared with the fixed-2.2 runs (first pass 3.37 and 6.44, final 0.99 and 2.36), the first pass is
closer and the final result is under 1.5. Fitting γ is cheap and removes a systematic error.

## 10. DDC writes: readback is not evidence

The gain test in §6 left one question open: does a write that *reads back* correctly actually
change the picture? Brightness answered it, and the answer is uncomfortable.

```
baseline   0x10 = 0      Y = 127.26
write      0x10 = 100    Y = 245.90    (+93.2%)   ← the write is real
restore    0x10 = 0      Y =  83.47    (-34.4%)   ← the restore is not
```

Two conclusions:

1. **Brightness writes genuinely change the backlight.** Unlike RGB gain, this VCP is effective.
2. **The readback is not the truth.** The display reported `0` while producing plenty of light, and
   writing that same `0` back made the screen 34 % dimmer. Restoring by value is unsafe; a restore
   must be closed-loop against the measured luminance.

The screen was left at `0x10 = 30` (a value estimated from the luminance curve) pending visual
confirmation. This is recorded rather than quietly fixed.

## 11. VCP scan: mostly phantom controls

Reads of further VCPs, with no writes:

```
0x0B saturation      15 / 24028     max implausible → almost certainly phantom
0x0C colour temp      1 / 255       writable but semantics unknown (§7)
0x0D                  0 / 65535     phantom
0x14 preset           5 / 12        real, writable
0x16 red             49 / 100       real, read-only
0x18 green           46 / 100       real, read-only
0x1A blue            42 / 100       real, read-only
0x52 active control   0 / 255       unknown
0x6C                 50 / 255       suspicious: same value as 0x6E
0x6E                 50 / 255       suspicious
0x8A                  0 / 65535     phantom
0xDC                  0 / 255       unknown
0xE0                  0 / 65535     phantom
```

A display answers unknown VCPs too; the giveaway is an implausible `max` (24028, 65535). Those are
not controls.

## Three failure modes

| Mode | Example | Readback | Actual effect |
|---|---|---|---|
| genuinely read-only | RGB gain | unchanged | none |
| writable, readback lies | brightness 0x10 | stable but wrong (0 while lit) | real (+93 %) |
| writable, different semantics | colour temp 0x0C | 201 written, 2 read | unknown |

The middle one is the dangerous case: the readback looks self-consistent. The rule that follows is
that a write counts as successful only when **the sensor sees a change**, and a restore must be
closed-loop on measured luminance.

## 12. Effect-verified VCP test

`d65 serve --effect-test` measures white, writes a candidate VCP, re-measures, restores and
re-measures again. Classification uses the sensor, never the readback.

```
effect contrast 0x12: 50->80   ΔY=+17.5%  Δxy=0.0247  readback=80   → EFFECTIVE
effect vcp6C    0x6C: 50->100  ΔY= +0.1%  Δxy=0.0013  readback=100  → no measurable effect
```

Two results, each useful:

1. **Contrast is real, and it moves colour as well as luminance.** A 30-point contrast change
   raised Y by 17.5 % and shifted chromaticity by 0.0247 — far more than the Δxy we are trying to
   correct (typically < 0.004). Consequence: contrast must be held constant during calibration, and
   any change to it invalidates a stored correction.
2. **`0x6C` is writable but inert.** Readback reports 100, the picture does not change. This is a
   fourth behaviour: accepted, consistent, and meaningless.

Both restores returned to baseline (no WARNING printed).

## 13. First real session after the shared-engine and app changes

Revision `b219ab6`, 2026-10-25: `d65 serve --apply`, selected K27 at 3840×2160 / 60 Hz,
USB-C, iPhone Air (`iPhone18,4`) running iOS 27.2. The newly signed D65 Probe included the
local private ALS adapter and connected using protocol v3. The placement gate settled before
sampling. Monitor readbacks: brightness 30, contrast 50, preset 5, input 15; no DDC gain or
brightness writes were requested.

The session collected all twelve patches, generally eight accepted readings each (grey40 had
nine), followed by one verification white. Black/ambient Y was 1.29.

```
gamma fit     2.114178
baseline      emitted Y=142.44, x=0.3091, y=0.3209
              normalized ΔE00 4.560329
pass 1        R=0.980579 G=1.000000 B=0.927274
verify        emitted Y=141.71, normalized ΔE00 1.397355
outcome       converged in one pass
restoration   no errors; follow-up probe showed identical linear R/G/B ramps, 1024 entries
```

These errors use **Y=1 normalization**, unlike the absolute-Y errors in §§1–12. They must not
be compared numerically with the old 17–24 ΔE00 baselines. This demonstrates the new workflow
on real hardware; it does not validate the ALS against a reference colorimeter.

Raw patch means, before ambient subtraction (Y units are those reported by the probe):

| Patch | Accepted samples | Y | x | y | Standard error of Y |
|---|---:|---:|---:|---:|---:|
| black | 8 | 1.2901 | 0.28008 | 0.26465 | 0.0193 |
| white | 8 | 143.7338 | 0.30883 | 0.32033 | 0.1303 |
| red | 8 | 36.4380 | 0.60923 | 0.33934 | 0.0533 |
| green | 8 | 104.9225 | 0.27247 | 0.51093 | 0.0666 |
| blue | 8 | 12.1104 | 0.17380 | 0.06659 | 0.0170 |
| yellow | 8 | 134.0697 | 0.38627 | 0.45868 | 0.0975 |
| cyan | 8 | 103.9986 | 0.21063 | 0.25031 | 0.0577 |
| magenta | 8 | 40.4360 | 0.33447 | 0.15546 | 0.0759 |
| grey20 | 8 | 6.1253 | 0.30461 | 0.31364 | 0.0222 |
| grey40 | 9 | 21.5321 | 0.30446 | 0.31491 | 0.0576 |
| grey60 | 8 | 48.2292 | 0.30741 | 0.31894 | 0.0425 |
| grey80 | 8 | 88.8282 | 0.30747 | 0.31863 | 0.0670 |
| white verification | 8 | 143.0024 | 0.31062 | 0.32574 | 0.1120 |

The reported restoration is the engine's successful table write, with an empty
`restorationErrors` list and lifecycle `idle → measuring → applying → verifying → restoring →
finished`. The follow-up table probe checks the post-session ramp shape; no post-restoration
optical white reading was taken.

Pre-session checks passed: 60 XCTest cases (15 core, 3 link, 40 calibration, 2 runtime), all CLI
self-checks, the unsigned Mac app build, and the signed physical-device probe build. The tested
workflow was CLI calibration plus the real probe, not the GUI review/Keep flow.

Commit `b219ab6` contains the engine and apps; `d59f022` first recorded this hardware result.
See [runbook.md](runbook.md) for reproduction and the distinction between temporary sessions and
kept corrections.

The session ran for 33.35 seconds and restored its starting gamma tables. It did not retain a
correction. Raw tagged attempts, measurements, gains, lifecycle and outcome are saved locally in
`local/experiments/A0E8B5AC-4CAF-4D10-864A-0474A714C314.json` (ignored working data).

## 14. GUI flow on hardware

Revision `3da5340`, 2026-10-25. D65Mac (menu-bar agent, signed with a personal development team, built from
`.build/xcode-signed`) and D65 Probe on the iPhone Air (`iPhone18,4`, iOS 27.2, with the local ALS
adapter), K27 at 3840×2160 / 60 Hz over USB-C, display ID 1. No corrections were stored before
the run (`~/Library/Application Support/D65` did not exist), and the earlier `d65 serve` was
stopped with SIGTERM so the app could listen on port 50515.

Starting state, read before launching the app:

```
gamma table   1024 entries, linear: R/G/B 0.0000 0.2502 0.5005 0.7507 1.0000
DDC           luminance 30, contrast 50, preset 5 (6500 K), display mode 0; 9 reads, 0 retries, ≤ 90 ms each
```

### The calibration session

One app session, `05C682F6-10F3-459E-A4E0-6D319CC6680D`, calibrate mode, 33.27 s, 13 measurement
attempts with no failures. The record stores contrast 50, preset 5 and display mode 0 as the
guarded settings.

```
gamma fit     2.107692
baseline      white x=0.3094 y=0.3212 (raw mean), normalized ΔE00 4.180534
pass 1        R=0.980575 G=1.000000 B=0.934387
verify        emitted Y=141.16, x=0.3108 y=0.3259, normalized ΔE00 1.689141
outcome       converged in one pass; restorationErrors empty
lifecycle     idle → measuring → applying → verifying → restoring → finished
```

After Keep, `Corrections.json` holds that result, and a read-only `d65 display probe` showed
the agent holding it. The table's top entries were R 0.9907, G 1.0000, B 0.9683, which matches the
gains raised to 1/γ: 0.980575^(1/2.1077) = 0.9907 and 0.934387^(1/2.1077) = 0.9683. The engine had
restored the table before the agent reapplied it, as designed.

Against §13 (CLI, same panel, phone re-placed): baseline white moved by Δxy ≈ 0.0004 (0.3091,
0.3209 → 0.3094, 0.3212), baseline ΔE00 4.56 → 4.18, gamma 2.114 → 2.108, pass-1 blue gain
0.927 → 0.934. Repeatability between placements is far better than the ±1200 K of the hand-held
sessions in §3, so the outline helps.

**Gate thresholds on the Y = 1 metric.** On this panel the baseline sits at 4.2–4.6, above the
2.5 "already fine" threshold and below the 5.0 ceiling; one pass reaches 1.4–1.7, inside the 2.0
target. The thresholds give sensible decisions for this display. Two sessions are not enough to
tune them.

### Checklist

The operator reported every check as working. The table separates what the saved data also
shows from what rests on that report alone.

| # | Check | Result |
|---|---|---|
| A | Menu-bar agent, K27 "Not calibrated" | reported working |
| B | Prepare preselects K27, reads monitor controls | reported; the record's guarded settings match the starting DDC read |
| C | Probe connects; Place shows the outline | reported; probe identity `iPhone18,4`, protocol v3 in the record |
| D | Esc during Place and during Measure | reported. No cancelled-session record exists, so the mid-measure cancel left no trace (a cancel saves a record) |
| E/F | Measure-only with the progress strip off, then on | **not evidenced**: no measure-only records were saved, so the strip's optical effect is still unmeasured |
| G | Placement starts the calibration on its own | reported; session above |
| H | Review preview; Space shows the original | reported (visual) |
| I | Keep, then quit and relaunch | Keep verified (store and held table above). The app process was the same one launched at the start (pid 49892) when the results were read, so quit and relaunch are not evidenced |
| J | Contrast change marks the row Stale | reported; contrast read back 50 afterwards |
| K | Sleep and wake | reported (visual) |

Still open from this run: E/F (does the bottom progress strip change the white reading?) and a
quit-and-relaunch cycle with a read-only `d65 display probe` after each step.

### DDC is silent while the display sleeps

About 40 minutes after the session, DDC/CI on the K27 stopped responding. `d65 ddc probe`
returned no reply for every control (9 exchanges, 27 retries, 9 failures, about 500 ms each), and
`ddc capabilities` failed the same way. EDID still read at I²C address 0x50, and the gamma table
and held correction were unaffected.

Cause: the display had gone to sleep. `pmset -g log` shows "Display is turned off" at 13:08:13,
and `CGDisplayIsAsleep` reported the K27 asleep while DDC was silent. The monitor's DDC/CI
controller does not answer while asleep.

The agent already skips sleeping displays when it polls, and waits 5 s after wake. The CLI and
the debug screenshot mode did not check, so they reported timeouts; `d65 ddc` now says the
display is asleep instead. A guard reading taken from a sleeping display would read "Can't verify
monitor settings", which is truthful but not useful, so sleep must keep being skipped.

## Confounds to control in future runs

| Confound | Effect | Mitigation |
|---|---|---|
| Phone position/angle between sessions | ±1200 K apparent white shift | fixed stand, or in-session verification |
| Ambient light | blue and cyan unmeasurable when ambient Y approaches their luminance | dark room (ambient Y < 2) |
| Phone screen | ALS sits next to the display; app dims it to 0.01 during patches | keep it dimmed |
| Link type | HDMI produced a 10,800 K reading, USB-C 6800 K | always note the link |
| Phone auto-lock | connection resets mid-session | idle timer disabled while running |
