> Research note, imported from the `color_cal_with_iphone` static-analysis workspace.
> It describes Apple's implementation, not this project. Kept here because it is the
> reason the design looks the way it does.

# Apple TV Color Balance — iOS 14.5 binary analysis

**Build analysed:** iOS 14.5 (18E199), iPhone13,2 (iPhone 12) restore image.
**Date:** 2026-10-25.
**Question:** is the Apple TV "Color Balance" calibration handled on the iPhone, on tvOS, or both — and can it be inspected in firmware?

---

## TL;DR

1. The iPhone side lives in **`SharingViewService.app`** and **`TVLatency.framework`**, both of which are on the device already at iOS 14.5.
2. The **measurement is the ambient-light sensor**, read through private **IOHID** APIs (`IOHIDEventSystemClient*`), not SensorKit and not the camera.
3. The **front camera is used only to align the phone and to detect which test patch is on screen** (`TVLRGBColorDetector`); it is not the colorimeter.
4. The iPhone **sends ALS readings plus its model and the sensor's spectral calibration to the Apple TV**. The TV runs the fit — confirmed in the tvOS build (§6), which contains the calibration engine, the CIEDE2000 optimiser, and the per-iPhone CoreML sensor models.
5. The result is **not** an ICC profile, LUT or hardware white point. The engine reduces it to **three RGB gains plus a blend factor**, which PineBoard applies as a **diagonal matrix through `CARenderServerSetAXMatrix`** (§8). Apple's own success string says: *"Apple TV calibrated your display's colour by adjusting its white point."*

Confidence: every step from sensor to render-server matrix is now evidenced in binaries. What remains is runtime validation and version drift, not architecture.

---

## How it was obtained

```bash
# iPhone side
ipsw download ipsw --device iPhone13,2 --version 14.5        # 5.5 GB
ipsw extract --dyld --device iPhone13,2 <ipsw>
ipsw extract --dmg fs <ipsw>
hdiutil attach -readonly -nobrowse <rootfs.dmg>

# Apple TV side (Pallas full OTA, 4.27 GB, payloadv2)
ipsw ota extract <OTA.zip> --dyld --output fw/tvos/ex --confirm
ipsw ota extract <OTA.zip> --pattern 'TVLatency' --output fw/tvos/files --confirm
ipsw dyld extract <cache> --all -o fw/tvos/ex/dylibs
```

The tools directory contains `ipsw` 3.1.739. The iOS rootfs was mounted read-only at `/tmp/ios145fs`. tvOS 14.5 was not obtainable; the 26.6 OTA was used instead and is noted as version drift.

Reproduce the interesting parts with `scripts/scan.sh`.

---

## Evidence

### 1. The iPhone-side UI is `SharingViewService.app`

```
Applications/SharingViewService.app/en.lproj/TVColorCalibrationSetup.strings
Applications/SharingViewService.app/en.lproj/TVColorCalibrationSetupUnsupported.strings
Applications/SharingViewService.app/en.lproj/Localizable-TVLatencyColorimeter.strings
Applications/SharingViewService.app/TVLatencyColorimeter.ca
```

This is the AirDrop/proximity sheet host, not the Apple TV Remote app. The Apple TV Remote bundle contains no calibration strings at all — the earlier assumption that the remote app owned this flow was wrong.

Representative strings:

| Key | English |
|---|---|
| `TVL_COLOR_TURN_PHONE_SUBTITLE` | "Turn your phone round so the front-facing camera points at the television in the device outline" |
| `TLV_SETTING_UP_COLOR_CALIBRATION` | "Hold your phone close to your TV to begin measurement." |
| `TLV_COLOR_TITLE` | "Colour Balance" |
| `TVL_COLOR_SUCCESS_SUBTITLE` | "Apple TV calibrated your display's colour by adjusting its white point." |
| `TLV_COLOR_TRYAGAIN2_SUBTITLE` | "Apple TV could not improve your picture quality. Try a picture mode like Standard or Cinema." |

Two things follow immediately:

- the camera is pointed at the TV, which is why "iPhone with Face ID" is required (the front camera + TrueDepth assembly is what the alignment step uses);
- the success text names **white point**, not gamut or gamma.

### 2. The controller classes

From `SharingViewService` (app binary):

```
SFDeviceSetupTVColorCalibratorSession      (from Sharing.framework)
TVLatencyColorimeterSetupMainController
TVLatencyColorimeterSetup{Start,Preparing,Progress,Done,TryAgain,Unsupported}ViewController
```

The app instantiates the calibrator by name and drives the UI from progress events:

```
-[TVLatencyColorimeterSetupMainController _sessionHandleProgress:info:]
-[TVLatencyColorimeterSetupMainController showTryAgainUI]
-[TVLatencyColorimeterSetupMainController showDoneUI:final:completed:]
```

`Sharing.framework` holds the transport:

```
SFDeviceSetupTVColorCalibratorService   (tvOS side)
SFDeviceSetupTVColorCalibratorSession   (iPhone side)
  _runPairSetup / _runPairVerify / _runSFSessionStart
  _runTVColorCalibratorSetup
  _runTVColorCalibratorProgressEvent:info:
```

So there are two ends of one session, one per device, over the same Sharing (SF) pairing transport used for Apple TV setup.

### 3. `TVLatency.framework` is the actual measurement engine

Extracted from the dyld shared cache and inspected with `strings` / `nm` / `otool`:

```
TVLDisplayColorCalibrator   _startPositioning, _startReadings, calibrate,
                            _sendMessage:withResponse:, _postProgressEvent:withInfo:,
                            colorDetector:metThresholdConditionsWithColor:,
                            colorDetector:movementDetected:,
                            colorDetector:backlightStateChanged:
                            ivars: role, session, state, detectorTarget, detectorMargin,
                                   maximumMotion, pitchMargin, yawMargin,
                                   stationaryFrames, useSlowALS

TVLRGBColorDetector         _setupCaptureSession, _averageColorForSampleBuffer:,
                            _startDetection, _pctChange:new:max:,
                            hue/saturation/brightness thresholds + error margins,
                            motionManager, backlightState

TVLALSDataExtractor         extract:ALSReadings:, extractALSData:, extractALSCalibrationData

TVLALSData                  x, y, z, cct, lux, channelData
TVLALSCalibrationData       channels, spectrumNom, wavelengthStartVisible,
                            wavelengthStartNIR, wavelengthEnd, wavelengthStep
```

Interpretation:

- `TVLRGBColorDetector` runs an `AVCaptureSession` on the front camera, averages the frame colour, and compares hue/saturation/brightness against a target with error margins. It also uses CoreMotion (`motionManager`, `noMotionDuration`, `maximumMotion`, pitch/yaw margins) and backlight notifications to decide whether a reading is valid. This is a **patch/position detector**, not a colorimeter.
- `TVLALSDataExtractor` produces CIE **XYZ** plus **CCT**, **lux** and raw **channel** data from the ALS, and can export the **per-device spectral calibration** of that ALS.
- `TVLDisplayColorCalibrator` orchestrates: positioning → readings → finish, with `role` distinguishing the two ends of the session.

Linked private APIs (`otool -L`, `nm -u`):

```
IOHIDEventSystemClientCreateWithType / RegisterEventCallback / ScheduleWithRunLoop
IOHIDEventGetFloatValue / GetIntegerValue / GetDataValue / GetChildren
IOHIDServiceClientCopyProperty
BrightnessSystemClient                (CoreBrightness, backlight state)
AVFoundation (AVCaptureSession, AVCaptureVideoDataOutput)
CoreMotion, SoundAnalysis, TimeSync, CoreUtils
```

This is the decisive detail: **the ALS is read through IOHID private API, not SensorKit.** There is no SensorKit dependency anywhere in this path.

### 4. What crosses the wire

Protocol keys found in `TVLatency`:

```
MESSAGE  READY  OPTIONS  COMPLETE  FINAL  FAILURE  ASK_RETRY  NOTREADY
DEVICE_TYPE  DEVICE_BUILD
ALS_CALIBRATION_DATA  ALS_CALIBRATION_{NCHANNELS,RESERVED,SPECTRUM_NOM,
                       WAVELENGTH_START_VISIBLE,WAVELENGTH_START_NIR,
                       WAVELENGTH_END,WAVELENGTH_STEP}
ALS_DATA  ALS_DATA_{X,Y,Z,CCT,LUX,CHANNELS}
DISPLAY_COLOR_CALIBRATION
DETECTOR_TARGET  DETECTOR_MARGIN  MAXIMUM_MOTION
```

Disassembly of `-[TVLDisplayColorCalibrator calibrate]` shows the iPhone building a dictionary with `DEVICE_TYPE`, `DEVICE_BUILD` and `ALS_CALIBRATION_DATA`, then registering a completion block typed `void (^)(TVLALSData *)`. `-_startReadings` sends `MESSAGE: READY` with `OPTIONS` and then sends `ALS_DATA` messages while the TV drives the patch sequence.

The Apple TV side answers with progress events and terminal states (`FINAL`, `COMPLETE`, `ASK_RETRY`). The direction of authority is therefore clear even where the arithmetic is not: the TV drives the patch sequence, decides whether the result was good enough, and is the side that changes anything.

**Now verified on the tvOS side — see §6.** Measurement happens on the iPhone; the fit, the success decision and the application all happen on the Apple TV. The phone has no display-control code in this path at all.

### 5. What the correction actually is

Apple's own UI string: *"Apple TV calibrated your display's colour by adjusting its white point."* This matches the independent measurements: a modest grey-axis improvement on a well-set-up LG C9 (ΔE 3.5 → 1.94) that is far from a real calibration (0.78), and a regression on an already-accurate reference monitor.

A per-device calibrated, multi-channel ALS measuring patches through the front of the phone, feeding a white-point/gain fit, is exactly the kind of system that produces that result — and exactly why it is called *Color Balance* rather than *calibration*.

---

## 6. tvOS 26.6 — the other half (verified)

**Build analysed:** tvOS 26.6 (23L773) full OTA for `AppleTV6,2`, pulled from Apple's Pallas asset service. The root filesystem is delivered as `payloadv2` chunks, so the cache had to come out with `ipsw ota extract --dyld`; framework resources came out with `ipsw ota extract --pattern TVLatency`.

tvOS 14.5 was not reachable through any feed, so this is a 2026 build. The feature is still present and the architecture is unchanged; the parameter tables are a later revision.

### The framework is twice the size, and contains the maths

| | iOS 14.5 | tvOS 26.6 |
|---|---|---|
| `TVLatency.framework` binary | 250 KB | 510 KB |
| Engine classes | none | `TVLColorCalibrationEngine`, `TVLWhitePointFunction`, `TVLGrayTrackingMetric`, `TVLSpectraClassifier`, `TVLColorCalALS{Input,Output}`, `TVLColorMatchingFunctionData`, `TVLMatrixData`, `TVLALSResponsivity`, `TVLDisplayTuningParams`, `TVLColorimeterFunctionOutput` |

The iPhone build has the sensor plumbing; the TV build has the colorimetry. That is the split, directly observable in binary size and class inventory.

### What the TV engine does

`TVLDisplayColorCalibrator` on tvOS is a state machine, not a measurement client:

```
_requestALS: / _delayedRequestALS:     ask the phone for a reading
_setPhase: / _nextPhase                drive the patch sequence
_setupCalibration:responseHandler:
_startCalibrationWithResponseHandler:
_askRetry
engine, numberOfReadings, phase
```

`TVLColorCalibrationEngine` then:

```
_detectAlsModel            pick the CoreML model for this iPhone
_detectDisplayType         pick the TV spectral prior
_computeTraining:          build the spectral basis
addXYZ:type: / addReadings:type: / _averageAndConvertALSData:
_detectAlsModel, _addReading:type:
```

and `TVLWhitePointFunction` performs the actual optimisation:

```
initWithRGBW:displayType:parameters:
_computeTargets, _findOptimalWP:, _findOptimalAlpha:,
_dE00:, computeOptimal, result
nativeCCT, targetCCT, truncationLevel
```

So: ALS channels → spectral reconstruction → tristimulus → **constrained white-point search minimising CIEDE2000**, with a luminance-loss limit and a gray-tracking constraint. Failure strings confirm the gates:

> "TVLColorCalibrationEngine not enough gray tracking levels -> Calibration unsuccessful"
> "TVLColorCalibrationEngine gray tracking criteria failed -> Calibration unsuccessful"
> "Color Calibration FAILED -> Ask for Retry"

### The parameters ship as data, and they explain the behaviour

`tuningParams.plist` (4.8 KB) — highlights:

| Key | Value | Meaning |
|---|---|---|
| `targetCCT` | 6504 | D65 target |
| `lowerBoundCCT` / `upperBoundCCT` | 5500 / 10000 | search range |
| `lowerWavelength` / `upperWavelength` | 370 / 830 nm, step 0.5 | spectral model |
| `basisVectors` | 120 | spectral basis rank |
| `minPreCalibrationdE00` | 2.5 | below this → "already accurate" |
| `maxPreCalibrationdE00` | 22 | above this → give up |
| `maxPostCalibrationdE00` | 5 | above this → retry |
| `luminanceLossThreshold` | 20 % | prevent a dark "fix" |
| `grayTrackingThreshold` | 2.5 | neutral-axis constraint |
| `alphaSDR` / `alphaHDR` | 0.75/0.55, 0.5/0.5 | blend of correction |
| `tvSpectras` | P3KSF, sRGB, qLED, oLED | TV spectral priors |
| `targetWhitePointOffset` | oLED: x −0.009, y −0.0015 | panel-type bias |

The 2.5 value is exactly the "your television's colour balance is accurate, it doesn't need to be calibrated right now" path; the 5.0 value is the retry path. The feature is a **bounded white-point nudge with a quality gate**, not a calibration.

`colorCalibration.plist` carries the acquisition policy — 5 readings, max motion 0.1, 10 stationary frames, 20° pitch margin, 7° yaw margin — matching the constants visible in the iOS classes.

### Per-iPhone sensor models

The TV ships four CoreML models, `TVLColorCalALS_v1` … `v4`, and selects one from the phone model reported by the iPhone:

```
"*"                  -> TVLColorCalALS_v4
"iPhone1[0-3],[0-9]" -> ""            (unsupported)
"iPhone14,[1,6,9]"   -> ""            (unsupported)
"iPhone14,[2-5,7-8]" -> v1
"iPhone15,[2-3]"     -> v1
"iPhone15,[4-5]"     -> v2
"iPhone16,[1-9]"     -> v2
"iPhone17,[1-2]"     -> v3
"iPhone17,[3-5]"     -> v2
```

This is the real reason for the Face ID requirement and the device support list: the ALS is only usable when a trained spectral model exists for that module. It also means a clone cannot simply read "the ALS" — the sensor needs its per-model transfer function, which is Apple's trained artefact.

Framework resources: `CMF.plist` (CIE matching functions, 921×3), `spectraBasis.plist` (120 basis vectors), `spectraMean.plist`, and four TV spectral priors `tvSpectra_sRGB/P3KSF/qLED/oLED.plist` (10–19 MB each).

### Conclusion

**Nothing about the correction is computed on the iPhone.** The phone measures, detects patches, and reports; the TV selects a sensor model, reconstructs spectra, optimises a white point under gray-tracking and luminance constraints, and applies it. The `role` ivar on `TVLDisplayColorCalibrator` is exactly this: same class name, two different jobs.

---

## 7. Where the result goes

The final phase of the state machine posts a result event rather than applying anything itself:

```
PHASE: WHITE → RED → GREEN → BLUE → (compute wpIterations) → GRAY TRACKING → RESULT
RESULT = { RGB: <result>, TARGETWP: <targetWP> }
```

That event is consumed by the tvOS **Settings** app, which owns the calibration screen and the display-manager client:

```
Applications/TVSettings.app/TVSettings
  TVSettingsColorCalibrationViewController
  TVSettingsColorCalibrationView
  _colorCalibrationService : SFDeviceSetupTVColorCalibratorService
  colorCalibrationForDisplayMode:
  colorCalibrationStatusForDisplayMode:
  setColorCalibration:forDisplayMode:
```

So the chain is:

```
Settings (TVSettings)
   └─ SFDeviceSetupTVColorCalibratorService        Sharing.framework
        └─ TVLDisplayColorCalibrator               TVLatency.framework
             └─ TVLColorCalibrationEngine / TVLWhitePointFunction
   ← RESULT {RGB, TARGETWP}
   └─ setColorCalibration:forDisplayMode:
        └─ PBSDisplayManagerServiceProxy           PineBoardServices.framework (XPC)
             └─ PBDisplayManagerService            PineBoard
                  saveColorCalibration:forKeys:
                  _applyColorCalibrationIfNeeded
                  _toggleColorCalibration
                  readColorCalibrations / removeColorCalibrations
                  colorCalibrations (per display mode)
                  PBTVMainDisplayTransformer transformDisplayConfiguration:
```

Evidence for each hop:

- `TVSettings` binary contains `TVSettingsColorCalibrationViewController`, the `SFDeviceSetupTVColorCalibratorService` property, and the three `…ColorCalibration…forDisplayMode:` selectors.
- `PineBoardServices` defines `PBSDisplayManagerServiceProxy` with `setColorCalibration:forKey:` / `forKeys:` and the client-side getters.
- `PineBoard` implements `PBDisplayManagerService` with `saveColorCalibration:forKeys:`, `readColorCalibrations`, `removeColorCalibrations`, `_applyColorCalibrationIfNeeded`, `_toggleColorCalibration`, the `colorCalibrations` dictionary, and `PBTVMainDisplayTransformer -transformDisplayConfiguration:`.

Two consequences worth noting:

1. **Calibration is stored per Apple TV output mode, not per TV.** `PBSColorCalibrationKeyForDisplayMode` builds the key from mode attributes — the strings `xSDRxYCbCr`, `xSDRxRGBLimited`, `xSDRxRGBFull`, `xHDR10` in `PineBoardServices` show dynamic range, chroma subsampling and RGB range going into it.

   **Correction to an earlier claim in this document:** that key does *not* observe the television's own picture preset. tvOS has no way to know whether the TV is in Cinema, Standard or Filmmaker mode. Apple's advice to recalibrate after changing picture settings is best read as a *measurement* dependency — the TV's processing changes the light the phone measures — not as cache invalidation. The two must be kept separate until runtime evidence says otherwise.
2. **"Use Original" vs "Use Balanced" is a toggle**, not a deletion — `_toggleColorCalibration` plus `removeColorCalibrations` on the PineBoard side.

The last physical hop is now traced; see §8.

---

## 8. What the correction becomes

`-[PBDisplayManager _applyColorCalibrationIfNeeded]` is short and unambiguous. Disassembled at `0x1001EC408` (PineBoard, tvOS 26.6):

```
readColorCalibrations
  → PBSColorCalibrationKeyForDisplayMode
  → objectForKey:                 log: "Retrieved Color Calibration %@ for display mode %@ with key %@"
  → PBSDisplayFiltersEnabled?     log: "AX display filters enabled. Skip applying color calibration gains."
  → display connected?            log: "Display disconnected. Not applying color calibration."
  → PBSDisplayColorCalibrationStatusForDisplayMode
                                  log: "Display mode %@ is CONFIRMED. Using identity matrix."
  → setColorGains:
```

`-[PBDisplayManager setColorGains:]` takes an **array of four numbers** and treats index 3 as an alpha:

```
gains = 1 - alpha + gain_rgb * alpha        // blend toward identity
clamp each to (0, 1]
```

Then it builds a 4×4 matrix on the stack and calls the render server:

```
str  s12, [sp, #0x00]     ; R gain
stur d0,  [sp, #0x04]     ; zeros
str  s9,  [sp, #0x10]     ; G gain
stur d0,  [sp, #0x14]     ; zeros
str  s8,  [sp, #0x20]     ; B gain
str  1.0, [sp, #0x24]     ; W = 1
bl   _CARenderServerSetAXMatrix(0, &matrix)
bl   _OBJC_CLASS_$_CADisplay → mainDisplay → update
```

So the answer to "matrix, LUT, white point, or something else" is: **a diagonal RGB gain matrix, applied as the render server's accessibility colour matrix.**

That closes several loops at once:

- `TVLDisplayTuningParams` does not travel to the display as a rich object. The engine reduces everything to three gains plus a blend factor; `TARGETWP` is an intermediate, not a payload.
- The result is *not* a hardware white point, an ICC profile, or a LUT. Gamut and transfer function are untouched, which is exactly why the measured result is a grey-axis improvement and not a calibration.
- **`PBTVMainDisplayTransformer` is not the colour path.** That lead was wrong: `transformDisplayConfiguration:` deals with bounds and overscan ("handling display bounds change notification"). The colour path bypasses the display configuration entirely.
- Calibration and accessibility display filters compete for the same slot, hence the explicit skip when AX filters are enabled.
- The "CONFIRMED" path (pre-calibration ΔE00 below 2.5) installs the identity matrix rather than skipping, so it also *removes* any previous correction.

---

## What this changes for a third-party reimplementation

- **SensorKit is irrelevant to how Apple does it.** Apple uses private IOHID. A normal App Store app cannot use `IOHIDEventSystemClient` for ALS without private entitlements (`com.apple.private.hid.client.event-monitor` and friends). SensorKit's `SRAmbientLightSample` (which does expose `chromaticity` x/y and `lux`) remains gated behind Apple's research approval.
- **A camera-only clone is a different, worse instrument.** The camera is used by Apple for patch detection and stability, not colorimetry. Reproducing the feature with the camera as the colorimeter means fighting exposure, white balance, tone mapping, spectral response, and per-unit variation — the reason phone-as-colorimeter papers need a colour chart and per-device characterisation.
- **The achievable open-source target is the output side, not the input side.** A white-point/gain correction driven by *some* ambient measurement (a calibrated external sensor, or a Mac's ALS) is realistic on macOS; an iPhone-ALS bridge is not, without private entitlements.

## Open questions / next steps

1. **Runtime validation of the matrix.** With the output mode held constant, compare the render-server AX matrix with calibration on and off, and confirm it is diagonal with the expected gains. This is the one step that turns a static call-site into proof of effect.
2. **Does the AX matrix compose or replace?** Calibration and accessibility filters share the slot, and PineBoard skips calibration when filters are on. Whether the matrix is additive with other AX transforms, or overwrites them, matters for anyone reimplementing this.
3. **Version drift.** The tvOS build is 26.6, not 14.5. The engine may have been simpler at launch (the tuning file is dated 2022-04 and carries versioned `V3` overrides). A tvOS 14.5 image would show the original parameterisation.
4. **TV-picture-mode dependence.** Untested. Static analysis says tvOS cannot see the TV's preset; only a runtime experiment (calibrate, change the TV preset, re-measure) can quantify how much the result depends on it.

## Caveats

- Static analysis on two builds (iOS 14.5, tvOS 26.6). Names and parameters can change between releases.
- The tvOS engine's existence and interface are verified; its numerical behaviour is inferred from method names, embedded parameters and log strings, not from executing it.
- The ALS transfer functions are per-module and per-model; nothing here implies an arbitrary iPhone can be substituted.

