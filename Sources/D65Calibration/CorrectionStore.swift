import D65Core
import D65Display
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
    public static let invalidatingSettings = MCCS.guardedSettings.map(\.name)

    /// The settings this correction can be checked against: those that were readable when it was made.
    public var guardedSettings: [String: UInt16] { monitorSettings.filter { Self.invalidatingSettings.contains($0.key) } }

    /// Compare the display's current state with the one the correction was measured in.
    /// A setting that can't be read now is reported as unverified, never as unchanged.
    public func check(modeSignature current: String, monitor: MonitorReading) -> GuardVerdict {
        if current != modeSignature { return .changed(.modeChanged(from: modeSignature, to: current)) }
        let guarded = guardedSettings
        guard !guarded.isEmpty else { return .unguarded }
        let values: [String: UInt16?]
        switch monitor {
        case .unreachable: return .unverified("Monitor not answering over DDC")
        case .values(let read): values = read
        }
        var unreadable: [String] = []
        for name in Self.invalidatingSettings {
            guard let then = guarded[name] else { continue }
            switch values[name] {
            case .some(.some(let now)) where now != then:
                return .changed(.settingChanged(name: name, from: then, to: now))
            case .some(.some): continue
            default: unreadable.append(name)
            }
        }
        return unreadable.isEmpty ? .unchanged : .unverified("Couldn’t read \(unreadable.joined(separator: ", "))")
    }
}

/// What the agent could read from the monitor just now.
public enum MonitorReading: Sendable, Equatable {
    /// No DDC endpoint answered for this display.
    case unreachable
    /// One entry per guarded setting; nil where that read failed.
    case values([String: UInt16?])
}

/// The state guard's three answers, plus the case where nothing was recorded to compare.
public enum GuardVerdict: Sendable, Equatable {
    case unchanged
    case changed(StaleReason)
    /// The correction may still be valid, but D65 can't confirm it right now.
    case unverified(String)
    /// No monitor settings were readable at calibration (no DDC), so monitor-side changes can't be detected.
    case unguarded
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
