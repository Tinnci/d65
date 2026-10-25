#if !targetEnvironment(simulator)
import D65Core
import D65Measurement
import Foundation
import os

/// The iPhone's ambient-light sensor, read through the private IOHID event system.
///
/// This is not public API, which is why the probe is sideload-only. IOKit is opened with `dlopen` and
/// each function resolved with `dlsym`: no private headers, no link-time dependency, and a missing
/// symbol is reported instead of crashing. The monitor client is restricted to the built-in
/// ambient-light service (Apple vendor page 0xFF00, usage 4) before any callback is registered, so
/// the process is never handed touch, button or other sensor events. The callback still checks the
/// event type. Nothing is written: no report interval, property or display state is changed.
/// See docs/research/als-iohid.md for how the fields were identified.
@MainActor final class AmbientLightSensor: ProbeSensor {
    let name = "Ambient-light sensor"
    let isSimulated = false
    private let reader = ALSReader()
    private let stillness = StillnessMonitor()

    func start(_ onSample: @escaping (MeasurementSample) -> Void) {
        stillness.start()
        reader.onEvent = { [weak self] reading in
            // Readings taken while the phone moves are dropped here, before they reach the Mac.
            guard let self, self.stillness.isStable else { return }
            onSample(MeasurementSample(xyz: reading.xyz, lux: reading.lux, reportedCCT: reading.cct))
        }
        reader.start(matching: true)
    }

    func stop() {
        reader.stop()
        stillness.stop()
    }
}

let sensorLog = Logger(subsystem: "dev.tinnci.d65.probe", category: "sensor")

/// A thin wrapper over the IOHID monitor client. Only the main run loop touches it.
final class ALSReader {
    struct Reading { let xyz: XYZ; let lux: Double; let cct: Double }

    /// Every event that reaches the callback, ambient light or not (used by the Debug sensor check).
    var onAnyEvent: ((Int32) -> Void)?
    var onEvent: ((Reading) -> Void)?
    private let api = IOHIDAPI()
    private var client: UnsafeMutableRawPointer?

    static let eventTypeAmbientLight: Int32 = 12
    /// The built-in ambient-light service: Apple vendor usage page, ambient-light usage.
    static let matching: [String: Any] = ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 4, "Built-In": true]

    func start(matching: Bool) {
        guard client == nil else { return }
        guard let api else { sensorLog.error("dlopen(IOKit) failed"); return }
        if !api.missing.isEmpty { sensorLog.error("missing IOHID symbols: \(api.missing.joined(separator: ", "), privacy: .public)") }
        guard let create = api.createWithType, let setMatching = api.setMatching, let register = api.register,
              let schedule = api.schedule else { return }
        // Type 1 is a monitor client: it observes events without consuming them.
        guard let client = create(kCFAllocatorDefault, 1, nil) else {
            sensorLog.error("IOHIDEventSystemClientCreateWithType(1) returned nil")
            return
        }
        // Matching first, so no unmatched event is ever delivered to this process.
        if matching { setMatching(client, Self.matching as CFDictionary) }
        self.client = client
        register(client, readerCallback, Unmanaged.passUnretained(self).toOpaque(), nil)
        schedule(client, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        sensorLog.debug("monitor client started (matching \(matching ? "on" : "off", privacy: .public))")
    }

    func stop() {
        guard let client, let unschedule = api?.unschedule else { return }
        unschedule(client, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        Unmanaged<AnyObject>.fromOpaque(client).release() // balances the Create
        self.client = nil
    }

    fileprivate func handle(_ event: UnsafeMutableRawPointer?) {
        guard let event, let api, let type = api.getType?(event) else { return }
        onAnyEvent?(type)
        guard type == Self.eventTypeAmbientLight, let float = api.getFloat, let double = api.getDouble else { return }
        // Field IDs are (event type << 16) | field index.
        let lux = Double(float(event, 0x000C_0000))
        let xyz = XYZ(x: double(event, 0x000C_0007), y: double(event, 0x000C_0008), z: double(event, 0x000C_0009))
        onEvent?(Reading(xyz: xyz, lux: lux, cct: double(event, 0x000C_000A)))
    }
}

/// IOHIDEventSystemClientEventCallback: target, refcon, service, event.
private func readerCallback(_ target: UnsafeMutableRawPointer?, _ refcon: UnsafeMutableRawPointer?,
                            _ service: UnsafeMutableRawPointer?, _ event: UnsafeMutableRawPointer?) {
    guard let target else { return }
    Unmanaged<ALSReader>.fromOpaque(target).takeUnretainedValue().handle(event)
}

/// The IOKit functions this reader uses, resolved at run time.
private struct IOHIDAPI {
    typealias Client = UnsafeMutableRawPointer
    typealias Event = UnsafeMutableRawPointer
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
                                         UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

    let createWithType: (@convention(c) (CFAllocator?, Int32, CFDictionary?) -> Client?)?
    let setMatching: (@convention(c) (Client, CFDictionary) -> Void)?
    let register: (@convention(c) (Client, Callback?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void)?
    let schedule: (@convention(c) (Client, CFRunLoop, CFString) -> Void)?
    let unschedule: (@convention(c) (Client, CFRunLoop, CFString) -> Void)?
    let getType: (@convention(c) (Event) -> Int32)?
    let getFloat: (@convention(c) (Event, Int32) -> Double)?
    let getDouble: (@convention(c) (Event, Int32) -> Double)?
    let missing: [String]

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }
        var missing: [String] = []
        func symbol<T>(_ name: String, as _: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { missing.append(name); return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        createWithType = symbol("IOHIDEventSystemClientCreateWithType", as: (@convention(c) (CFAllocator?, Int32, CFDictionary?) -> Client?).self)
        setMatching = symbol("IOHIDEventSystemClientSetMatching", as: (@convention(c) (Client, CFDictionary) -> Void).self)
        register = symbol("IOHIDEventSystemClientRegisterEventCallback", as: (@convention(c) (Client, Callback?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void).self)
        schedule = symbol("IOHIDEventSystemClientScheduleWithRunLoop", as: (@convention(c) (Client, CFRunLoop, CFString) -> Void).self)
        unschedule = symbol("IOHIDEventSystemClientUnscheduleWithRunLoop", as: (@convention(c) (Client, CFRunLoop, CFString) -> Void).self)
        getType = symbol("IOHIDEventGetType", as: (@convention(c) (Event) -> Int32).self)
        getFloat = symbol("IOHIDEventGetFloatValue", as: (@convention(c) (Event, Int32) -> Double).self)
        getDouble = symbol("IOHIDEventGetDoubleValue", as: (@convention(c) (Event, Int32) -> Double).self)
        self.missing = missing
    }
}

#if DEBUG
/// `-sensorCheck`: runs the reader without matching, then with it, for `seconds` each, and prints
/// which event types reached the process. With matching only type 12 (ambient light) should appear.
@MainActor enum SensorCheck {
    static func run(seconds: Double = 8) {
        Task { @MainActor in
            for matching in [false, true] {
                var counts: [Int32: Int] = [:]
                let reader = ALSReader()
                reader.onAnyEvent = { counts[$0, default: 0] += 1 }
                var last: ALSReader.Reading?
                reader.onEvent = { last = $0 }
                reader.start(matching: matching)
                print("[sensor] matching \(matching ? "on" : "off"): listening \(Int(seconds)) s")
                try? await Task.sleep(for: .seconds(seconds))
                reader.stop()
                let summary = counts.sorted { $0.key < $1.key }.map { "type \($0.key) ×\($0.value)" }
                print("[sensor] matching \(matching ? "on" : "off"): " + (summary.isEmpty ? "no events" : summary.joined(separator: ", ")))
                if let last {
                    print(String(format: "[sensor]   last reading: %.1f lux, XYZ %.3f %.3f %.3f, CCT %.0f K",
                                 last.lux, last.xyz.x, last.xyz.y, last.xyz.z, last.cct))
                }
            }
        }
    }
}
#endif
#endif
