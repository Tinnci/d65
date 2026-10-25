# D65 documentation

Everything known about this project, in reading order.

| Document | What it answers |
|---|---|
| [status.md](status.md) | What works today, what does not, and what is next |
| [probe-haptics.md](probe-haptics.md) | Subtle scene cues, strength controls, timing and sampling protection |
| [truedepth-alignment.md](truedepth-alignment.md) | Optional pre-contact distance/tilt aid, sampling isolation and limitations |
| [runbook.md](runbook.md) | Build/install the real probe, run a session, inspect results |
| [implementation.md](implementation.md) | Module layout, CLI reference, wire protocol |
| [experiments.md](experiments.md) | What was measured, with dates, numbers and conclusions |
| [hardware.md](hardware.md) | The test display: DDC capabilities, gamma behaviour |
| [architecture.md](architecture.md) | Why the code is split the way it is |
| [research/cie-observers.md](research/cie-observers.md) | Official CIE 2015 CMFs, D65 integration, checks and observer boundaries |
| [research/apple-color-balance.md](research/apple-color-balance.md) | How Apple's tvOS Color Balance works, from firmware |
| [research/als-iohid.md](research/als-iohid.md) | How the iPhone ambient-light sensor is read, decoded and gated |

## Short version

D65 measures an external display with an iPhone's ambient-light sensor, solves a per-channel
white-point correction, and applies it to the Mac's gamma table. The measurement path, the solver
and the output path have historical hardware evidence. The current shared session engine is covered
by deterministic tests and a protocol-v3 hardware run: normalized ΔE00 4.56 → 1.40 in one pass,
with no reported restoration errors (experiment §13). The GUI Keep/Discard flow still needs a
hardware run.
Absolute sensor accuracy and reliable single-pass convergence remain unproven. This panel ignores
hardware RGB gain writes. See the architecture notes for new normalized ΔE metrics and records.

## Conventions in these documents

- **Verified** means measured on the hardware described, with the number included.
- **Inferred** means read out of a binary or protocol, not executed.
- Dates are 2026 unless stated otherwise; the whole investigation happened on 2026-10-25.
- Where an earlier claim was wrong, the correction is recorded in place rather than silently fixed.
