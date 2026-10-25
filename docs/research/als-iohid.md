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

lux     = IOHIDEventGetFloatValue (event, 0x000C0000)
channel = IOHIDEventGetDoubleValue(event, 0x000C0007)     // +0x0C0008
                                                          // +0x0C0009
                                                          // +0x0C000A

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
| Channels | raw channel 0 and 1 | four doubles, `0x000C0007`–`0x000C000A` |
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

The HID entitlement lives on the daemon, not on the view service. `event-monitor` is exactly the
entitlement that an unrestricted monitor stream would require — which is consistent with the
absence of `SetMatching`.

## What this means for D65

None of this changes the plan; it sharpens the boundary.

- The probe backend stays an abstraction (`MeasurementSource`). Nothing in `D65Core`, `D65Link` or
  `D65Display` may assume a particular sensor.
- A stock-iPhone probe cannot read these fields, so the shipped probe path has to be a camera, an
  external sensor, or nothing.
- The private path remains documented as research, with the entitlement requirement stated, so
  nobody mistakes "the function is visible" for "the call will work".

## If you do test on a device

Order matters, and it is the same order the wiki page implies:

1. Create the client, register, schedule. Log whether the callback ever fires at all.
2. If it fires, log `IOHIDEventGetType` for every event before filtering — confirm 12 appears.
3. Read the level field only. Confirm it tracks a desk lamp.
4. Then read `0x000C0007`–`0x000C000A` and the child blob.
5. Only then consider `ReportInterval`, and only on a device you can restore. Changing it affects
   system auto-brightness.
