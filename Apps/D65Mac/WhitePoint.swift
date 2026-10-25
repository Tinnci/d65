import D65Calibration
import D65Core
import SwiftUI

/// The product's mark: a ring with a dot. Held = filled centred dot, stale = hollow dot,
/// uncorrected = small dot. Drawn, so it stays legible at 16 pt.
struct WhitePointGlyph: View {
    enum Mode { case held, stale, paused, none, critical }
    let mode: Mode
    var size: CGFloat = 22

    var body: some View {
        Canvas { context, canvas in
            let r = min(canvas.width, canvas.height) / 2 - 1.5
            let centre = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            let ring = Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
            context.stroke(ring, with: .color(mode == .critical ? Theme.critical : .secondary), lineWidth: 1.5)
            let dot = r * 0.42
            let rect = CGRect(x: centre.x - dot, y: centre.y - dot, width: dot * 2, height: dot * 2)
            switch mode {
            case .held: context.fill(Path(ellipseIn: rect), with: .color(.primary))
            case .stale: context.stroke(Path(ellipseIn: rect), with: .color(Theme.warn), lineWidth: 1.5)
            case .paused: context.stroke(Path(ellipseIn: rect), with: .color(.secondary), lineWidth: 1.2)
            case .critical: context.fill(Path(ellipseIn: rect), with: .color(Theme.critical))
            case .none:
                let small = rect.insetBy(dx: dot * 0.35, dy: dot * 0.35)
                context.fill(Path(ellipseIn: small), with: .color(.secondary.opacity(0.6)))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// CIE 1931 xy close-up around D65: Planckian locus, ΔE00 2 and 5 contours (the engine's Y = 1 metric),
/// and this session's white, one dot per pass.
struct ChromaticityPlot: View {
    let points: [Chromaticity]
    /// Rings and the spoken summary use the session's own metric.
    var metric: WhiteErrorMetric = .ciede2000

    var body: some View {
        let D65 = Self.D65
        return Canvas { context, size in
            let span = max(0.012, (points.map { max(abs($0.x - D65.x), abs($0.y - D65.y)) }.max() ?? 0) * 2.6)
            let x0 = D65.x - span / 2, y0 = D65.y - span / 2
            let scale = min(size.width, size.height) / span
            func p(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: (x - x0) * scale, y: size.height - (y - y0) * scale)
            }
            context.stroke(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.rule))
            var locus = Path()
            for (i, t) in stride(from: 4500.0, through: 12000, by: 50).enumerated() {
                let c = Self.planck(t)
                i == 0 ? locus.move(to: p(c.x, c.y)) : locus.addLine(to: p(c.x, c.y))
            }
            context.stroke(locus, with: .color(.secondary), lineWidth: 1)
            for t in [6000.0, 6500, 7000, 7500] {
                let c = Self.planck(t), at = p(c.x, c.y)
                guard CGRect(origin: .zero, size: size).insetBy(dx: 12, dy: 10).contains(at) else { continue }
                context.fill(Path(ellipseIn: CGRect(x: at.x - 2, y: at.y - 2, width: 4, height: 4)), with: .color(.secondary))
                context.draw(Text("\(Int(t)) K").font(.system(size: 9)).foregroundStyle(.secondary), at: at.applying(.init(translationX: 18, y: 9)))
            }
            for (limit, dash) in [(5.0, [4.0, 3.0]), (2.0, [])] {
                var ring = Path()
                for (i, point) in Self.contour(limit, metric: metric).enumerated() {
                    i == 0 ? ring.move(to: p(point.x, point.y)) : ring.addLine(to: p(point.x, point.y))
                }
                ring.closeSubpath()
                context.stroke(ring, with: .color(Theme.accent.opacity(0.85)), style: StrokeStyle(lineWidth: 1, dash: dash.map { CGFloat($0) }))
            }
            let target = p(D65.x, D65.y)
            context.fill(Path(ellipseIn: CGRect(x: target.x - 3, y: target.y - 3, width: 6, height: 6)), with: .color(Theme.accent))
            context.draw(Text("D65").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent), at: target.applying(.init(translationX: 16, y: -8)))
            guard !points.isEmpty else { return }
            var trail = Path()
            for (i, c) in points.enumerated() { i == 0 ? trail.move(to: p(c.x, c.y)) : trail.addLine(to: p(c.x, c.y)) }
            context.stroke(trail, with: .color(.primary), lineWidth: 1.3)
            for (i, c) in points.enumerated() {
                let at = p(c.x, c.y), last = i == points.count - 1
                let rect = CGRect(x: at.x - 3.5, y: at.y - 3.5, width: 7, height: 7)
                context.fill(Path(ellipseIn: rect), with: .color(last ? .primary : Theme.card))
                context.stroke(Path(ellipseIn: rect), with: .color(.primary), lineWidth: 1.3)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let first = points.first, let last = points.last else { return "Chromaticity plot around D65" }
        return "White moved from \(metric.label) \(Format.deltaE(Self.error(first, metric: metric))) to \(Format.deltaE(Self.error(last, metric: metric))) in \(points.count - 1) passes"
    }

    static let D65 = Chromaticity.d65
    static func error(_ c: Chromaticity, metric: WhiteErrorMetric = .ciede2000) -> Double { metric.whiteError(c.xyz()) }

    /// Kim et al. cubic spline approximation of the Planckian locus, 4000–25000 K.
    static func planck(_ t: Double) -> Chromaticity {
        let x = -3.0258469e9 / pow(t, 3) + 2.1070379e6 / pow(t, 2) + 0.2226347e3 / t + 0.240390
        return Chromaticity(x: x, y: 3.0817580 * pow(x, 3) - 5.87338670 * x * x + 3.75112997 * x - 0.37001483)
    }

    private static var contours: [String: [Chromaticity]] = [:]
    static func contour(_ limit: Double, metric: WhiteErrorMetric) -> [Chromaticity] {
        let key = "\(metric.rawValue)-\(limit)"
        if let cached = contours[key] { return cached }
        let points = stride(from: 0.0, to: 360, by: 5).map { degrees -> Chromaticity in
            let a = degrees * .pi / 180
            var lo = 0.0, hi = 0.03
            for _ in 0..<32 {
                let m = (lo + hi) / 2
                error(Chromaticity(x: D65.x + m * cos(a), y: D65.y + m * sin(a)), metric: metric) < limit ? (lo = m) : (hi = m)
            }
            return Chromaticity(x: D65.x + lo * cos(a), y: D65.y + lo * sin(a))
        }
        contours[key] = points
        return points
    }
}

extension ExperimentRecord {
    /// Ambient-subtracted baseline white, then each verified pass.
    var whiteTrajectory: [Chromaticity] {
        let black = measurements.first { $0.request.phase == "black" }?.mean ?? .zero
        let white = measurements.first { $0.request.phase == "white" }?.subtracting(black)
        return ([white].compactMap { $0 } + passes.map(\.measured)).compactMap(\.chromaticity)
    }
}
