// Renders the README poster: what D65 does, how a calibration runs, and how the parts connect.
//
//   swift scripts/make-poster.swift        # writes docs/images/poster-{light,dark}.png
//
// Laid out in SwiftUI and rasterised with ImageRenderer at 2×. The icon is the rendered app icon
// (docs/images/icon-*.png from make-icons.swift); every number is from the code's defaults or the
// recorded K27 session (docs/experiments.md §14).
import AppKit
import SwiftUI

struct Palette {
    let dark: Bool
    var page: Color { dark ? Color(white: 0.075) : Color(white: 0.965) }
    var card: Color { dark ? Color(white: 0.12) : .white }
    var rule: Color { dark ? Color(white: 0.22) : Color(white: 0.86) }
    var ink: Color { dark ? Color(white: 0.93) : Color(white: 0.09) }
    var ink2: Color { dark ? Color(white: 0.68) : Color(white: 0.36) }
    var ink3: Color { dark ? Color(white: 0.5) : Color(white: 0.55) }
    var accent: Color { dark ? Color(red: 0.55, green: 0.71, blue: 0.93) : Color(red: 0.12, green: 0.34, blue: 0.66) }
    var ok: Color { dark ? Color(red: 0.42, green: 0.78, blue: 0.56) : Color(red: 0.17, green: 0.48, blue: 0.29) }
    var cool: Color { dark ? Color(red: 0.47, green: 0.64, blue: 0.96) : Color(red: 0.36, green: 0.53, blue: 0.88) }
    var warm: Color { dark ? Color(red: 0.97, green: 0.69, blue: 0.40) : Color(red: 0.93, green: 0.60, blue: 0.29) }
}

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)

struct Poster: View {
    let p: Palette
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            header
            locus
            label("How a calibration runs")
            VStack(spacing: 14) {
                Step(p: p, number: 1, title: "Place",
                     text: "The phone lies face-down on a life-size outline, its own screen dimmed to 1 %. Measuring starts once readings hold within 3 % for 1.5 s and the motion gate reports still.") { PlaceVisual(p: p) }
                Step(p: p, number: 2, title: "Measure",
                     text: "Twelve full-screen patches, 0.5 s to settle and 2 s of sampling each, outliers dropped around the median. Black gives the ambient light to subtract; four greys fit the panel’s gamma.") { PatchesVisual(p: p) }
                Step(p: p, number: 3, title: "Solve",
                     text: "The measured white is compared with D65 using CIEDE2000 at equal luminance. Gains come from the sRGB matrix and are scaled so the brightest channel stays at 1.") { SolveVisual(p: p) }
                Step(p: p, number: 4, title: "Apply and verify",
                     text: "Each gain scales the display’s gamma table as gain^(1/γ). White is measured again; up to three passes run, stopping at ΔE00 2 or when a pass improves by less than 0.3.") { PassesVisual(p: p) }
                Step(p: p, number: 5, title: "Keep",
                     text: "Review shows the result on the real display. Keep hands it to the menu-bar agent, which reapplies it when the display returns and flags it when contrast, preset or display mode change.") { KeepVisual(p: p) }
            }
            label("Where each part runs")
            architecture
            footer
        }
        .padding(56)
        .frame(width: 1200)
        .background(p.page)
    }

    var header: some View {
        HStack(alignment: .center, spacing: 28) {
            Image(nsImage: NSImage(contentsOf: root.appendingPathComponent("docs/images/icon-\(p.dark ? "dark" : "light").png"))!)
                .resizable().frame(width: 148, height: 148)
            VStack(alignment: .leading, spacing: 8) {
                Text("D65").font(.system(size: 72, weight: .heavy)).tracking(-1.5).foregroundStyle(p.ink)
                Text("White-point balance for external displays, measured with an iPhone.")
                    .font(.system(size: 24, weight: .semibold)).foregroundStyle(p.ink2)
            }
        }
    }

    /// The icon's arc, carried into the poster as a section rule: cool to warm, neutral at D65.
    var locus: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("It measures a display’s white with the iPhone’s ambient-light sensor, solves three channel gains toward D65, and holds them in the Mac’s gamma table. A quality gate refuses any correction that doesn’t measurably help.")
                .font(.system(size: 19)).foregroundStyle(p.ink).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            Capsule().fill(LinearGradient(colors: [p.cool, Color(white: p.dark ? 0.45 : 0.7), p.warm], startPoint: .leading, endPoint: .trailing))
                .frame(height: 6)
        }
    }

    func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 13, weight: .bold, design: .monospaced)).tracking(1.5)
            .foregroundStyle(p.accent)
    }

    var architecture: some View {
        HStack(alignment: .center, spacing: 0) {
            Device(p: p, symbol: "iphone", title: "iPhone · D65 Probe",
                   lines: ["Ambient-light sensor: X, Y, Z", "Motion gate for stillness", "Holds no colour maths"])
            Arrow(p: p, label: "XYZ samples\nBonjour, protocol v3")
            Device(p: p, symbol: "macbook", title: "Mac · D65",
                   lines: ["Patches, solver, quality gate", "A JSON record per session", "Menu-bar agent holds the result"])
            Arrow(p: p, label: "gamma table\nDDC/CI reads")
            Device(p: p, symbol: "display", title: "External display",
                   lines: ["Gains in the transfer table", "Contrast, preset, mode read back", "macOS reverts it when D65 quits"])
        }
    }

    var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("On a HAN K27 with an iPhone Air: ΔE00 4.18 → 1.69 in one pass, γ 2.11, 33 s.")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(p.ink)
                Text("The sensor is uncalibrated: results show convergence against it, not colorimeter accuracy.")
                    .font(.system(size: 14)).foregroundStyle(p.ink3)
            }
            Spacer()
            Text("github.com/Tinnci/d65").font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(p.ink2)
        }
        .padding(.top, 4)
    }
}

struct Step<Visual: View>: View {
    let p: Palette
    let number: Int
    let title: String
    let text: String
    @ViewBuilder var visual: Visual
    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            Text("\(number)").font(.system(size: 20, weight: .bold)).foregroundStyle(p.page)
                .frame(width: 40, height: 40).background(Circle().fill(p.ink))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(p.ink)
                Text(text).font(.system(size: 15.5)).foregroundStyle(p.ink2).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 520, alignment: .leading)
            Spacer(minLength: 0)
            visual.frame(width: 400, height: 120)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(p.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(p.rule))
    }
}

struct PlaceVisual: View {
    let p: Palette
    var body: some View {
        HStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.white).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(p.rule))
                RoundedRectangle(cornerRadius: 9).strokeBorder(Color(white: 0.4), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .frame(width: 34, height: 70)
            }
            .frame(width: 170, height: 104)
            VStack(alignment: .leading, spacing: 8) {
                Text("Steady 1.0 of 1.5 s").font(.system(size: 13, weight: .medium)).foregroundStyle(p.ink2)
                Capsule().fill(p.rule).frame(width: 180, height: 6)
                    .overlay(alignment: .leading) { Capsule().fill(p.ink2).frame(width: 120, height: 6) }
                Text("Y 141.9 · still").font(.system(size: 13, design: .monospaced)).foregroundStyle(p.ink3)
            }
        }
    }
}

struct PatchesVisual: View {
    let p: Palette
    let patches: [(String, Double, Double, Double)] = [
        ("black", 0, 0, 0), ("white", 1, 1, 1), ("red", 1, 0, 0), ("green", 0, 1, 0), ("blue", 0, 0, 1), ("yellow", 1, 1, 0),
        ("cyan", 0, 1, 1), ("magenta", 1, 0, 1), ("20", 0.2, 0.2, 0.2), ("40", 0.4, 0.4, 0.4), ("60", 0.6, 0.6, 0.6), ("80", 0.8, 0.8, 0.8),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(56), spacing: 8), count: 6), spacing: 8) {
                ForEach(patches.indices, id: \.self) { i in
                    let patch = patches[i]
                    RoundedRectangle(cornerRadius: 5).fill(Color(.sRGB, red: patch.1, green: patch.2, blue: patch.3))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(p.rule))
                        .frame(height: 34)
                }
            }
            HStack(spacing: 18) {
                Text("black → ambient").font(.system(size: 12.5, weight: .medium)).foregroundStyle(p.ink3)
                Spacer()
                Text("greys → γ 2.11").font(.system(size: 12.5, weight: .medium)).foregroundStyle(p.ink3)
            }
        }
        .frame(width: 384)
    }
}

struct SolveVisual: View {
    let p: Palette
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("gains = M⁻¹·D65 ÷ M⁻¹·white").font(.system(size: 17, weight: .semibold, design: .monospaced)).foregroundStyle(p.ink)
            Text("R 0.981   G 1.000   B 0.934").font(.system(size: 14, design: .monospaced)).foregroundStyle(p.ink2)
            HStack(spacing: 8) {
                Chip(p: p, text: "≤ 2.5: already fine")
                Chip(p: p, text: "> 5.0: refuse")
                Chip(p: p, text: "> 20 % dimmer: refuse")
            }
        }
    }
}

struct Chip: View {
    let p: Palette
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.ink2)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(p.page)).overlay(Capsule().strokeBorder(p.rule))
    }
}

/// ΔE00 before and after the recorded pass, against the target line.
struct PassesVisual: View {
    let p: Palette
    var body: some View {
        Canvas { context, size in
            // Values sit in their own right-hand column so they never cross the target line.
            let left: CGFloat = 70, right: CGFloat = 60, bottom = size.height - 18, top: CGFloat = 8, maxE = 5.0
            func x(_ e: Double) -> CGFloat { left + CGFloat(e / maxE) * (size.width - left - right) }
            let rows: [(String, Double, Color)] = [("start", 4.18, p.ink3), ("pass 1", 1.69, p.ok)]
            let rowHeight = (bottom - top) / CGFloat(rows.count)
            for (i, row) in rows.enumerated() {
                let y = top + CGFloat(i) * rowHeight + rowHeight * 0.22
                let bar = CGRect(x: left, y: y, width: x(row.1) - left, height: rowHeight * 0.5)
                context.fill(Path(roundedRect: bar, cornerRadius: 4), with: .color(row.2))
                context.draw(Text(row.0).font(.system(size: 13, weight: .medium)).foregroundStyle(p.ink2),
                             at: CGPoint(x: left - 10, y: bar.midY), anchor: .trailing)
                context.draw(Text(String(format: "%.2f", row.1)).font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(p.ink), at: CGPoint(x: size.width, y: bar.midY), anchor: .trailing)
            }
            var target = Path()
            target.move(to: CGPoint(x: x(2), y: top)); target.addLine(to: CGPoint(x: x(2), y: bottom))
            context.stroke(target, with: .color(p.accent), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            context.draw(Text("target ΔE00 2").font(.system(size: 12, weight: .medium)).foregroundStyle(p.accent),
                         at: CGPoint(x: x(2), y: bottom + 10), anchor: .center)
        }
    }
}

struct KeepVisual: View {
    let p: Palette
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().strokeBorder(p.ink2, lineWidth: 2).frame(width: 26, height: 26)
                    Circle().fill(p.ink).frame(width: 10, height: 10)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("K27").font(.system(size: 15, weight: .bold)).foregroundStyle(p.ink)
                    Text("Corrected · ΔE00 1.7").font(.system(size: 13)).foregroundStyle(p.ink2)
                }
                Spacer()
                Capsule().fill(p.accent).frame(width: 40, height: 22)
                    .overlay(alignment: .trailing) { Circle().fill(.white).frame(width: 18, height: 18).padding(2) }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(p.page))
            Text("guard: contrast 50 · preset 6500 K · mode 0").font(.system(size: 12.5, design: .monospaced)).foregroundStyle(p.ink3)
        }
        .frame(width: 360)
    }
}

struct Device: View {
    let p: Palette
    let symbol: String
    let title: String
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(p.accent)
                Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(p.ink)
            }
            ForEach(lines, id: \.self) { line in
                Text(line).font(.system(size: 14)).foregroundStyle(p.ink2)
            }
        }
        .padding(18)
        .frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(p.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(p.rule))
    }
}

struct Arrow: View {
    let p: Palette
    let label: String
    var body: some View {
        VStack(spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(p.ink3).multilineTextAlignment(.center)
            Image(systemName: "arrow.right").font(.system(size: 18, weight: .semibold)).foregroundStyle(p.ink3)
        }
        .frame(maxWidth: .infinity)
    }
}

@MainActor func render(dark: Bool) {
    let renderer = ImageRenderer(content: Poster(p: Palette(dark: dark)).environment(\.colorScheme, dark ? .dark : .light))
    renderer.scale = 2
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
        fatalError("poster did not render")
    }
    let url = root.appendingPathComponent("docs/images/poster-\(dark ? "dark" : "light").png")
    try! png.write(to: url)
    print(url.path, image.size)
}

MainActor.assumeIsolated {
    render(dark: false)
    render(dark: true)
}
