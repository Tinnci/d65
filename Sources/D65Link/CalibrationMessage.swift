import D65Core
import D65Measurement
import Foundation

/// Everything that crosses the wire between the Mac and the probe.
public enum CalibrationMessage: Codable, Hashable, Sendable {
    /// Probe → Mac. Identifies the sensor so the Mac can pick a calibration.
    case hello(deviceModel: String, build: String)
    /// Probe → Mac. Per-module sensor calibration exported by the probe.
    case sensorCalibration(channels: [Double], wavelengths: [Double])
    /// Mac → Probe. Display is showing the reference patch; start sampling.
    case ready(options: [String: Double])
    /// Probe → Mac. One reading.
    case sample(MeasurementSample)
    /// Probe → Mac. A reading taken while the display showed a named patch.
    case phasedSample(phase: String, sample: MeasurementSample)
    /// Mac → Probe. Display progress for the probe UI.
    case progress(phase: String, fraction: Double)
    /// Mac → Probe. Final outcome, including what was applied.
    case result(gains: RGBGains, preDeltaE: Double, postDeltaE: Double, verdict: CalibrationVerdict)
    case failure(code: Int, message: String)
}

public enum FramingError: Error, Equatable {
    case frameTooLarge(Int)
    case truncated
    case malformed
}

/// Length-prefixed JSON framing: 4-byte big-endian length, then the payload.
public enum MessageFraming {
    public static let maximumFrameSize = 1 << 20

    public static func encode(_ message: CalibrationMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(message)
        guard payload.count <= maximumFrameSize else {
            throw FramingError.frameTooLarge(payload.count)
        }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        return frame
    }

    public static func decode(_ frame: Data) throws -> CalibrationMessage {
        guard frame.count >= 4 else { throw FramingError.truncated }
        let length = frame.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard length <= maximumFrameSize else { throw FramingError.frameTooLarge(Int(length)) }
        guard frame.count >= 4 + Int(length) else { throw FramingError.truncated }
        let payload = frame.subdata(in: 4..<(4 + Int(length)))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            return try decoder.decode(CalibrationMessage.self, from: payload)
        } catch {
            throw FramingError.malformed
        }
    }

    /// Consume every complete frame in `buffer`, leaving any partial tail behind.
    public static func drain(_ buffer: inout Data) throws -> [CalibrationMessage] {
        var messages: [CalibrationMessage] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            guard length <= maximumFrameSize else { throw FramingError.frameTooLarge(Int(length)) }
            let total = 4 + Int(length)
            guard buffer.count >= total else { break }
            let frame = buffer.prefix(total)
            messages.append(try decode(Data(frame)))
            buffer.removeFirst(total)
        }
        return messages
    }
}

public enum Link {
    /// Bonjour service type advertised by the Mac and browsed by the probe.
    public static let serviceType = "_d65._tcp"
    public static let protocolVersion = 1
}
