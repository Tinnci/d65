import SwiftUI

// First-run guide. The figures follow the icon's own parts: the ring, the held dot and the locus arc,
// drawn as line figures after hairline's rules (github.com/lucasmarkes/hairline): strokes only, one
// bright highlight, plates opaque in the ground colour and painted back to front, a composed rest
// pose, stagger by distance, a 700 ms ease for discrete changes and a spring for a following finger,
// no words inside a figure, and nothing running while a page is offscreen or Reduce Motion is on.

// MARK: Tokens

/// Hairline's grey scale, plus the icon's locus colours. Bright is the only highlight.
struct LineInk {
    let scheme: ColorScheme
    var hi: Color { scheme == .dark ? Color(white: 0.95) : Color(white: 0.08) }
    var edge: Color { scheme == .dark ? Color(white: 0.62) : Color(white: 0.38) }
    var mid: Color { scheme == .dark ? Color(white: 0.42) : Color(white: 0.6) }
    var lo: Color { scheme == .dark ? Color(white: 0.26) : Color(white: 0.8) }
    var plate: Color { Color(.systemBackground) }
    var cool: Color { scheme == .dark ? Color(red: 0.47, green: 0.64, blue: 0.96) : Color(red: 0.36, green: 0.53, blue: 0.88) }
    var neutral: Color { scheme == .dark ? Color(white: 0.45) : Color(white: 0.7) }
    var warm: Color { scheme == .dark ? Color(red: 0.97, green: 0.69, blue: 0.40) : Color(red: 0.93, green: 0.60, blue: 0.29) }
}

/// Hairline's two clocks.
enum LineClock {
    /// A discrete change: 700 ms on (.32, .72, 0, 1).
    static func ease(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        // Solve the cubic Bézier for x = t, then return y.
        var u = t
        for _ in 0..<8 {
            let x = 3 * (1 - u) * (1 - u) * u * 0.32 + 3 * (1 - u) * u * u * 0 + u * u * u - t
            let dx = 3 * (1 - u) * (1 - u) * 0.32 + 6 * (1 - u) * u * (0 - 0.32) + 3 * u * u * (1 - 0)
            if abs(dx) < 1e-6 { break }
            u = min(max(u - x / dx, 0), 1)
        }
        return 3 * (1 - u) * (1 - u) * u * 0.72 + 3 * (1 - u) * u * u * 1 + u * u * u
    }
    static let duration = 0.7
}

/// A continuous input follows a spring: k 100, c 18, m 1.
struct LineSpring {
    var x: Double, v = 0.0, target: Double
    init(_ value: Double) { x = value; target = value }
    mutating func step(_ dt: Double) {
        let dt = min(dt, 1.0 / 30)
        let a = 100 * (target - x) - 18 * v
        v += a * dt; x += v * dt
    }
    var settled: Bool { abs(target - x) < 0.0005 && abs(v) < 0.001 }
}

// MARK: Projection

/// The 2:1 isometric view (azimuth 45°, elevation ratio .5) on a 400 × 320 frame.
struct Iso {
    var scale: CGFloat, origin: CGPoint
    init(size: CGSize, scale: CGFloat = 1.6, centre: CGPoint = CGPoint(x: 200, y: 166)) {
        let s = min(size.width / 400, size.height / 320)
        self.scale = scale * s
        origin = CGPoint(x: size.width / 2 + (centre.x - 200) * s, y: size.height / 2 + (centre.y - 160) * s)
    }
    func p(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
        CGPoint(x: origin.x + CGFloat((x - y) * 0.7071) * scale,
                y: origin.y + CGFloat((x + y) * 0.3536 - z) * scale)
    }
}

/// A rounded rectangle's outline in local plane coordinates (a, b).
func roundedRing(_ a0: Double, _ b0: Double, _ a1: Double, _ b1: Double, r: Double, steps: Int = 6) -> [(Double, Double)] {
    let r = min(r, (a1 - a0) / 2, (b1 - b0) / 2)
    let corners = [(a1 - r, b0 + r, -90.0), (a1 - r, b1 - r, 0.0), (a0 + r, b1 - r, 90.0), (a0 + r, b0 + r, 180.0)]
    var points: [(Double, Double)] = []
    for (ca, cb, start) in corners {
        for i in 0...steps {
            let angle = (start + 90 * Double(i) / Double(steps)) * .pi / 180
            points.append((ca + r * cos(angle), cb + r * sin(angle)))
        }
    }
    return points
}

/// Monotone-chain convex hull, for a plate's silhouette.
func hull(_ points: [CGPoint]) -> [CGPoint] {
    let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
    func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
    var lower: [CGPoint] = [], upper: [CGPoint] = []
    for p in sorted { while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }; lower.append(p) }
    for p in sorted.reversed() { while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }; upper.append(p) }
    return Array(lower.dropLast() + upper.dropLast())
}

func polygon(_ points: [CGPoint], closed: Bool = true) -> Path {
    var path = Path()
    guard let first = points.first else { return path }
    path.move(to: first)
    for p in points.dropFirst() { path.addLine(to: p) }
    if closed { path.closeSubpath() }
    return path
}

/// A thin solid: silhouette (the hull of its two faces) and one dim crease inset on the facing face.
struct Plate {
    let silhouette: Path, crease: Path, face: Path
    /// `map(a, b, d)` places a plane point at depth d (0 = back face, 1 = front face).
    init(ring: [(Double, Double)], inset: [(Double, Double)], map: (Double, Double, Double) -> CGPoint) {
        let back = ring.map { map($0.0, $0.1, 0) }, front = ring.map { map($0.0, $0.1, 1) }
        silhouette = polygon(hull(back + front))
        face = polygon(front)
        crease = polygon(inset.map { map($0.0, $0.1, 1) })
    }
    func draw(_ context: GraphicsContext, _ ink: LineInk, bright: Bool = false) {
        context.fill(silhouette, with: .color(ink.plate))
        context.stroke(silhouette, with: .color(bright ? ink.hi : ink.edge), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
        context.stroke(crease, with: .color(ink.lo), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
    }
}

// MARK: Figures

/// One clock per figure page: runs only while the page is shown and something moves.
private struct FigureCanvas: View {
    let active: Bool
    let draw: (inout GraphicsContext, CGSize, Double, LineInk) -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !active || reduceMotion)) { timeline in
            Canvas { context, size in
                // Under Reduce Motion every figure holds its composed rest pose.
                let t = reduceMotion ? 1000 : timeline.date.timeIntervalSince(start)
                draw(&context, size, t, LineInk(scheme: scheme))
            }
        }
        .aspectRatio(5.0 / 4.0, contentMode: .fit)
        .onChange(of: active) { _, now in if now { start = Date() } }
        .accessibilityHidden(true)
    }
}

/// The ring and the held dot on the screen of a display, with the locus arc behind them.
/// `held` 0…1 moves the dot along the arc onto the centre; when it arrives the ring turns bright.
private func drawMark(_ context: GraphicsContext, ink: LineInk, centre: (Double, Double), radius: Double, held: Double,
                      onPlane map: @escaping (Double, Double) -> CGPoint) {
    func ellipse(_ r: Double, _ c: (Double, Double)) -> Path {
        polygon((0..<64).map { i in let a = Double(i) / 64 * 2 * .pi; return map(c.0 + r * cos(a), c.1 + r * sin(a)) })
    }
    // The arc: cool at the lower left, warm at the upper right, through the centre.
    let arcPoints = stride(from: -1.35, through: 1.35, by: 0.05).map { s -> (Double, Double) in
        (centre.0 + s * radius * 0.95, centre.1 + s * radius * 0.42 - s * s * radius * 0.12)
    }
    let arc = polygon(arcPoints.map(map), closed: false)
    let ends = (map(arcPoints.first!.0, arcPoints.first!.1), map(arcPoints.last!.0, arcPoints.last!.1))
    var behind = context
    // Gaps around the ring and the dot put the arc behind the mark, as in the icon.
    behind.clip(to: Path(CGRect(x: -10_000, y: -10_000, width: 20_000, height: 20_000))
        .subtracting(ellipse(radius * 1.14, centre).subtracting(ellipse(radius * 0.86, centre)))
        .subtracting(ellipse(radius * 0.48, centre)))
    behind.stroke(arc, with: .linearGradient(Gradient(colors: [ink.cool, ink.neutral, ink.warm]), startPoint: ends.0, endPoint: ends.1),
                  style: StrokeStyle(lineWidth: 3, lineCap: .round))
    context.stroke(ellipse(radius, centre), with: .color(held >= 0.98 ? ink.hi : ink.edge), lineWidth: 3)
    // The dot travels along the arc from the cool side to the centre (s = 0).
    let s = -0.85 * (1 - held)
    let dot = (centre.0 + s * radius * 0.95, centre.1 + s * radius * 0.42 - s * s * radius * 0.12)
    context.fill(ellipse(radius * 0.3, dot), with: .color(held >= 0.98 ? ink.hi : ink.edge))
}

/// The icon's mark, face-on and in the icon's proportions (ring 292, width 60, dot 104, gap 22 on a
/// 1024 tile; the arc a quadratic through the centre). `held` moves the dot along the arc from the
/// cool side onto the centre; when it lands the ring takes the bright stroke.
func drawFrontMark(_ context: GraphicsContext, ink: LineInk, size: CGSize, held: Double, fill: Double = 0.36) {
    let k = min(size.width, size.height) * fill / 292
    let c = CGPoint(x: size.width / 2, y: size.height / 2)
    func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: c.x + CGFloat(x) * k, y: c.y + CGFloat(y) * k) }
    // The icon's arc, in y-down coordinates relative to the centre.
    let start = (-442.0, 262.0), end = (448.0, 8.0), control = (-3.0, -127.0)
    func arcPoint(_ t: Double) -> CGPoint {
        let u = 1 - t
        return p(u * u * start.0 + 2 * u * t * control.0 + t * t * end.0, u * u * start.1 + 2 * u * t * control.1 + t * t * end.1)
    }
    var arc = Path(); arc.move(to: arcPoint(0))
    for i in 1...64 { arc.addLine(to: arcPoint(Double(i) / 64)) }
    func circle(_ r: Double, at centre: CGPoint) -> Path {
        Path(ellipseIn: CGRect(x: centre.x - CGFloat(r) * k, y: centre.y - CGFloat(r) * k, width: CGFloat(2 * r) * k, height: CGFloat(2 * r) * k))
    }
    let ringR = 292.0, ringW = 60.0, dotR = 104.0, gap = 22.0
    let dotAt = arcPoint(0.5 - 0.32 * (1 - held))
    var behind = context
    let mask = circle(ringR + ringW / 2 + gap, at: c).subtracting(circle(ringR - ringW / 2 - gap, at: c))
        .union(circle(dotR + gap, at: dotAt))
    behind.clip(to: Path(CGRect(origin: .zero, size: size)).subtracting(mask))
    behind.stroke(arc, with: .linearGradient(Gradient(stops: [.init(color: ink.cool, location: 0), .init(color: ink.neutral, location: 0.5),
                                                               .init(color: ink.warm, location: 1)]),
                                              startPoint: arcPoint(0), endPoint: arcPoint(1)),
                  style: StrokeStyle(lineWidth: CGFloat(26 * k), lineCap: .round))
    let lit = held >= 0.98
    context.stroke(circle(ringR, at: c), with: .color(lit ? ink.hi : ink.edge), lineWidth: CGFloat(ringW * k))
    context.fill(circle(dotR, at: dotAt), with: .color(lit ? ink.hi : ink.edge))
}

/// Page 1: a display, the mark on its screen; the dot settles onto D65.
struct DisplayFigure: View {
    let active: Bool
    var body: some View {
        FigureCanvas(active: active) { context, size, t, ink in
            let iso = Iso(size: size, scale: 1.3, centre: CGPoint(x: 200, y: 262))
            // Back to front: foot, neck, screen, mark.
            Plate(ring: roundedRing(-42, -26, 42, 26, r: 10), inset: roundedRing(-38, -22, 38, 22, r: 8)) { a, b, d in
                iso.p(a, b, d * 4)
            }.draw(context, ink)
            Plate(ring: roundedRing(-9, 0, 9, 46, r: 4), inset: []) { a, b, d in iso.p(a, -2 + d * 4, b) }.draw(context, ink)
            let screen = { (a: Double, b: Double, d: Double) in iso.p(a, -6 + d * 8, b) }
            Plate(ring: roundedRing(-96, 34, 96, 150, r: 8), inset: roundedRing(-90, 40, 90, 144, r: 5), map: screen).draw(context, ink)
            let cycle = t.truncatingRemainder(dividingBy: 4.2)
            let held = cycle < 1.2 ? 0 : LineClock.ease((cycle - 1.2) / LineClock.duration)
            drawMark(context, ink: ink, centre: (0, 92), radius: 34, held: t > 999 ? 1 : held) { a, b in screen(a, b, 1) }
        }
    }
}

/// Page 2: the phone comes face-down onto the outline; its sensor edge is the bright mark.
struct PlaceFigure: View {
    let active: Bool
    var body: some View {
        FigureCanvas(active: active) { context, size, t, ink in
            let iso = Iso(size: size, scale: 1.3, centre: CGPoint(x: 200, y: 262))
            let screen = { (a: Double, b: Double, d: Double) in iso.p(a, -6 + d * 8, b) }
            Plate(ring: roundedRing(-96, 34, 96, 150, r: 8), inset: roundedRing(-90, 40, 90, 144, r: 5), map: screen).draw(context, ink)
            // The outline: a dashed guide painted on the screen, behind the phone.
            let outline = polygon(roundedRing(-17, 56, 17, 128, r: 7).map { screen($0.0, $0.1, 1) })
            context.stroke(outline, with: .color(ink.mid), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            // The phone approaches, then rests on the glass (a discrete change: the 700 ms ease).
            let cycle = t.truncatingRemainder(dividingBy: 4.0)
            let approach = t > 999 ? 1 : LineClock.ease((cycle - 0.6) / LineClock.duration)
            let gap = 70 * (1 - approach) + 2
            let phone = { (a: Double, b: Double, d: Double) in iso.p(a, 2 + gap + d * 6, b) }
            let ring = roundedRing(-15, 58, 15, 126, r: 7)
            Plate(ring: ring, inset: roundedRing(-12, 61, 12, 123, r: 5), map: phone).draw(context, ink)
            // The sensor sits at the top edge, facing the screen: the one bright mark.
            let sensor = polygon([phone(-5, 120, 0), phone(5, 120, 0)], closed: false)
            context.stroke(sensor, with: .color(ink.hi), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }
}

/// Page 3: twelve patches; the one being measured lifts and is lit, its neighbours follow by distance.
struct PatchesFigure: View {
    let active: Bool
    @State private var touched: Int?
    private static let colours: [(Double, Double, Double)] = [
        (0, 0, 0), (1, 1, 1), (1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0),
        (0, 1, 1), (1, 0, 1), (0.2, 0.2, 0.2), (0.4, 0.4, 0.4), (0.6, 0.6, 0.6), (0.8, 0.8, 0.8),
    ]
    var body: some View {
        GeometryReader { geometry in
            FigureCanvas(active: active) { context, size, t, ink in
                Self.draw(context, size: size, t: t, ink: ink, touched: touched)
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in touched = Self.tile(at: value.location, in: geometry.size) }
                .onEnded { _ in touched = nil })
        }
        .aspectRatio(5.0 / 4.0, contentMode: .fit)
    }

    private static func draw(_ context: GraphicsContext, size: CGSize, t: Double, ink: LineInk, touched: Int?) {
        let iso = Iso(size: size, scale: 1.6, centre: CGPoint(x: 200, y: 180))
        let current: Int = touched ?? (t > 999 ? 4 : Int(t / 0.9) % 12)
        let since: Double = touched == nil ? t.truncatingRemainder(dividingBy: 0.9) : 1
        // Four by three tiles on the ground, painted far to near.
        let order: [Int] = (0..<12).sorted { tilePosition($0).sum < tilePosition($1).sum }
        for i in order {
            let (x, y, _) = tilePosition(i)
            let distance = Double(abs(i - current))
            // Stagger by distance (45 ms a step); rest is a gentle dune, never flat.
            let progress: Double = LineClock.ease((since - distance * 0.045) / LineClock.duration)
            let lift: Double = (1 - min(distance / 3, 1)) * 12 * progress
            let z: Double = 3 + 1.5 * sin(Double(i) * 1.7) + lift
            let plate = Plate(ring: roundedRing(x - 15, y - 15, x + 15, y + 15, r: 5),
                              inset: roundedRing(x - 12, y - 12, x + 12, y + 12, r: 4)) { a, b, d in iso.p(a, b, z - 3 + d * 3) }
            plate.draw(context, ink, bright: i == current)
            guard i == current else { continue }
            let c = colours[i]
            context.fill(plate.face, with: .color(Color(.sRGB, red: c.0, green: c.1, blue: c.2)))
            context.stroke(plate.face, with: .color(ink.hi), lineWidth: 1.4)
        }
    }

    private static func tilePosition(_ i: Int) -> (Double, Double, sum: Double) {
        let x = Double(i % 4) * 46 - 69, y = Double(i / 4) * 46 - 46
        return (x, y, x + y)
    }

    /// Hit test against the tiles' rest pose, never the lifted one (no flicker loop).
    private static func tile(at point: CGPoint, in size: CGSize) -> Int {
        let iso = Iso(size: size, scale: 1.6, centre: CGPoint(x: 200, y: 180))
        return (0..<12).min { a, b in
            func distance(_ i: Int) -> CGFloat {
                let p = iso.p(Double(i % 4) * 46 - 69, Double(i / 4) * 46 - 46, 3)
                return hypot(p.x - point.x, p.y - point.y)
            }
            return distance(a) < distance(b)
        }!
    }
}

/// Page 4: the correction. Drag to move the white along the locus; let go and it springs back to D65.
struct CorrectionFigure: View {
    let active: Bool
    @State private var spring = LineSpring(0)
    @State private var dragging = false
    @State private var lastFrame = Date()
    var body: some View {
        GeometryReader { geometry in
            FigureCanvas(active: active) { context, size, t, ink in
                let autoplay = t > 999 ? 1 : LineClock.ease((t.truncatingRemainder(dividingBy: 3.6) - 1.0) / LineClock.duration)
                let held = dragging || spring.x != 0 ? 1 - min(max(spring.x, 0), 1) : autoplay
                drawFrontMark(context, ink: ink, size: size, held: held)
            }
            .onChange(of: dragging) { _, _ in lastFrame = Date() }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragging = true
                    // Distance from the centre, along the screen, sets how far from D65 the white is.
                    let dx = Double((value.location.x - geometry.size.width / 2) / (geometry.size.width / 3))
                    spring.target = min(max(abs(dx), 0), 1)
                    stepSpring()
                }
                .onEnded { _ in
                    dragging = false
                    spring.target = 0
                    settle()
                })
        }
        .aspectRatio(5.0 / 4.0, contentMode: .fit)
    }
    private func stepSpring() {
        let now = Date()
        spring.step(now.timeIntervalSince(lastFrame)); lastFrame = now
    }
    /// Let the spring land after the finger lifts; stops when it has settled.
    private func settle() {
        Task { @MainActor in
            lastFrame = Date()
            while !spring.settled && !dragging {
                try? await Task.sleep(for: .milliseconds(16))
                stepSpring()
            }
            if !dragging { spring = LineSpring(0) }
        }
    }
}

/// Page 5: the icon's mark, whole and held.
struct ReadyFigure: View {
    let active: Bool
    var body: some View {
        FigureCanvas(active: active) { context, size, _, ink in
            drawFrontMark(context, ink: ink, size: size, held: 1)
        }
    }
}

// MARK: The guide

struct OnboardingView: View {
    var onFinish: () -> Void
    @State private var page: Int
    init(startPage: Int = 0, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        _page = State(initialValue: startPage)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Page { let title: String; let text: String }
    private let pages = [
        Page(title: "Bring your display’s white to D65",
             text: "D65 measures the white of a monitor on your Mac and corrects it, a little at a time, until it matches daylight white."),
        Page(title: "Your iPhone is the sensor",
             text: "Its light sensor sits at the top edge, on the screen side. You’ll press that side flat onto an outline on the monitor."),
        Page(title: "Twelve patches, about 40 seconds",
             text: "The Mac shows each colour while the phone reads it. Keep the phone still; its own screen goes dark so it doesn’t add light."),
        Page(title: "Corrected toward D65, on your Mac",
             text: "The Mac moves the white along the colour-temperature curve and checks the result. You keep it or discard it there."),
        Page(title: "Ready when your Mac is",
             text: "Open D65 on your Mac and choose Calibrate Display. Allow Local Network when asked, so the two can find each other."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if page < pages.count - 1 { Button("Skip") { onFinish() }.foregroundStyle(.secondary) }
            }
            .frame(height: 44).padding(.horizontal, 24)

            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    VStack(spacing: 28) {
                        figure(index)
                            .frame(maxWidth: 360)
                            .padding(.horizontal, 12)
                        VStack(spacing: 10) {
                            Text(pages[index].title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                            Text(pages[index].text).font(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 32)
                        .accessibilityElement(children: .combine)
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(reduceMotion ? nil : .timingCurve(0.32, 0.72, 0, 1, duration: 0.7), value: page)
            .sensoryFeedback(.selection, trigger: page)

            PageDots(count: pages.count, current: page).padding(.bottom, 20)
            Button {
                if page < pages.count - 1 { page += 1 } else { onFinish() }
            } label: {
                Text(page < pages.count - 1 ? "Next" : "Get Started").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.horizontal, 32).padding(.bottom, 24)
        }
        .tint(ProbeTheme.accent)
    }

    @ViewBuilder private func figure(_ index: Int) -> some View {
        switch index {
        case 0: DisplayFigure(active: page == 0)
        case 1: PlaceFigure(active: page == 1)
        case 2: PatchesFigure(active: page == 2)
        case 3: CorrectionFigure(active: page == 3)
        default: ReadyFigure(active: page == 4)
        }
    }
}

/// Hairline-style dots: one bright, the rest dim.
private struct PageDots: View {
    let count: Int, current: Int
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Circle().fill(index == current ? Color.primary : Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}
