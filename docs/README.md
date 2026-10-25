# D65 documentation

Everything known about this project, in reading order.

| Document | What it answers |
|---|---|
| [status.md](status.md) | What works today, what does not, and what is next |
| [implementation.md](implementation.md) | Module layout, CLI reference, wire protocol |
| [experiments.md](experiments.md) | What was measured, with dates, numbers and conclusions |
| [hardware.md](hardware.md) | The test display: DDC capabilities, gamma behaviour |
| [architecture.md](architecture.md) | Why the code is split the way it is |
| [research/apple-color-balance.md](research/apple-color-balance.md) | How Apple's tvOS Color Balance works, from firmware |
| [research/als-iohid.md](research/als-iohid.md) | How the iPhone ambient-light sensor is read, decoded and gated |

## Short version

D65 measures an external display with an iPhone's ambient-light sensor, solves a per-channel
white-point correction, and applies it to the Mac's gamma table. The measurement path, the solver
and the output path are each verified on real hardware. Two things are not: convergence in a single
pass, and hardware (DDC) gain writes, which this panel ignores.

## Conventions in these documents

- **Verified** means measured on the hardware described, with the number included.
- **Inferred** means read out of a binary or protocol, not executed.
- Dates are 2026 unless stated otherwise; the whole investigation happened on 2026-10-25.
- Where an earlier claim was wrong, the correction is recorded in place rather than silently fixed.
