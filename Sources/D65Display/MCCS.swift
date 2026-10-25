import Foundation

/// VESA MCCS (Monitor Control Command Set) vocabulary used over DDC/CI.
///
/// Names follow MCCS 2.2a. A monitor may implement a code differently or not at all; the
/// capabilities string and a sensor measurement decide what a code does on a given panel.
public enum MCCS {
    public static let luminance: UInt8 = 0x10
    public static let contrast: UInt8 = 0x12
    public static let colorPreset: UInt8 = 0x14
    public static let activeControl: UInt8 = 0x52
    public static let inputSource: UInt8 = 0x60
    public static let displayMode: UInt8 = 0xDC
    public static let vcpVersion: UInt8 = 0xDF

    public static let names: [UInt8: String] = [
        0x02: "New Control Value", 0x04: "Restore Factory Defaults", 0x05: "Restore Factory Luminance/Contrast",
        0x06: "Restore Factory Geometry", 0x08: "Restore Factory Colour", 0x0B: "Colour Temperature Increment",
        0x0C: "Colour Temperature Request", 0x0E: "Clock", 0x10: "Luminance", 0x11: "Flesh Tone Enhancement",
        0x12: "Contrast", 0x13: "Backlight Control", 0x14: "Select Colour Preset", 0x16: "Video Gain: Red",
        0x17: "User Colour Vision Compensation", 0x18: "Video Gain: Green", 0x1A: "Video Gain: Blue",
        0x1C: "Focus", 0x1E: "Auto Setup", 0x1F: "Auto Colour Setup", 0x20: "Horizontal Position",
        0x30: "Vertical Position", 0x52: "Active Control", 0x54: "Performance Preservation",
        0x59: "Six-Axis Saturation: Red", 0x5A: "Six-Axis Saturation: Yellow", 0x5B: "Six-Axis Saturation: Green",
        0x5C: "Six-Axis Saturation: Cyan", 0x5D: "Six-Axis Saturation: Blue", 0x5E: "Six-Axis Saturation: Magenta",
        0x60: "Input Source", 0x62: "Audio Speaker Volume", 0x6C: "Video Black Level: Red",
        0x6E: "Video Black Level: Green", 0x70: "Video Black Level: Blue", 0x72: "Gamma", 0x86: "Display Scaling",
        0x87: "Sharpness", 0x8A: "Colour Saturation", 0x8D: "Audio Mute / Screen Blank", 0x90: "Hue",
        0xAA: "Screen Orientation", 0xAC: "Horizontal Frequency", 0xAE: "Vertical Frequency",
        0xB2: "Flat Panel Sub-Pixel Layout", 0xB6: "Display Technology Type", 0xC0: "Display Usage Time",
        0xC6: "Application Enable Key", 0xC8: "Display Controller Type", 0xC9: "Display Firmware Level",
        0xCA: "OSD / Button Control", 0xCC: "OSD Language", 0xD6: "Power Mode", 0xDC: "Display Mode",
        0xDF: "VCP Version",
    ]

    public static func name(of code: UInt8) -> String {
        names[code] ?? String(format: "Manufacturer or unknown 0x%02X", code)
    }

    /// Values of `0x14` Select Colour Preset.
    public static func presetName(_ value: UInt16) -> String? {
        [0x01: "sRGB", 0x02: "Display Native", 0x03: "4000 K", 0x04: "5000 K", 0x05: "6500 K", 0x06: "7500 K",
         0x07: "8200 K", 0x08: "9300 K", 0x09: "10000 K", 0x0A: "11500 K", 0x0B: "User 1", 0x0C: "User 2",
         0x0D: "User 3"][value]
    }

    /// Codes an automated harness must never write: they reset, blank, rotate, switch input or power off.
    public static let disruptive: Set<UInt8> = [0x04, 0x05, 0x06, 0x08, 0x60, 0x8D, 0xAA, 0xC6, 0xCA, 0xCC, 0xD6]

    /// Settings recorded with a correction because changing them moves the white more than a correction does.
    /// Luminance is not here: its readback is unreliable on the test panel (experiments §10).
    public static let guardedSettings: [(name: String, code: UInt8)] = [
        ("contrast", contrast), ("preset", colorPreset), ("displayMode", displayMode),
    ]
}

/// A parsed MCCS capabilities string, e.g.
/// `(prot(monitor)type(lcd)model(K27)cmds(01 02 03 07 0C F3)vcp(10 12 14(05 08 0B) 16 18 1A 60(0F 11))mccs_ver(2.2))`.
public struct MCCSCapabilities: Sendable, Equatable {
    public let raw: String
    public let fields: [String: String]
    /// Every listed VCP code, with its permitted values when the string lists them (list-type controls).
    public let vcp: [UInt8: [UInt16]]
    public let commands: [UInt8]

    public var model: String? { fields["model"] }
    public var type: String? { fields["type"] }
    public var mccsVersion: String? { fields["mccs_ver"] }
    public func supports(_ code: UInt8) -> Bool { vcp[code] != nil }
    /// Permitted values, or nil for a continuous control or one listed without values.
    public func values(for code: UInt8) -> [UInt16]? { vcp[code].flatMap { $0.isEmpty ? nil : $0 } }

    /// Lenient parser: monitors differ in case, spacing, outer parentheses and run-together hex.
    public init?(_ raw: String) {
        let text = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        var fields: [String: String] = [:]
        var body = Substring(text)
        if body.hasPrefix("("), body.hasSuffix(")") { body = body.dropFirst().dropLast() }
        var index = body.startIndex
        while index < body.endIndex {
            guard let open = body[index...].firstIndex(of: "(") else { break }
            var key = body[index..<open].trimmingCharacters(in: .whitespaces).lowercased()
            guard let close = Self.matchingParenthesis(in: body, from: open) else { break }
            // Some firmware writes unlabelled text before a key, e.g. `type(lcd)MStarcmds(…)` (HAN K27).
            if !Self.knownKeys.contains(key), let known = Self.knownKeys.filter({ key.hasSuffix($0) }).max(by: { $0.count < $1.count }) {
                let prefix = body[index..<open].trimmingCharacters(in: .whitespaces).dropLast(known.count)
                if fields["unlabelled"] == nil, !prefix.isEmpty { fields["unlabelled"] = String(prefix) }
                key = known
            }
            if !key.isEmpty, fields[key] == nil { fields[key] = String(body[body.index(after: open)..<close]) }
            index = body.index(after: close)
        }
        guard let vcpField = fields["vcp"] else { return nil }
        self.raw = raw
        self.fields = fields
        vcp = Self.parseVCP(vcpField)
        commands = Self.hexValues(fields["cmds"] ?? "").map { UInt8(truncatingIfNeeded: $0) }
    }

    private static let knownKeys: Set<String> = ["prot", "type", "model", "cmds", "vcp", "mccs_ver", "mswhql",
                                                 "asset_eep", "mpu", "vcpname", "window"]

    private static func matchingParenthesis(in text: Substring, from open: Substring.Index) -> Substring.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "(" { depth += 1 }
            if text[index] == ")" { depth -= 1; if depth == 0 { return index } }
            index = text.index(after: index)
        }
        return nil
    }

    private static func parseVCP(_ text: String) -> [UInt8: [UInt16]] {
        var result: [UInt8: [UInt16]] = [:]
        let characters = Array(text)
        var i = 0
        while i < characters.count {
            guard characters[i].isHexDigit else { i += 1; continue }
            var run = ""
            while i < characters.count, characters[i].isHexDigit { run.append(characters[i]); i += 1 }
            var j = i
            while j < characters.count, characters[j] == " " { j += 1 }
            var codes = pairs(run)
            if j < characters.count, characters[j] == "(", let last = codes.popLast() {
                // Values belong to the last code of a run-together token.
                for code in codes { result[code] = result[code] ?? [] }
                let substring = Substring(text)
                let open = substring.index(substring.startIndex, offsetBy: j)
                let close = matchingParenthesis(in: substring, from: open) ?? substring.endIndex
                let inner = substring[substring.index(after: open)..<close]
                result[last] = hexValues(String(inner))
                i = substring.distance(from: substring.startIndex, to: close) + 1
                codes = []
            }
            for code in codes { result[code] = result[code] ?? [] }
        }
        return result
    }

    private static func pairs(_ run: String) -> [UInt8] {
        let digits = Array(run)
        guard digits.count > 2 else { return UInt8(run, radix: 16).map { [$0] } ?? [] }
        return stride(from: 0, to: digits.count - 1, by: 2).compactMap { UInt8(String(digits[$0...$0 + 1]), radix: 16) }
    }

    /// Hex values separated by spaces; nested parentheses are flattened, run-together pairs split.
    private static func hexValues(_ text: String) -> [UInt16] {
        text.split(whereSeparator: { !$0.isHexDigit }).flatMap { token -> [UInt16] in
            token.count <= 2 ? [UInt16(token, radix: 16)].compactMap { $0 } : pairs(String(token)).map(UInt16.init)
        }
    }
}
