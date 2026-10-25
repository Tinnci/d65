import D65Core
import Foundation

/// A kept correction, valid for one display identity in one mode with the monitor settings it was measured at.
public struct StoredCorrection: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let displayIdentity: String
    public let displayName: String
    public let width: Int
    public let height: Int
    public let refreshRate: Double
    public let gains: RGBGains
    public let gamma: Double
    public let baselineDeltaE: Double
    public let deltaE: Double
    public let createdAt: Date
    public let monitorSettings: [String: UInt16]

    public init(record: ExperimentRecord, gains: RGBGains, createdAt: Date = Date()) {
        id = record.id; displayIdentity = record.display.identity; displayName = record.display.name
        width = record.display.width; height = record.display.height; refreshRate = record.display.refreshRate
        self.gains = gains; gamma = record.gamma
        baselineDeltaE = record.baselineDeltaE ?? .nan; deltaE = record.bestDeltaE ?? .nan
        self.createdAt = createdAt; monitorSettings = record.display.monitorSettings
    }

    public var modeSignature: String { Self.modeSignature(width: width, height: height, refreshRate: refreshRate) }

    public static func modeSignature(width: Int, height: Int, refreshRate: Double) -> String {
        "\(width)×\(height)@\(Int(refreshRate.rounded()))"
    }

    /// Monitor settings that move chromaticity by more than a typical correction (experiments §12).
    public static let invalidatingSettings = ["contrast", "preset"]

    /// Why this correction may no longer describe the display, or nil if it still applies.
    public func staleReason(modeSignature current: String, monitorSettings now: [String: UInt16]) -> StaleReason? {
        if current != modeSignature { return .modeChanged(from: modeSignature, to: current) }
        for name in Self.invalidatingSettings {
            if let then = monitorSettings[name], let value = now[name], then != value {
                return .settingChanged(name: name, from: then, to: value)
            }
        }
        return nil
    }
}

public enum StaleReason: Sendable, Equatable {
    case modeChanged(from: String, to: String)
    case settingChanged(name: String, from: UInt16, to: UInt16)

    public var description: String {
        switch self {
        case .modeChanged(_, let to): return "measured in another mode (now \(to))"
        case .settingChanged(let name, let from, let to): return "\(name) \(from) → \(to)"
        }
    }
}

/// Versioned JSON store of kept corrections, one per display identity and mode.
@MainActor public final class CorrectionStore {
    private struct File: Codable { var schemaVersion = 1; var corrections: [StoredCorrection] }
    public let url: URL
    public private(set) var corrections: [StoredCorrection] = []

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
            if let file = try? decoder.decode(File.self, from: data), file.schemaVersion == 1 {
                corrections = file.corrections
            }
        }
    }

    /// The correction for this exact mode, else the most recent one for the display.
    public func correction(for identity: String, modeSignature: String) -> StoredCorrection? {
        let matching = corrections.filter { $0.displayIdentity == identity }
        return matching.first { $0.modeSignature == modeSignature }
            ?? matching.max { $0.createdAt < $1.createdAt }
    }

    public func save(_ correction: StoredCorrection) throws {
        corrections.removeAll { $0.displayIdentity == correction.displayIdentity && $0.modeSignature == correction.modeSignature }
        corrections.append(correction)
        try write()
    }

    public func remove(displayIdentity: String) throws {
        corrections.removeAll { $0.displayIdentity == displayIdentity }
        try write()
    }

    private func write() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(corrections: corrections)).write(to: url, options: .atomic)
    }
}
