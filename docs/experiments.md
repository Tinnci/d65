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

Remaining error is dominated by the assumed γ; the panel's real transfer function is not known.
A fitted γ (measure a grey ramp) would tighten the first pass further.

## Confounds to control in future runs

| Confound | Effect | Mitigation |
|---|---|---|
| Phone position/angle between sessions | ±1200 K apparent white shift | fixed stand, or in-session verification |
| Ambient light | blue and cyan unmeasurable when ambient Y approaches their luminance | dark room (ambient Y < 2) |
| Phone screen | ALS sits next to the display; app dims it to 0.01 during patches | keep it dimmed |
| Link type | HDMI produced a 10,800 K reading, USB-C 6800 K | always note the link |
| Phone auto-lock | connection resets mid-session | idle timer disabled while running |
