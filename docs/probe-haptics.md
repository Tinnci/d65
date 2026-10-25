# Probe haptic language

D65 Probe uses quiet, short transient cues to make its state understandable while the screen faces
the monitor. **Subtle** is the default; **Clear** is stronger throughout, and
**Off** disables app-generated cues. The setting is saved on the phone. **Feel the start cue** plays
the gentle measurement-start pair so intensity can be checked before placement. Native controls
retain their platform behavior; the app does not add a second custom tick to its strength picker.

Controls appear before/after a measurement, not on the dim measurement screen. Every cue also has
visual feedback. Haptics are optional, and missing hardware or a playback error cannot prevent
calibration.

## Scene map

| Scene | Cue | Trigger control |
|---|---|---|
| Connected | soft rising pair | one connection event; automatic retries after a problem stay quiet |
| Connection lost | soft descending pair | one connectivity warning until a placement is accepted |
| Placement requested | small tap | skipped if it would crowd the connection cue |
| TrueDepth requested | very small tap | once per explicit alignment attempt |
| Flat surface acquired | faint tick | 0.6 s of reliable geometry |
| Approximately level surface | tiny pair | sustained ≤3°; 6° reset threshold; at most once per attempt |
| Near-screen approach | small tick | sustained ≤30 cm, 35 cm reset threshold; at most once per attempt |
| Depth aid finished | small handover tap | after camera shutdown/ALS cooldown, not proof of contact |
| Unreliable/unavailable depth | muted attention tick | sustained missing depth, not every camera frame |
| Measurement starts | gentle rising pair | only at the first patch's settling boundary |
| Next patch | silent | the user can't act on it, and each tap nudges a phone lying on the glass |
| White verification pass | tiny pair | at the verification request's settling boundary |
| Improved result | soft completion pair | one terminal cue per session |
| Already within tolerance | even light pair | distinct from improvement and rejection |
| Measurement-only completion | single quiet completion tap | informational outcome, not an error |
| Gate rejection / refused probe | spaced quiet pair | attention without the old strong system warning |
| Measurement/restoration failure | three small descending taps | error takes precedence over an earlier good pass |
| Cancellation | muted single tap | explicit cancellation, not an inferred failed measurement |
| Result dismissal | selection tick | user action, subject to burst limiting |

The geometry cues describe an approximately flat surface, not recognition of the display. They
cannot certify snug contact or choose a colour observer. Repeated depth readings and threshold
jitter do not create a stream of vibrations; stronger milestones also count as surface acquisition.

## Sampling isolation

Haptic motion can disturb the ALS, gyro and depth estimates. The policy therefore distinguishes
ordinary scene cues from a deliberately allowed settling-boundary cue:

- A patch cue is eligible only if its conservative duration, 250 ms quiet interval and 50 ms margin
  fit within the request's configured settling time. Short settling windows skip it.
- Other cues are suppressed for the entire active patch window. Nothing is queued to play halfway
  through sampling. Duplicate patch IDs cannot replay a cue; a stale close cannot unlock a new window.
- Colour samples are withheld throughout actual playback and for 250 ms after completion. Normal
  Core Haptics playback uses its completion callback, not an assumed timer, to release that guard.
- Cancelling playback stops its player/pending fallback pulses and allows an extra 80 ms transient
  tail before the quiet interval. Muting cannot immediately admit samples disturbed by a previous cue.
- The UIKit fallback preserves the same relative timing/intensity using soft impacts. It waits for
  its last transient tail before marking playback finished. No loud notification generator is used.
- These checks combine with the existing CoreMotion and TrueDepth sampling guards. The Mac's normal
  settling and minimum-sample rules remain in force. Long playback/startup delays may reduce the
  usable sample count and fail a measurement rather than intentionally accepting disturbed readings.

The guard durations are engineering choices, not a measurement of the sensor's impulse response.
Check enabled-versus-disabled white readings on hardware before treating the effect as negligible.

## Playback lifecycle

Core Haptics patterns contain transient haptic events only, with no audio. Each cue has a relative
weight (0.055–0.16) that each strength maps onto what the Taptic Engine renders: Subtle is
0.25 + 1.6 × weight (about 0.34–0.51), Clear is 0.45 + 2.6 × weight (about 0.59–0.87), with sharpness
0.4–0.54 so short taps stay crisp. The first tuning used the weights directly (0.045–0.16) and was
not felt on an iPhone Air: transients below about 0.25 are lost against a hand or a desk.
These numbers are API parameters, not calibrated physical forces. Patterns last
at most 300 ms including the fallback tail. A global 350 ms separation prevents crowded cues,
ordinary repeated cue types have a 1.5 s cooldown, and terminal outcomes are deduplicated until a
new placement. Automatic busy/refused/reconnect loops do not keep buzzing.

Backgrounding stops playback; returning does not replay old events. Engine interruption/reset
invalidates players and uses a fresh player on a later event. Playback tokens prevent an old
completion callback from releasing a newer cue's sampling guard. Changing to Off cancels pending
pulses and retains the previous motion-settling interval.

`D65ProbeSupport` contains the pure pattern/timing policy; `Apps/D65Probe/ProbeHaptics.swift` adapts
it to Core Haptics/UIKit. Local link events mark actual measurement request boundaries. Protocol
v4 also gives cancellations and measurement-only completions distinct `LinkFailure` codes (4 and
5 respectively); the wire case name `failure` is historical, and the phone presents those codes
as informational scenes. Restoration errors still win over any earlier successful pass.

## Verification

Tests cover bounded patterns, burst/terminal/retry suppression, mute/background behavior, actual
playback completion plus quiet time, short/duplicate/stale measurement windows, and sustained
alignment milestones. Protocol/outcome tests check that cancellation or restoration errors cannot
be misreported as a successful earlier pass, and that measurement-only completion is informational.
Mac and iOS app builds verify the native adapters. Subjective feel and effects on real ALS readings
still require an iPhone check; Simulator cannot validate tactile strength.

Design reference: Apple's [Playing haptics](https://developer.apple.com/design/human-interface-guidelines/playing-haptics)
recommends short, meaningful, optional feedback and considering interference with cameras and motion
sensors. Implementation reference: [CHHapticEngine](https://developer.apple.com/documentation/corehaptics/chhapticengine).

## Diagnostics

Every cue is logged under subsystem `dev.tinnci.d65.probe`, category `haptics`: what played and at
what intensities, why a cue was held back (strength off, app inactive, another cue playing, rate
limit or an open sample window), and Core Haptics failures, engine resets and stops. Debug builds
also print these lines, so a cable-connected phone shows them with:

```
xcrun devicectl device process launch --console --device <udid> dev.tinnci.d65.probe -- -hapticCheck
```

`-hapticCheck` plays the start cue at Subtle, then Clear, two seconds apart.
