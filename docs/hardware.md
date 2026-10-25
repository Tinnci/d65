# Hardware notes

## Test display

| Property | Value |
|---|---|
| EDID manufacturer | `HAN` |
| Product | `0x2700`, name `K27` |
| Size / mode | 3840×2160, 60 Hz, UI 1920×1080 |
| Connection | USB-C (DisplayPort alt mode) |
| Year | 2022 |
| DDC endpoint | `DCPAVServiceProxy`, `Location = External`, `IOAVServiceUserInterfaceSupported = Yes` |

EDID reads cleanly over I2C at address `0x50`, which is how the identification above was obtained
(the `m1ddc`/Arm64DDC paths only speak DDC at `0x37`).

## DDC/CI capability matrix

Measured with `d65 ddc` (Arm64DDC port: XOR checksum, 4 retries, 10/50/20 ms sleeps). Every write
was followed by a read-back and a restore.

| VCP | Meaning | Read | Write | Evidence |
|---|---|---|---|---|
| `0x10` | luminance | ⚠️ | ✅ | write 100 raised measured Y by 93 %; readback reported 0 while lit |
| `0x12` | contrast | ✅ | ✅ | 50→80 raised measured Y 17.5 % and Δxy 0.0247; restored |
| `0x14` | colour preset | ✅ | ✅ | 5 → 11 → read 11 → restored 5 |
| `0x60` | input source | ✅ | ✅ | reads 15 |
| `0x0C` | colour temperature | ✅ | ⚠️ | wrote 201, read back 2 — semantics unclear |
| `0x16` | red gain | ✅ | ❌ | write ignored even in User preset |
| `0x18` | green gain | ✅ | ❌ | write ignored |
| `0x1A` | blue gain | ✅ | ❌ | write ignored |

Current values: `R 49 / G 46 / B 42`, contrast 50, preset 5 (6500 K fixed), brightness 30 (set by
hand after the brightness test; the true value before that test is unknown).

**Readback is not evidence.** Brightness reads `0` while the display is clearly lit, and writing
that `0` back dimmed the panel by 34 %. Any automation must verify with the sensor and restore by
measured luminance, not by the value it read.

Phantom VCPs (implausible maximum, no real control): `0x0B` (max 24028), `0x0D`, `0x8A`, `0xE0`.
Inert: `0x6C` accepts a write (readback 100) but changes nothing measurable; `0x6E` likely the
same. Unverified: `0x52`, `0xDC`.

**Contrast is part of the calibration state.** Changing it shifts colour by more than the
corrections we apply, so a stored correction is invalid once contrast changes.

### What this means

- The monitor's **hardware white point cannot be set over DDC**. A hardware RGB-gain adapter is not
  possible on this panel; `d65 ddc gain` exists and reports the ignored write honestly.
- Brightness, contrast, input and preset *are* writable, so a "hardware controls" section in a
  future UI is viable for those.
- Switching colour preset visibly changes the picture (red gain read 49 → 75 in User mode). This is
  a preset switch, not a successful gain write, and should not be confused with one.

## macOS gamma tables

`CGSetDisplayTransferByTable` works and is the output path in use:

```
probe       R 0.0000 0.2510 0.5020 0.7529 1.0000   (256 entries, linear)
apply 0.9   changed table observed from a second process
reset       restored
```

Two platform behaviours matter:

1. **The table is reverted when the process that set it exits.** Verified: another process sees the
   scaled table while the setter is alive, then the original table returns. A shipping app must be a
   persistent agent; the CLI needs `--hold`.
2. This display reports a **linear** table, so `GammaTable.scaled` multiplies the encoded ramp
   directly. On a display with a non-linear calibrated table the same approximation applies, with
   the error measured in [experiments.md](experiments.md) §7.

## Why DDC failed over HDMI

With the display on HDMI, `IOAVServiceReadI2C` returned success but the reply bytes were garbage
(`2C 9C C2 ...`, different every call), and no reply passed the DDC checksum. `m1ddc` printed
plausible-looking numbers only because it does not validate checksums. On USB-C the same code
returns stable, checksum-valid replies. Apple silicon's HDMI path is the likely cause; the display
and the code were unchanged.
