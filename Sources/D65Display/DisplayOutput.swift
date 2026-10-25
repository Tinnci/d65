import D65Core
import Foundation

/// Applies a correction to the display output.
///
/// Implementations are responsible for the transport (render-server matrix,
/// ICC profile, DDC/CI), never for the colour maths.
public protocol DisplayOutput: Sendable {
    func apply(_ gains: RGBGains) throws
    func reset() throws
}

/// The output mode a calibration belongs to.
///
/// Apple keys its stored calibration on attributes of the Apple TV output mode
/// — dynamic range, chroma subsampling, RGB range, resolution, refresh rate —
/// not on the television's own picture preset. Reproduced here so that
/// calibrations do not leak across modes.
public struct DisplayModeKey: Codable, Hashable, Sendable {
    public enum DynamicRange: String, Codable, Hashable, Sendable {
        case sdr, hdr10, dolbyVision
    }

    public enum Chroma: String, Codable, Hashable, Sendable {
        case ycbcr420, ycbcr422, ycbcr444, rgbLimited, rgbFull
    }

    public var width: Int
    public var height: Int
    public var refreshRate: Double
    public var dynamicRange: DynamicRange
    public var chroma: Chroma

    public init(
        width: Int,
        height: Int,
        refreshRate: Double,
        dynamicRange: DynamicRange,
        chroma: Chroma
    ) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.dynamicRange = dynamicRange
        self.chroma = chroma
    }

    /// Stable key for persistence, e.g. `1920x1080@60-sdr-ycbcr420`.
    public var storageKey: String {
        let rate = refreshRate.rounded() == refreshRate
            ? String(Int(refreshRate))
            : String(format: "%.2f", refreshRate)
        return "\(width)x\(height)@\(rate)-\(dynamicRange.rawValue)-\(chroma.rawValue)"
    }
}

/// A `DisplayOutput` that does nothing, useful for previews and tests.
public struct NullDisplayOutput: DisplayOutput {
    public init() {}
    public func apply(_ gains: RGBGains) throws {}
    public func reset() throws {}
}
