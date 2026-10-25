import AVFoundation
import CoreVideo
import D65Measurement
import Foundation

/// Optional, explicit camera use. All published state and the colour-sampling gate live on main.
@MainActor final class TrueDepthAlignmentAssist {
    var onReading: ((DepthAlignmentReading) -> Void)?
    private let capture = TrueDepthCapture()
    private var safety = AlignmentSamplingGate()
    private var generation = UUID()
    private var requested = false
    private var stopping = false
    private var timeout: Task<Void, Never>?
    var permitsColourSamples: Bool { safety.permitsColourSample(at: Date()) }

    func start() {
        guard !requested, !stopping, permitsColourSamples else { return }
        let token = UUID()
        generation = token; requested = true; safety.begin()
        publish(.init(status: .starting, message: "Starting optional TrueDepth alignment…"))
        Task { [self] in
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
            default: allowed = false
            }
            guard self.requested, self.generation == token else { return }
            guard allowed else {
                self.stop(finalStatus: .unavailable, message: "Camera access is unavailable. Placement still works with the outline.")
                return
            }
            self.capture.start { [weak self] reading in
                Task { @MainActor in
                    guard let self, self.requested, self.generation == token else { return }
                    if reading.status == .unavailable {
                        self.stop(finalStatus: .unavailable, message: reading.message)
                    } else {
                        self.publish(reading)
                        if let distance = reading.distanceMeters, distance <= 0.20 {
                            self.stop(message: "Depth camera off. Finish placement against the outline by contact.")
                        }
                    }
                }
            }
            self.timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                self?.stop(message: "Depth assist timed out. Use the outline or retry before contact.")
            }
        }
    }

    /// Shutdown completion, not a UI state change, releases the colour-sampling gate.
    func stop(finalStatus: DepthAlignmentReading.Status = .finished,
              message: String = "Depth camera off. Use the outline and hold still for measurement.") {
        guard requested, !stopping else { return }
        requested = false; stopping = true
        timeout?.cancel(); timeout = nil
        let token = UUID(); generation = token
        publish(.init(status: .stopping, message: "Stopping depth camera before colour sampling…"))
        capture.stop { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.safety.cameraDidStop(at: Date())
                self.publish(.init(status: .cooldown, message: "Depth camera off; letting the light sensor settle…"))
                try? await Task.sleep(for: .milliseconds(500))
                guard self.generation == token else { return }
                self.stopping = false
                self.publish(.init(status: finalStatus, message: message))
            }
        }
    }
    private func publish(_ reading: DepthAlignmentReading) { onReading?(reading) }
}

/// Capture and depth-buffer access are confined to this serial queue. No RGB frames are retained.
private final class TrueDepthCapture: NSObject, AVCaptureDepthDataOutputDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "d65.truedepth", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let output = AVCaptureDepthDataOutput()
    private var configured = false
    private var callback: (@Sendable (DepthAlignmentReading) -> Void)?
    private var lastFrame = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    self.callback?(.init(status: .unavailable, message: "Depth capture was interrupted. Continue with the outline."))
                }
            })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func start(_ callback: @escaping @Sendable (DepthAlignmentReading) -> Void) {
        queue.async { [self] in
            self.callback = callback
            do {
                if !configured { try configure() }
                lastFrame = .distantPast
                session.startRunning()
                if !session.isRunning {
                    callback(.init(status: .unavailable, message: "TrueDepth could not start. Continue with the outline."))
                }
            } catch {
                callback(.init(status: .unavailable, message: "TrueDepth is unavailable on this device. Continue with the outline."))
            }
        }
    }
    func stop(completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            callback = nil
            if session.isRunning { session.stopRunning() }
            completion()
        }
    }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front),
              let format = device.formats.first(where: { !$0.supportedDepthDataFormats.isEmpty }),
              let depthFormat = format.supportedDepthDataFormats.filter({
                  let type = CMFormatDescriptionGetMediaSubType($0.formatDescription)
                  return type == kCVPixelFormatType_DepthFloat16 || type == kCVPixelFormatType_DepthFloat32
              }).max(by: {
                  CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
              }) else { throw CaptureError.unsupported }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority
        guard session.canAddInput(input) else { throw CaptureError.unsupported }
        session.addInput(input)
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeDepthDataFormat = depthFormat
            if format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 15 && $0.maxFrameRate >= 15 }) {
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 15)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 15)
            }
            device.unlockForConfiguration()
            guard session.canAddOutput(output) else { throw CaptureError.unsupported }
            session.addOutput(output)
            output.isFilteringEnabled = false // Do not treat interpolated/inpainted contact data as geometry.
            output.setDelegate(self, callbackQueue: queue)
            configured = true
        } catch {
            session.removeInput(input)
            throw error
        }
    }

    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData,
                         timestamp: CMTime, connection: AVCaptureConnection) {
        guard callback != nil, Date().timeIntervalSince(lastFrame) >= 0.2 else { return }
        lastFrame = Date()
        guard depthData.depthDataAccuracy == .absolute, depthData.depthDataQuality == .high,
              let calibration = depthData.cameraCalibrationData else {
            callback?(.init(status: .noReliableDepth, message: "Depth confidence is low. Finish placement using the outline."))
            return
        }
        let depth = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32).depthDataMap
        guard CVPixelBufferLockBaseAddress(depth, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        let width = CVPixelBufferGetWidth(depth), height = CVPixelBufferGetHeight(depth)
        guard let base = CVPixelBufferGetBaseAddress(depth), width > 0, height > 0 else { return }
        let reference = calibration.intrinsicMatrixReferenceDimensions
        guard reference.width > 0, reference.height > 0 else { return }
        let matrix = calibration.intrinsicMatrix
        let scaleX = Double(width) / reference.width, scaleY = Double(height) / reference.height
        let intrinsics = DepthCameraIntrinsics(fx: Double(matrix[0][0]) * scaleX, fy: Double(matrix[1][1]) * scaleY,
            cx: Double(matrix[2][0]) * scaleX, cy: Double(matrix[2][1]) * scaleY)
        var pixels: [DepthPixel] = []
        let rowBytes = CVPixelBufferGetBytesPerRow(depth)
        // Small central ROI reduces lens distortion; this remains an approximate, unrectified estimate.
        for y in stride(from: height * 35 / 100, to: height * 65 / 100, by: max(1, height / 60)) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in stride(from: width * 35 / 100, to: width * 65 / 100, by: max(1, width / 60)) {
                pixels.append(.init(x: Double(x), y: Double(y), meters: Double(row[x])))
            }
        }
        callback?(DepthAlignmentEstimator.estimate(pixels, intrinsics: intrinsics))
    }

    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didDrop depthData: AVDepthData,
                         timestamp: CMTime, connection: AVCaptureConnection, reason: AVCaptureOutput.DataDroppedReason) {
        guard Date().timeIntervalSince(lastFrame) >= 0.5 else { return }
        lastFrame = Date()
        callback?(.init(status: .noReliableDepth, message: "Depth frames unavailable. Finish placement using the outline."))
    }
    private enum CaptureError: Error { case unsupported }
}
