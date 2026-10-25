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

> **Correction (MCCS 2.2a names, capabilities string below).** `0x0B` is *Colour Temperature
> Increment* (the scale for `0x0C`), not saturation; saturation is `0x8A`. `0x6C`/`0x6E`/`0x70` are
> red/green/blue **black level**, so their white-patch effect test could not show an effect either
> way. `0x52` is *Active Control* and `0xDC` *Display Mode*. The panel's own capabilities string does
> not list `0x0B`, `0x0C`, `0x6C`, `0x6E`, `0x70` or `0x8A`, which explains the phantom and inert
> results better than plausibility of the maximum.

### Capabilities string (2026-10-25, USB-C)

`d65 ddc capabilities` reads it in 8 exchanges with no retries:

```
(prot(monitor)type(lcd)MStarcmds(01 02 03 07 0C E3 F3)vcp(02 04 05 08 10 12 14(05 08 0B 0C) 16 18 1A
52 60( 11 12 0F) AA(01 02) AC AE B2 B6 C6 C8 C9 D6(01 04 05) DC(00 02 03 05 ) DF FD)mccs_ver(2.1)mswhql(1))
```

- MStar controller, MCCS 2.1 (`0xDF` reads 0x0201). The firmware glues "MStar" onto the `cmds` key;
  the parser recovers it.
- Presets offered: 6500 K (current, `05`), 9300 K, User 1, User 2. No sRGB preset.
- `0x02` New Control Value and `0x52` Active Control are advertised, so on-screen-menu changes could
  be detected with one read instead of polling each setting. Not yet tried.
- **No colour-temperature request (`0x0C`) is advertised.** Treat it as not a hardware white-point
  path on this panel unless a sweep proves otherwise.

`d65 ddc probe` on the same day: luminance 30/100, contrast 50, preset 5 (6500 K), gains 49/46/42,
input 0x0F (DisplayPort 1), display mode 0. Every read took 83–94 ms with no retries, so a poll of
the three guarded settings costs about 0.3 s of bus time, serialized per endpoint.

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
2. This display reports a **linear** table, and the session transaction scales the captured
   baseline with `GammaTable.scaledLinear` (`gain^(1/γ)`). It restores the exact captured curves
   afterward rather than resetting global ColorSync defaults. See [experiments.md](experiments.md)
   §§7–9 for the historical motivation.

## Why DDC failed over HDMI

With the display on HDMI, `IOAVServiceReadI2C` returned success but the reply bytes were garbage
(`2C 9C C2 ...`, different every call), and no reply passed the DDC checksum. `m1ddc` printed
plausible-looking numbers only because it does not validate checksums. On USB-C the same code
returns stable, checksum-valid replies. Apple silicon's HDMI path is the likely cause; the display
and the code were unchanged.
