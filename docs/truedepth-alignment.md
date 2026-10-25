# Optional TrueDepth alignment

D65 Probe can show an approximate distance and tilt for a nearby flat surface before the phone
contacts the display. Enable **Use TrueDepth alignment** on the phone while searching, connected,
or placing. Camera access is requested only after this action. The same advisory appears in the
Mac placement window/overlay and CLI placement output, so it remains visible as the phone turns
towards the screen.

This is an alignment aid, not screen recognition, a contact detector, or a colour sensor. It does
not choose a CIE observer, convert XYZ, or alter the iPhone source's observer assumption. Keep the
front light sensor inside the outline and finish placement by contact.

## Operation and fallback

The feature uses public AVFoundation TrueDepth depth capture, on a serial queue. Only the front
TrueDepth device is requested. No RGB output is recorded, no camera images/depth maps are saved,
and only scalar advisory readings are sent to the Mac.

- No TrueDepth hardware, camera denial/restriction, a capture failure or interruption: stop capture
  and show an unavailable message; placement can continue using the outline and stillness gate.
- Low-confidence, nonplanar or missing depth: show no distance or tilt. This never means the phone
  is in contact. **Finish depth alignment** stops the aid explicitly.
- An estimated optical-axis distance of 20 cm or less ends the aid before final contact. This is
  a chosen handover threshold, not a validated minimum working distance for TrueDepth.
- Capture also ends after 15 seconds, on measurement progress/placement end, disconnect, explicit
  stop, or entering the background. It does not automatically restart on return to the foreground.
- A stale Mac estimate loses its distance/tilt after one second. If the camera has not reported
  shutdown, colour sampling remains blocked; stale feedback cannot count as camera-off.

Both apps must be rebuilt for **protocol v4**, which adds the session-tagged `depthAlignment`
message. A v3 peer is refused with a version diagnostic. The older placement and patch-tagging
messages retain their shapes.

## Keeping infrared capture separate from colour sampling

The phone blocks colour samples as soon as alignment is requested, including while permission is
pending. Preview readings are marked unstable, and tagged patch samples are withheld. Stopping a
UI spinner does not release that block: `AVCaptureSession.stopRunning()` must finish on the capture
queue, followed by a 500 ms ALS settling interval. Only then can the phone send usable colour
samples again. This settling interval is an engineering choice, not a measured guarantee about
ALS temporal response.

The Mac resets its stillness run on active alignment feedback and refuses manual/automatic starts
while that feedback blocks colour sampling. Normal placement settling still applies afterward.
This avoids intentionally mixing the TrueDepth infrared illumination with the colour readings.
Camera and colour-source failures remain independent; lacking TrueDepth never makes the ALS
itself unavailable.

## Geometry calculation

`TrueDepthCapture` requires absolute, high-quality depth and camera calibration. It converts the
buffer to Float32 depth, respects row stride and rescales intrinsics from their reference image
size to the depth-map size. A sparse central 30% × 30% ROI is back-projected into camera coordinates.

`DepthAlignmentEstimator` fits `z = ax + by + c` by centered least squares. Distance is the plane's
intersection with the optical axis (`c`); tilt is `atan(sqrt(a²+b²))` in degrees. The result also
carries RMS point-to-plane residual. It is an approximate surface estimate: the central ROI reduces
lens-distortion effects but is not a full depth-map rectification.

Current heuristic rejection thresholds:

| Check | Requirement |
|---|---|
| Advisory depth window | 0.15–1.5 m, finite and positive |
| Coverage | at least 16 usable points and 60% of sampled pixels |
| Depth outliers | within max(3 cm, 12% of median depth) |
| Plane geometry | nondegenerate two-dimensional footprint |
| Tilt | at most 65° |
| RMS residual | at most max(3 mm, 1% of estimated distance) |

These thresholds do not establish hardware accuracy. In particular, zero/near-zero depth, NaNs,
holes or a covered camera return **no reliable depth**, not “snug” or “aligned.” Other flat surfaces
can pass the plane fit; the operator still has to point at the display.

## Verification and remaining hardware work

Deterministic tests cover front-facing and tilted planes, scaled intrinsics, invalid/contact-range
depth, holes, nonplanarity, degenerate samples, stale feedback and the shutdown/settling colour gate.
Protocol tests round-trip valid and unavailable advisories. The Mac and iOS app targets compile.
Actual TrueDepth capture, accuracy and permission/interruption behavior still need physical-device
validation; Simulator lacks this sensor and exercises the unavailable path.

On a device, compare approximate estimates against a measured distance and known flat-surface
angles before contact. Then approach the display, verify the aid stops or reports unavailable,
and verify that measurement waits for camera shutdown and normal placement settling. Repeat with
camera access denied and with the app backgrounded. Check that enabled-then-stopped versus disabled
alignment does not measurably shift the subsequent ALS white reading before relying on it.

Apple references: [streaming depth data](https://developer.apple.com/documentation/avfoundation/streaming-depth-data-from-the-truedepth-camera),
[camera calibration data](https://developer.apple.com/documentation/avfoundation/avcameracalibrationdata).
