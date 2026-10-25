# Real calibration session

Use this for the CLI workflow verified on the K27 in [experiment §13](experiments.md#13-first-real-session-after-the-shared-engine-and-app-changes).
The CLI applies a temporary correction, verifies it, restores the starting gamma tables, and saves
the measurements. Keeping a correction is a separate action in the Mac app.

## Prepare the display and phone

1. Connect the display over USB-C. Keep its preset, contrast, brightness, resolution and refresh
   rate fixed throughout the session. Use a dark room; the verified run had black/ambient Y=1.29.
2. Pair and unlock the iPhone, enable Developer Mode as required by Xcode, and use the same local
   network as the Mac. Allow the probe's Local Network and Motion permissions when prompted.
3. Confirm that the local ALS source files exist: `Experiment.swift`, `IOHIDShim.swift`, and
   `MotionGate.swift` under `local/als-probe/ALSProbe`, plus `local/als-probe/D65LocalSensor.swift`.
   The factory must return a `ProbeSensor`. These files are deliberately ignored, not supplied by a
   clean clone. Without a local factory, a physical-device build reports no sensor; a Simulator
   build uses a labelled simulation and cannot validate display colour.
4. Run only one host: either the Mac app's calibration service or `d65 serve`. A second host on
   port 50515 cannot listen; a second probe connection is refused while another holds the lease.

## Build and install the physical probe

Run from the repository root with Xcode and XcodeGen installed. Choose the device identifier and
personal development team from your own paired device/account; do not use the Simulator destination.

```sh
xcrun devicectl list devices
security find-identity -v -p codesigning
xcodegen generate

export D65_DEVICE_ID='<paired-device identifier>'
export D65_TEAM_ID='<development team ID>'
xcodebuild -project D65.xcodeproj -scheme D65Probe -configuration Debug \
  -destination "id=$D65_DEVICE_ID" -derivedDataPath /tmp/d65-device \
  DEVELOPMENT_TEAM="$D65_TEAM_ID" -allowProvisioningUpdates build

xcrun devicectl device install app --device "$D65_DEVICE_ID" \
  /tmp/d65-device/Build/Products/Debug-iphoneos/D65Probe.app
```

Free personal-team signing expires after seven days; rebuild and reinstall when necessary. A USB
connection pairs/installs the app; the probe still discovers the Mac using Bonjour. Protocol v3 is
required on both sides. The `helloV2` case name is historical; its `protocolVersion` field must be 3.

## Start a session

Find the target display ID, then start the host in one terminal:

```sh
swift run d65 display list
swift run d65 serve --apply --display-id <display ID>
```

In another terminal, launch the installed probe:

```sh
xcrun devicectl device process launch --device "$D65_DEVICE_ID" \
  --terminate-existing dev.tinnci.d65.probe
```

The Mac shows a phone outline. Press the phone's front flat against the display, top edge up,
with its front ambient sensor inside the lit area. Hold it still. Placement starts measurement
automatically after steady readings; Space starts manually and Esc cancels. Keep the probe in
place through all twelve patches and any white-verification passes. The verified run took 33.35 s.

Placement uses stillness and luminance consistency, not camera-based alignment: a stationary phone
under room lighting can also settle. The operator must position it against the actual screen.

Use `serve` without `--apply` for measurement only. `--apply` never keeps a correction after the
experiment. Ctrl-C/SIGTERM stops the host through cleanup; closing the probe mid-run cancels the
measurement. Restoration errors are reported and retained in the experiment record.

## Read and retain the evidence

The host prints its source revision, patch statistics, gamma fit, baseline and best normalized
ΔE00, pass gains, termination reason and restoration errors. The atomic record is saved to
`local/experiments/<session UUID>.json`. This directory is ignored; summarize hardware findings in
`docs/experiments.md` and retain the local JSON for raw attempts and precise numbers.

The first successful run used revision `b219ab6`, session
`A0E8B5AC-4CAF-4D10-864A-0474A714C314`: normalized ΔE00 **4.560329 → 1.397355** in one pass,
gamma **2.114178**, gains **R=0.980579 / G=1 / B=0.927274**, no restoration errors. A subsequent
read-only `d65 display probe --display-id 1` showed matching linear R/G/B tables with 1024 entries.
That confirms the observed post-session table shape; it is not a second optical white measurement.

The record's `whiteErrorMetric` is `CIEDE2000, white normalized to Y=1`. Earlier experiments used
absolute sensor Y, so their ΔE00 numbers cannot be compared directly. A low error against the same
ALS demonstrates convergence, not reference-colorimeter accuracy.

## Keeping a correction in the Mac app

Quit the CLI host before starting an app session. Open the menu-bar app, choose *Calibrate
Display…*, then follow Prepare → Connect → Place → Measure → Review. Review can preview the best
eligible correction; Keep stores it and the agent holds it while running. Discard releases the
preview. Stored corrections live in `~/Library/Application Support/D65/Corrections.json`; app
experiment records live in `~/Library/Application Support/D65/Experiments`.

The store uses display UUID and pixel dimensions/rounded refresh rate. The agent flags changes in
mode, contrast or preset as stale; stale corrections can remain applied. HDR/chroma/range are not
fully characterized by that key. The CLI hardware run did not validate GUI Keep/Discard, relaunch
reapplication, mode switching, or the optical effect of the progress overlay. Those remain separate
hardware checks.
