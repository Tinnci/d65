---
name: Monitor report
about: Share how D65's DDC/CI and gamma paths behave on your display
title: "Monitor report: <make> <model> over <connection>"
labels: hardware
---

D65 has been measured on one panel. Reports from other displays decide what the app can rely on.
Everything below is read-only unless a step says otherwise.

**Display:** make, model, firmware if known
**Connection:** USB-C / DisplayPort / HDMI / dock (name it) / DisplayLink
**Mac:** model and chip, macOS version

### `d65 ddc capabilities`

```
paste output
```

### `d65 ddc probe`

```
paste output
```

### `d65 display probe --display-id <id>`

```
paste output
```

### Calibration session (optional)

If you ran a session with the probe, paste the console summary and say whether you kept the
correction. Note the room lighting and whether HDR was on.

### Anything odd

Values that read back wrong, controls that time out, behaviour after sleep or re-plug.
