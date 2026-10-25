import AppKit
import SwiftUI

/// D65's tokens. Surfaces are opaque, equal-RGB system greys: while the user judges white, nothing in
/// the chrome should pick up wallpaper tint. One accent marks the primary action; status uses words and
/// icons first, colour second.
enum Theme {
    static let accent = dynamic(light: (0.12, 0.34, 0.66), dark: (0.55, 0.71, 0.93))
    static let ok = dynamic(light: (0.17, 0.48, 0.29), dark: (0.42, 0.78, 0.56))
    static let warn = dynamic(light: (0.60, 0.36, 0.0), dark: (0.89, 0.66, 0.28))
    static let critical = dynamic(light: (0.70, 0.15, 0.12), dark: (0.94, 0.54, 0.50))
    static let surface = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let rule = Color(nsColor: .separatorColor)

    static func tone(_ tone: ToneKind) -> Color {
        switch tone {
        case .success: ok
        case .partial, .warning: warn
        case .critical: critical
        case .info: accent
        }
    }

    private static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

enum ToneKind { case success, partial, info, warning, critical }

extension View {
    /// A grouped block: opaque card, hairline, no shadow.
    func card() -> some View {
        padding(12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.rule))
    }
}

/// ΔE00 to one decimal, CCT to 10 K with ≈: the sensor is relative evidence, not a colourimeter.
enum Format {
    static func deltaE(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        return String(format: "%.1f", value)
    }
    static func cct(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 1000 else { return "–" }
        return "≈\((Int((value / 10).rounded()) * 10).formatted()) K"
    }
    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}

/// One motion vocabulary for both apps (after hairline's two clocks). A discrete change, such as a
/// new step or a finished patch, takes a 700 ms ease on (.32, .72, 0, 1). A value that follows live
/// input, such as placement steadiness, follows a spring (k 100, c 18, m 1). Reduce Motion turns both
/// off.
enum Motion {
    static func change(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .timingCurve(0.32, 0.72, 0, 1, duration: 0.7)
    }
    static func follow(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .interpolatingSpring(mass: 1, stiffness: 100, damping: 18)
    }
}

/// A number that counts between values when it changes (Animatable, so SwiftUI drives the frames).
struct CountingText: View, Animatable {
    var value: Double
    var format = "%.1f"
    var animatableData: Double { get { value } set { value = newValue } }
    var body: some View { Text(String(format: format, value)).monospacedDigit() }
}
