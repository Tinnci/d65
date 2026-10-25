# Experiments

Everything measured on 2026-10-25, in the order it happened. Numbers are the ones printed by
`d65 serve` and `d65 ddc`, not rounded afterwards.

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

The session ran for 33.35 seconds and restored its starting gamma tables. It did not retain a
correction. Raw tagged attempts, measurements, gains, lifecycle and outcome are saved locally in
`local/experiments/A0E8B5AC-4CAF-4D10-864A-0474A714C314.json` (ignored working data).

## Confounds to control in future runs

| Confound | Effect | Mitigation |
|---|---|---|
| Phone position/angle between sessions | ±1200 K apparent white shift | fixed stand, or in-session verification |
| Ambient light | blue and cyan unmeasurable when ambient Y approaches their luminance | dark room (ambient Y < 2) |
| Phone screen | ALS sits next to the display; app dims it to 0.01 during patches | keep it dimmed |
| Link type | HDMI produced a 10,800 K reading, USB-C 6800 K | always note the link |
| Phone auto-lock | connection resets mid-session | idle timer disabled while running |
