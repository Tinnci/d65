// Renders D65's app icons and colour assets into both asset catalogs, plus the README icon,
// banner (light and dark) and GitHub social preview in docs/images.
//
//   swift scripts/make-icons.swift
//
// The mark is the product's ring-and-dot glyph: a held white point. Behind it runs a short arc of
// the Planckian locus, cool at the lower left and warm at the upper right, passing through the dot
// where it turns neutral. Surfaces are equal-RGB greys, as in the apps.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

typealias RGB = (r: CGFloat, g: CGFloat, b: CGFloat)

struct Palette {
    var backgroundTop: RGB
    var backgroundBottom: RGB
    var ink: RGB
    var cool: RGB
    var neutral: RGB
    var warm: RGB
    var opaque: Bool

    static let light = Palette(backgroundTop: (0.975, 0.975, 0.975), backgroundBottom: (0.855, 0.855, 0.855),
                               ink: (0.086, 0.086, 0.086), cool: (0.36, 0.53, 0.88), neutral: (0.70, 0.70, 0.70),
                               warm: (0.93, 0.60, 0.29), opaque: true)
    static let dark = Palette(backgroundTop: (0.20, 0.20, 0.20), backgroundBottom: (0.075, 0.075, 0.075),
                              ink: (0.93, 0.93, 0.93), cool: (0.47, 0.64, 0.96), neutral: (0.45, 0.45, 0.45),
                              warm: (0.97, 0.69, 0.40), opaque: true)
    /// iOS tints a greyscale icon itself; keep it monochrome and let the system colour it.
    static let tinted = Palette(backgroundTop: (0, 0, 0), backgroundBottom: (0, 0, 0),
                                ink: (1, 1, 1), cool: (0.42, 0.42, 0.42), neutral: (0.42, 0.42, 0.42),
                                warm: (0.42, 0.42, 0.42), opaque: true)
}

enum Shape { case fullBleed, macOS }

func render(size: Int, palette: Palette, shape: Shape) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: palette.opaque && shape == .fullBleed
                            ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(size) / 1024
    ctx.scaleBy(x: s, y: s)
    ctx.interpolationQuality = .high
    func color(_ c: RGB, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [c.r, c.g, c.b, a])! }

    // Body: full square for iOS (the system masks it), Big Sur grid tile with shadow for macOS.
    let body: CGRect
    let clip: CGPath
    switch shape {
    case .fullBleed:
        body = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        clip = CGPath(rect: body, transform: nil)
    case .macOS:
        body = CGRect(x: 100, y: 100, width: 824, height: 824)
        clip = CGPath(roundedRect: body, cornerWidth: 185.4, cornerHeight: 185.4, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color((0, 0, 0), 0.32))
        ctx.addPath(clip); ctx.setFillColor(color(palette.backgroundBottom)); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(clip); ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(palette.backgroundTop), color(palette.backgroundBottom)] as CFArray,
                                locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])

    // Mark geometry, scaled to the body so macOS and iOS read at the same visual weight.
    let k = body.width / 1024
    let centre = CGPoint(x: body.midX, y: body.midY)
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: centre.x + (x - 512) * k, y: centre.y + (y - 512) * k) }

    // Locus arc: quadratic through the centre at t = 0.5, bulging upward like the Planckian locus in xy.
    let start = p(70, 250), end = p(960, 520)
    let control = CGPoint(x: 2 * centre.x - (start.x + end.x) / 2, y: 2 * centre.y - (start.y + end.y) / 2)
    let arc = CGMutablePath()
    arc.move(to: start); arc.addQuadCurve(to: end, control: control)
    drawMark(ctx, centre: centre, k: k, arc: arc, from: start, to: end, bounds: body, palette: palette, space: space)
    ctx.restoreGState()

    // A hairline edge keeps the light macOS tile from dissolving into a light Dock.
    if shape == .macOS {
        // The dark tile gets a light edge so it doesn't dissolve into a dark page.
        let edge: CGColor = palette.ink.r > 0.5 ? color(palette.ink, 0.14) : color((0, 0, 0), 0.10)
        ctx.addPath(clip); ctx.setStrokeColor(edge); ctx.setLineWidth(2); ctx.strokePath()
    }
    return ctx.makeImage()!
}

/// The ring, the held dot, and a locus arc passing behind them with gaps around both.
/// Shared by the icons and the banner so the mark is drawn one way only.
func drawMark(_ ctx: CGContext, centre: CGPoint, k: CGFloat, arc: CGPath, from start: CGPoint, to end: CGPoint,
              bounds body: CGRect, palette: Palette, space: CGColorSpace, neutralAt: CGFloat = 0.5) {
    func color(_ c: RGB, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [c.r, c.g, c.b, a])! }
    // Gaps around the ring and the dot put the locus behind the mark, with the dot sitting on it.
    let ringRadius = 292 * k, ringWidth = 60 * k, dot = 104 * k, gap = 22 * k
    ctx.saveGState()
    let knockout = CGMutablePath()
    knockout.addRect(body)
    let outer = ringRadius + ringWidth / 2 + gap, inner = ringRadius - ringWidth / 2 - gap
    knockout.addEllipse(in: CGRect(x: centre.x - outer, y: centre.y - outer, width: outer * 2, height: outer * 2))
    knockout.addEllipse(in: CGRect(x: centre.x - inner, y: centre.y - inner, width: inner * 2, height: inner * 2))
    let around = dot + gap
    knockout.addEllipse(in: CGRect(x: centre.x - around, y: centre.y - around, width: around * 2, height: around * 2))
    ctx.addPath(knockout); ctx.clip(using: .evenOdd)
    ctx.addPath(arc)
    ctx.setLineWidth(26 * k); ctx.setLineCap(.round)
    ctx.replacePathWithStrokedPath(); ctx.clip()
    let locus = CGGradient(colorsSpace: space, colors: [color(palette.cool), color(palette.neutral), color(palette.warm)] as CFArray,
                           locations: [0, neutralAt, 1])!
    // Extend past the ends so the round caps take the end colours instead of being cut flat.
    ctx.drawLinearGradient(locus, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // Ring and held dot.
    ctx.setStrokeColor(color(palette.ink)); ctx.setLineWidth(ringWidth)
    ctx.strokeEllipse(in: CGRect(x: centre.x - ringRadius, y: centre.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
    ctx.setFillColor(color(palette.ink))
    ctx.fillEllipse(in: CGRect(x: centre.x - dot, y: centre.y - dot, width: dot * 2, height: dot * 2))
}

func write(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(url.path)") }
}

func writeJSON(_ object: Any, to url: URL) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: url)
}

func colorSet(_ name: String, in catalog: URL, light: RGB, dark: RGB) {
    let dir = catalog.appendingPathComponent("\(name).colorset")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func entry(_ c: RGB, dark: Bool) -> [String: Any] {
        var e: [String: Any] = ["idiom": "universal", "color": ["color-space": "srgb", "components": [
            "red": String(format: "%.3f", c.r), "green": String(format: "%.3f", c.g),
            "blue": String(format: "%.3f", c.b), "alpha": "1.000"]]]
        if dark { e["appearances"] = [["appearance": "luminosity", "value": "dark"]] }
        return e
    }
    writeJSON(["colors": [entry(light, dark: false), entry(dark, dark: true)], "info": ["author": "xcode", "version": 1]],
              to: dir.appendingPathComponent("Contents.json"))
}

func catalog(_ path: String) -> URL {
    // Only the icon and colour sets below are rewritten; anything else in the catalog is left alone.
    let url = URL(fileURLWithPath: path)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    writeJSON(["info": ["author": "xcode", "version": 1]], to: url.appendingPathComponent("Contents.json"))
    return url
}

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
// Accent tokens shared with Theme.swift / ProbeTheme.
let accentLight: RGB = (0.12, 0.34, 0.66), accentDark: RGB = (0.55, 0.71, 0.93)

// macOS: every size the Dock, Finder and Spotlight ask for.
let mac = catalog(root.appendingPathComponent("Apps/D65Mac/Assets.xcassets").path)
let macIcon = mac.appendingPathComponent("AppIcon.appiconset")
try? FileManager.default.removeItem(at: macIcon)
try! FileManager.default.createDirectory(at: macIcon, withIntermediateDirectories: true)
var macImages: [[String: Any]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        write(render(size: points * scale, palette: .light, shape: .macOS), to: macIcon.appendingPathComponent(name))
        macImages.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
writeJSON(["images": macImages, "info": ["author": "xcode", "version": 1]], to: macIcon.appendingPathComponent("Contents.json"))
colorSet("AccentColor", in: mac, light: accentLight, dark: accentDark)

// iOS: one 1024 master per appearance; the system masks and scales it.
let ios = catalog(root.appendingPathComponent("Apps/D65Probe/Assets.xcassets").path)
let iosIcon = ios.appendingPathComponent("AppIcon.appiconset")
try? FileManager.default.removeItem(at: iosIcon)
try! FileManager.default.createDirectory(at: iosIcon, withIntermediateDirectories: true)
var iosImages: [[String: Any]] = []
for (name, palette, appearance) in [("icon.png", Palette.light, nil), ("icon-dark.png", .dark, "dark"), ("icon-tinted.png", .tinted, "tinted")] as [(String, Palette, String?)] {
    write(render(size: 1024, palette: palette, shape: .fullBleed), to: iosIcon.appendingPathComponent(name))
    var entry: [String: Any] = ["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": name]
    if let appearance { entry["appearances"] = [["appearance": "luminosity", "value": appearance]] }
    iosImages.append(entry)
}
writeJSON(["images": iosImages, "info": ["author": "xcode", "version": 1]], to: iosIcon.appendingPathComponent("Contents.json"))
colorSet("AccentColor", in: ios, light: accentLight, dark: accentDark)
// Launch matches the probe's first screen: system background, no logo flash.
colorSet("LaunchBackground", in: ios, light: (1, 1, 1), dark: (0, 0, 0))

// README header: the macOS tile in both palettes, chosen by GitHub's theme through <picture>.
let readmeImages = root.appendingPathComponent("docs/images")
try! FileManager.default.createDirectory(at: readmeImages, withIntermediateDirectories: true)
write(render(size: 512, palette: .light, shape: .macOS), to: readmeImages.appendingPathComponent("icon-light.png"))
write(render(size: 512, palette: .dark, shape: .macOS), to: readmeImages.appendingPathComponent("icon-dark.png"))


/// A wide lockup: the mark on the left, the locus arc continuing across the whole banner like a
/// horizon, and the wordmark with its tagline beneath the arc. Drawn at 2× in points.
struct BannerLayout {
    var size: CGSize
    var markCentre: CGPoint
    var k: CGFloat
    /// The arc passes through these points (Catmull-Rom); one of them is the mark's centre.
    var arcPoints: [CGPoint]
    var wordmarkOrigin: CGPoint
    var wordmarkSize: CGFloat
    var taglineLines: [String]
    var taglineSize: CGFloat
    var radius: CGFloat
}

func banner(_ layout: BannerLayout, palette: Palette) -> CGImage {
    let scale: CGFloat = 2
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(layout.size.width * scale), height: Int(layout.size.height * scale),
                        bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    func color(_ c: RGB, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [c.r, c.g, c.b, a])! }
    let body = CGRect(origin: .zero, size: layout.size)
    let clip = CGPath(roundedRect: body.insetBy(dx: 1, dy: 1), cornerWidth: layout.radius, cornerHeight: layout.radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(clip); ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(palette.backgroundTop), color(palette.backgroundBottom)] as CFArray,
                                locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

    // Catmull-Rom through the arc points, as cubic segments.
    let pts = layout.arcPoints
    let arc = CGMutablePath()
    arc.move(to: pts[0])
    for i in 0..<(pts.count - 1) {
        let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
        arc.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                     control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
    }
    let start = pts.first!, end = pts.last!
    let neutralAt = (layout.markCentre.x - start.x) / (end.x - start.x)
    drawMark(ctx, centre: layout.markCentre, k: layout.k, arc: arc, from: start, to: end, bounds: body,
             palette: palette, space: space, neutralAt: neutralAt)

    // Wordmark and tagline, in the system face.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let ink = NSColor(srgbRed: palette.ink.r, green: palette.ink.g, blue: palette.ink.b, alpha: 1)
    let word = NSAttributedString(string: "D65", attributes: [
        .font: NSFont.systemFont(ofSize: layout.wordmarkSize, weight: .heavy),
        .foregroundColor: ink, .kern: -layout.wordmarkSize * 0.02])
    word.draw(at: layout.wordmarkOrigin)
    var y = layout.wordmarkOrigin.y - layout.taglineSize * 1.15
    for line in layout.taglineLines {
        NSAttributedString(string: line, attributes: [
            .font: NSFont.systemFont(ofSize: layout.taglineSize, weight: .medium),
            .foregroundColor: ink.withAlphaComponent(0.62)]).draw(at: CGPoint(x: layout.wordmarkOrigin.x + 4, y: y))
        y -= layout.taglineSize * 1.35
    }
    NSGraphicsContext.restoreGraphicsState()
    ctx.restoreGState()

    // Rounded banners get the tiles' hairline edge; the square social preview is cropped by GitHub.
    if layout.radius > 0 {
        let edge: CGColor = palette.ink.r > 0.5 ? color(palette.ink, 0.14) : color((0, 0, 0), 0.10)
        ctx.addPath(clip); ctx.setStrokeColor(edge); ctx.setLineWidth(1); ctx.strokePath()
    }
    return ctx.makeImage()!
}

let tagline = ["White-point balance for external displays,", "measured with an iPhone."]
let readmeBanner = BannerLayout(
    size: CGSize(width: 1280, height: 400), markCentre: CGPoint(x: 250, y: 200), k: 0.40,
    arcPoints: [CGPoint(x: -30, y: 40), CGPoint(x: 250, y: 200), CGPoint(x: 700, y: 345), CGPoint(x: 1320, y: 368)],
    wordmarkOrigin: CGPoint(x: 470, y: 142), wordmarkSize: 128, taglineLines: tagline, taglineSize: 28, radius: 24)
// GitHub's social preview is 1280×640.
let socialPreview = BannerLayout(
    size: CGSize(width: 1280, height: 640), markCentre: CGPoint(x: 300, y: 300), k: 0.52,
    arcPoints: [CGPoint(x: -30, y: 90), CGPoint(x: 300, y: 300), CGPoint(x: 760, y: 470), CGPoint(x: 1320, y: 515)],
    wordmarkOrigin: CGPoint(x: 590, y: 250), wordmarkSize: 168, taglineLines: tagline, taglineSize: 34, radius: 0)
write(banner(readmeBanner, palette: .light), to: readmeImages.appendingPathComponent("banner-light.png"))
write(banner(readmeBanner, palette: .dark), to: readmeImages.appendingPathComponent("banner-dark.png"))
write(banner(socialPreview, palette: .light), to: readmeImages.appendingPathComponent("social-preview.png"))

// A side-by-side preview for review, not shipped.
if let previewPath = CommandLine.arguments.dropFirst(2).first {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: 2200, height: 820, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(colorSpace: space, components: [0.5, 0.5, 0.5, 1])!)
    ctx.fill(CGRect(x: 0, y: 0, width: 2200, height: 820))
    let tiles: [(CGImage, CGRect)] = [
        (render(size: 700, palette: .light, shape: .macOS), CGRect(x: 40, y: 60, width: 700, height: 700)),
        (render(size: 512, palette: .light, shape: .fullBleed), CGRect(x: 800, y: 154, width: 512, height: 512)),
        (render(size: 512, palette: .dark, shape: .fullBleed), CGRect(x: 1352, y: 154, width: 512, height: 512)),
        (render(size: 64, palette: .light, shape: .macOS), CGRect(x: 1920, y: 400, width: 64, height: 64)),
        (render(size: 32, palette: .light, shape: .macOS), CGRect(x: 2010, y: 416, width: 32, height: 32)),
        (render(size: 16, palette: .light, shape: .macOS), CGRect(x: 2070, y: 424, width: 16, height: 16)),
    ]
    for (index, (image, rect)) in tiles.enumerated() {
        if index == 1 || index == 2 {
            // iOS mask preview: continuous-corner approximation at 22.37 % radius.
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.width * 0.2237, cornerHeight: rect.width * 0.2237, transform: nil))
            ctx.clip(); ctx.draw(image, in: rect); ctx.restoreGState()
        } else { ctx.draw(image, in: rect) }
    }
    write(ctx.makeImage()!, to: URL(fileURLWithPath: previewPath))
}
print("icons written")
