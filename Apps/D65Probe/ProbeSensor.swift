import CoreMotion
import D65Core
import D65Measurement
import Foundation

/// A source of light readings: the ambient-light sensor on a device, a labelled fake in the Simulator.
@MainActor protocol ProbeSensor: AnyObject {
    var name: String { get }
    var isSimulated: Bool { get }
    func start(_ onSample: @escaping (MeasurementSample) -> Void)
    func stop()
}

@MainActor enum SensorRegistry {
    static func make() -> ProbeSensor? {
        #if targetEnvironment(simulator)
        SimulatedSensor()
        #else
        AmbientLightSensor()
        #endif
    }
}

/// Simulator only: a white slightly cooler than D65 with noise, so the whole flow can be exercised.
/// It is labelled as simulated everywhere it appears.
@MainActor final class SimulatedSensor: ProbeSensor {
    let name = "Simulated sensor"
    let isSimulated = true
    private var timer: Timer?
    func start(_ onSample: @escaping (MeasurementSample) -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            let y = 128 + Double.random(in: -1...1)
            let white = Chromaticity(x: 0.3075 + .random(in: -0.0004...0.0004), y: 0.3185).xyz(luminance: y)
            Task { @MainActor in onSample(MeasurementSample(xyz: white, lux: y)) }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }
}

/// Public CoreMotion stillness, reported with every preview reading so the Mac can start on its own.
final class StillnessMonitor: @unchecked Sendable {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var stable = false
    /// Rotation in rad/s plus linear acceleration in g, as in the reference calibrator's gate.
    var threshold = 0.10

    var isStable: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        lock.lock(); defer { lock.unlock() }
        return stable
        #endif
    }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 0.05
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let r = motion.rotationRate, a = motion.userAcceleration
            let value = max(abs(r.x), abs(r.y), abs(r.z)) + max(abs(a.x), abs(a.y), abs(a.z)) * 2
            self.lock.lock(); self.stable = value < self.threshold; self.lock.unlock()
        }
    }
    func stop() { manager.stopDeviceMotionUpdates() }
}
