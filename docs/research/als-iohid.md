# ALS access: what `TVLatency` actually reads

Static analysis of `TVLatency.framework` from iOS 14.5 (18E199, iPhone13,2), compared against
the public `AppleISL29003` example on The Apple Wiki.

The conclusion up front: **the wiki example is structurally right and numerically wrong for this
sensor.** Event type and the level field match, but the channel fields do not, and Apple reads an
extra per-module calibration blob that the example does not know about.

## What the extractor does

`-[TVLALSDataExtractor extractALSData:]` at `0x1c472e690`:

```
IOHIDEventSystemClientCreateWithType(type: 1)     // monitor stream
IOHIDEventSystemClientRegisterEventCallback(...)
IOHIDEventSystemClientScheduleWithRunLoop(CFRunLoopGetMain(), ...)
```

There is **no `IOHIDEventSystemClientSetMatching` call** — `nm -u` shows the framework imports only
create, register, schedule, unschedule, plus the event getters. Service selection is done in the
callback instead, by property.

## The callback, decoded

```
if IOHIDEventGetType(event) != 12 { return }              // cmp w0, #0xc

LocationID = IOHIDServiceClientCopyProperty(service, "LocationID")
Built-In   = IOHIDServiceClientCopyProperty(service, "Built-In")
if !Built-In.boolValue { return }                         // external sensors rejected

lux = IOHIDEventGetFloatValue (event, 0x000C0000)
X   = IOHIDEventGetDoubleValue(event, 0x000C0007)
Y   = IOHIDEventGetDoubleValue(event, 0x000C0008)
Z   = IOHIDEventGetDoubleValue(event, 0x000C0009)
CCT = IOHIDEventGetDoubleValue(event, 0x000C000A)

child = IOHIDEventGetChildren(event)[0]
data  = IOHIDEventGetDataValue   (child, 0x00010004)
len   = IOHIDEventGetIntegerValue(child, 0x00010003)
memmove(buf, data, 68)                                    // fixed 68-byte copy
```

The 68-byte buffer is then unpacked as `TVLALSCalibrationData`: byte 0 is the channel count
(`ldrb w8, [sp, #0x24]`), followed by float32 spectral data loaded in a loop. That is the
per-module calibration, and it arrives **inside the HID event**, not from a separate database.

Field encoding is `(type << 16) | index`, so `0x000C0000` is ALS field 0, and `0x00010003/4` are
vendor-defined fields 3 and 4 on a child event.

> Field *names* are inferred from offsets. Apple's `IOHIDEventTypes.h` is not public, so treat the
> labels as working names, not documented API.

## Comparison with the wiki example

| | `AppleISL29003` (wiki) | `TVLatency` (iOS 14.5) |
|---|---|---|
| Client | `IOHIDEventSystemCreate` | `IOHIDEventSystemClientCreateWithType(1)` |
| Service selection | `SetMatching(page 0xff00, usage 4)` | none; monitor + `Built-In` / `LocationID` filter |
| Event type | `kIOHIDEventTypeAmbientLightSensor` | `12` — matches |
| Illuminance | `…SensorLevel` | `0x000C0000` |
| Colour | raw channel 0 and 1 | X, Y, Z and CCT, `0x000C0007`–`0x000C000A` |
| Per-module calibration | not read | 68-byte vendor blob on a child event |
| Report interval | example raises it | not touched |

Two practical consequences:

1. **Do not hardcode the wiki's channel fields.** A two-channel ISL29003-era sensor and the
   four-channel part used here do not share channel offsets. Reading `0xC0001/0xC0002` on a modern
   phone would return nothing useful while the level field still looks correct — a failure mode that
   is easy to misread as "the sensor is quantised".
2. **The calibration arrives with the event.** Any reimplementation that reads channels but ignores
   the child blob is missing the data that makes the reading colorimetric. This also explains the
   per-iPhone CoreML model table on the tvOS side: the TV needs to know which sensor produced the
   numbers.

## Device results (2026-10-25)

Measured with `local/als-probe`, a read-only app sideloaded onto a stock **iPhone Air (iPhone18,4)**
with a free personal team and Developer Mode enabled.

```
client created (type 1 = monitor)
callback registered
event #1: arg3 type=16777217, arg4 type=12
ALS #1 lux=11.0000  X=11.3772  Y=11.4852  Z=9.4385  CCT=4726.67
ALS #2 lux=11.0000  X=11.2035  Y=11.4223  Z=8.9977  CCT=4727.90
```

Four findings:

1. **`CreateWithType(1)` succeeded on a stock device**, with no special entitlement and no
   jailbreak.
2. **The ALS event is the fourth callback argument** on this OS build. The third is a vendor event
   (`type = 0x01000001`), which is why the first attempt read zeros.
3. **The four doubles are X, Y, Z and CCT, not four sensor channels.** With `X=11.38, Y=11.49,
   Z=9.44` the chromaticity is `x=0.352, y=0.356`, and McCamy gives ≈4750 K against a reported
   4726 K. They agree, which settles the decode.
4. Samples arrive at roughly 4 Hz and track ambient light; `lux` moves with `Y`.

This contradicts the assumption in the previous section — see the revised conclusion below.

## Entitlements, verified

From the code signature on the same image:

```
sharingd
  com.apple.private.hid.client.event-monitor
  com.apple.private.hid.client.event-dispatch

SharingViewService
  platform-application
  com.apple.private.MobileGestalt.AllowedProtectedKeys:
      AmbientLightSensorSerialNumber, …
```

The HID entitlement lives on the daemon, not on the view service. `event-monitor` is the
entitlement an unrestricted monitor stream *should* require. But the device test above shows a
sideloaded app creating a monitor client and receiving ALS events without it, so the check is not
applied to this client type on this OS version. The entitlements are real; their enforcement
boundary is narrower than assumed.

## What this means for D65

None of this changes the plan; it sharpens the boundary.

- The probe backend stays an abstraction (`MeasurementSource`). Nothing in `D65Core`, `D65Link` or
  `D65Display` may assume a particular sensor.
- A sideloaded probe **can** read these fields on current iOS. That makes an IOHID-backed
  `MeasurementSource` viable for a self-signed build, while remaining unacceptable for the App
  Store and unusable by anyone unwilling to sideload.
- The backend stays isolated behind `MeasurementSource`, so the shipping path can use a camera or
  external sensor and the IOHID path can exist as an opt-in experiment.
- Do not generalise from one device. The check may exist for other client types, older iOS
  versions, or App Store signed apps.

## If you do test on a device

Order matters, and it is the same order the wiki page implies:

1. Create the client, register, schedule. Log whether the callback ever fires at all.
2. If it fires, log `IOHIDEventGetType` for every event before filtering — confirm 12 appears.
3. Read the level field only. Confirm it tracks a desk lamp.
4. Then read `0x000C0007`–`0x000C000A` and the child blob.
5. Only then consider `ReportInterval`, and only on a device you can restore. Changing it affects
   system auto-brightness.
