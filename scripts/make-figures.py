#!/usr/bin/env python3
"""Render the README figures as static SVGs, one light and one dark per figure.

    python3 scripts/make-figures.py            # writes docs/images/*.svg

Every plotted value comes from a recorded hardware session (docs/experiments.md §13 and §14);
the numbers below were extracted from those sessions' JSON records. The script recomputes
ΔE00 with the engine's metric (white normalised to Y = 1, CIEDE2000 against D65) and refuses
to draw if it disagrees with the recorded values.

Style: the apps' equal-RGB neutrals and accent, built with hairline axes. GitHub picks the
variant through <picture> and prefers-color-scheme. Series colours pass the dataviz validator
against GitHub's light (#ffffff) and dark (#0d1117) surfaces.
"""
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "docs", "images")

# Ambient-subtracted chromaticities and fits from the two recorded sessions.
SESSIONS = [
    {
        "key": "app", "label": "§14 · Mac app", "record": "05C682F6",
        "baseline": (0.30965, 0.32176), "passes": [(0.31083, 0.32594)],
        "recorded_dE": (4.181, 1.689), "gamma": 2.1077,
        "greys": {0.2: 0.0344, 0.4: 0.1424, 0.6: 0.3290, 0.8: 0.6162},
        "primaries": {"red": (0.62404, 0.34179), "green": (0.27250, 0.51609), "blue": (0.17117, 0.06162)},
    },
    {
        "key": "cli", "label": "§13 · CLI", "record": "A0E8B5AC",
        "baseline": (0.30915, 0.32094), "passes": [(0.31096, 0.32643)],
        "recorded_dE": (4.560, 1.397), "gamma": 2.1142,
        "greys": {0.2: 0.0339, 0.4: 0.1421, 0.6: 0.3295, 0.8: 0.6145},
    },
]

THEMES = {
    "light": {"surface": "#ffffff", "ink": "#1f1f1f", "ink2": "#5e5e5e", "ink3": "#8a8a8a",
              "grid": "#e8e8e8", "axis": "#c8c8c8", "app": "#1f56a8", "cli": "#c0601c", "target": "#1f1f1f"},
    "dark": {"surface": "#0d1117", "ink": "#e8e8e8", "ink2": "#a8a8a8", "ink3": "#7a7a7a",
             "grid": "#262626", "axis": "#3d3d3d", "app": "#4f88dc", "cli": "#cf7430", "target": "#e8e8e8"},
}
FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
D65 = (0.3127, 0.3290)


# ---------------------------------------------------------------- colour maths (mirrors D65Core)

def lab(x, y):
    X, Y, Z = x / y, 1.0, (1 - x - y) / y
    xn, zn = D65[0] / D65[1], (1 - D65[0] - D65[1]) / D65[1]
    f = lambda t: t ** (1 / 3) if t > 216 / 24389 else (24389 / 27 * t + 16) / 116
    fx, fy, fz = f(X / xn), f(Y), f(Z / zn)
    return 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)


def de00(a, b):
    (L1, a1, b1), (L2, a2, b2) = a, b
    C1, C2 = math.hypot(a1, b1), math.hypot(a2, b2)
    Cb = (C1 + C2) / 2
    G = 0.5 * (1 - math.sqrt(Cb ** 7 / (Cb ** 7 + 25 ** 7)))
    ap1, ap2 = (1 + G) * a1, (1 + G) * a2
    Cp1, Cp2 = math.hypot(ap1, b1), math.hypot(ap2, b2)
    h = lambda bb, ap: 0.0 if bb == 0 and ap == 0 else math.degrees(math.atan2(bb, ap)) % 360
    hp1, hp2 = h(b1, ap1), h(b2, ap2)
    dL, dC = L2 - L1, Cp2 - Cp1
    dh = 0.0
    if Cp1 * Cp2:
        dh = hp2 - hp1
        dh = dh - 360 if dh > 180 else dh + 360 if dh < -180 else dh
    dH = 2 * math.sqrt(Cp1 * Cp2) * math.sin(math.radians(dh / 2))
    Lb, Cbp = (L1 + L2) / 2, (Cp1 + Cp2) / 2
    hb = hp1 + hp2
    if Cp1 * Cp2:
        hb = ((hp1 + hp2 + 360) / 2 if hp1 + hp2 < 360 else (hp1 + hp2 - 360) / 2) if abs(hp1 - hp2) > 180 else (hp1 + hp2) / 2
    T = (1 - 0.17 * math.cos(math.radians(hb - 30)) + 0.24 * math.cos(math.radians(2 * hb))
         + 0.32 * math.cos(math.radians(3 * hb + 6)) - 0.20 * math.cos(math.radians(4 * hb - 63)))
    dT = 30 * math.exp(-(((hb - 275) / 25) ** 2))
    Rc = 2 * math.sqrt(Cbp ** 7 / (Cbp ** 7 + 25 ** 7))
    Sl = 1 + 0.015 * (Lb - 50) ** 2 / math.sqrt(20 + (Lb - 50) ** 2)
    Sc, Sh = 1 + 0.045 * Cbp, 1 + 0.015 * Cbp * T
    Rt = -math.sin(math.radians(2 * dT)) * Rc
    return math.sqrt((dL / Sl) ** 2 + (dC / Sc) ** 2 + (dH / Sh) ** 2 + Rt * (dC / Sc) * (dH / Sh))


def white_error(p):
    return de00(lab(*p), lab(*D65))


def planck(t):
    """Kim et al. cubic approximation of the Planckian locus, 4000–25000 K."""
    x = -3.0258469e9 / t ** 3 + 2.1070379e6 / t ** 2 + 0.2226347e3 / t + 0.240390
    return x, 3.0817580 * x ** 3 - 5.87338670 * x ** 2 + 3.75112997 * x - 0.37001483


def mccamy(p):
    n = (p[0] - 0.3320) / (0.1858 - p[1])
    return 449 * n ** 3 + 3525 * n ** 2 + 6823.3 * n + 5520.33


def contour(limit, steps=120):
    points = []
    for i in range(steps):
        a = 2 * math.pi * i / steps
        lo, hi = 0.0, 0.05
        for _ in range(40):
            m = (lo + hi) / 2
            if white_error((D65[0] + m * math.cos(a), D65[1] + m * math.sin(a))) < limit:
                lo = m
            else:
                hi = m
        points.append((D65[0] + lo * math.cos(a), D65[1] + lo * math.sin(a)))
    return points


def check_against_records():
    for s in SESSIONS:
        got = (white_error(s["baseline"]), white_error(s["passes"][-1]))
        for value, recorded in zip(got, s["recorded_dE"]):
            if abs(value - recorded) > 0.01:
                sys.exit(f"ΔE00 mismatch for {s['label']}: computed {value:.3f}, recorded {recorded:.3f}")


# ---------------------------------------------------------------- SVG helpers

class SVG:
    def __init__(self, width, height, theme, title, desc):
        self.w, self.h, self.t = width, height, THEMES[theme]
        self.parts = [
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" '
            f'role="img" aria-labelledby="t d" font-family="{FONT}" style="font-variant-numeric: tabular-nums">',
            f'<title id="t">{title}</title><desc id="d">{desc}</desc>',
            f'<rect width="{width}" height="{height}" rx="8" fill="{self.t["surface"]}"/>',
        ]

    def add(self, s):
        self.parts.append(s)

    def text(self, x, y, s, size=12, color="ink2", anchor="start", weight=400, extra=""):
        self.add(f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" fill="{self.t.get(color, color)}" '
                 f'text-anchor="{anchor}" font-weight="{weight}" {extra}>{s}</text>')

    def line(self, x1, y1, x2, y2, color="axis", width=1, dash=None):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.add(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" stroke="{self.t.get(color, color)}" '
                 f'stroke-width="{width}"{d}/>')

    def path(self, points, color, width=1, dash=None, close=False, fill="none"):
        d = "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in points) + (" Z" if close else "")
        dash = f' stroke-dasharray="{dash}"' if dash else ""
        self.add(f'<path d="{d}" fill="{fill}" stroke="{self.t.get(color, color)}" stroke-width="{width}" '
                 f'stroke-linejoin="round" stroke-linecap="round"{dash}/>')

    def dot(self, x, y, color, r=4.5, hollow=False):
        c = self.t.get(color, color)
        # 2px surface ring keeps overlapping marks separable.
        self.add(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r + 2}" fill="{self.t["surface"]}"/>')
        if hollow:
            self.add(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r - 1}" fill="{self.t["surface"]}" stroke="{c}" stroke-width="2"/>')
        else:
            self.add(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r}" fill="{c}"/>')

    def target(self, x, y):
        c = self.t["target"]
        self.add(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="9" fill="{self.t["surface"]}" stroke="{c}" stroke-width="2"/>')
        self.add(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="3.5" fill="{c}"/>')

    def header(self, title, subtitle):
        self.text(24, 34, title, size=15, color="ink", weight=600)
        self.text(24, 54, subtitle, size=12, color="ink2")

    def legend(self, x, y, entries):
        for label, color, hollow in entries:
            self.dot(x + 5, y - 4, color, r=4, hollow=hollow)
            self.text(x + 16, y, label, size=12, color="ink2")
            x += 24 + len(label) * 6.6

    def save(self, name):
        self.add("</svg>")
        with open(os.path.join(OUT, name), "w") as f:
            f.write("\n".join(self.parts) + "\n")


class Frame:
    """A plot area with linear scales."""

    def __init__(self, svg, left, top, width, height, xr, yr):
        self.svg, self.l, self.tp, self.w, self.h, self.xr, self.yr = svg, left, top, width, height, xr, yr

    def x(self, v):
        return self.l + (v - self.xr[0]) / (self.xr[1] - self.xr[0]) * self.w

    def y(self, v):
        return self.tp + self.h - (v - self.yr[0]) / (self.yr[1] - self.yr[0]) * self.h

    def p(self, pt):
        return self.x(pt[0]), self.y(pt[1])

    def grid(self, xticks, yticks, xfmt, yfmt, xlabel, ylabel, xlabel_below=False):
        s = self.svg
        for v in xticks:
            s.line(self.x(v), self.tp, self.x(v), self.tp + self.h, color="grid")
            s.text(self.x(v), self.tp + self.h + 18, xfmt(v), size=11, color="ink3", anchor="middle")
        for v in yticks:
            s.line(self.l, self.y(v), self.l + self.w, self.y(v), color="grid")
            s.text(self.l - 8, self.y(v) + 4, yfmt(v), size=11, color="ink3", anchor="end")
        s.line(self.l, self.tp + self.h, self.l + self.w, self.tp + self.h, color="axis")
        s.line(self.l, self.tp, self.l, self.tp + self.h, color="axis")
        if xlabel_below:
            s.text(self.l + self.w, self.tp + self.h + 36, xlabel, size=11, color="ink3", anchor="end")
        else:
            s.text(self.l + self.w + 10, self.tp + self.h + 4, xlabel, size=11, color="ink3", anchor="start")
        s.text(self.l, self.tp - 10, ylabel, size=11, color="ink3", anchor="start")

    def clip(self, points):
        return [pt for pt in points if self.xr[0] <= pt[0] <= self.xr[1] and self.yr[0] <= pt[1] <= self.yr[1]]


# ---------------------------------------------------------------- figures

def whitepoint(theme):
    a, c = SESSIONS
    # Equal x and y scales, so ΔE00 contours keep their true shape.
    xr, yr, scale = (0.3030, 0.3210), (0.3180, 0.3340), 32000
    width, height = (xr[1] - xr[0]) * scale, (yr[1] - yr[0]) * scale
    svg = SVG(760, int(96 + height + 84), theme, "Measured white moving to D65",
              "CIE 1931 xy near D65. Two sessions on the HAN K27: the Mac app session goes from ΔE00 4.18 to 1.69 "
              "in one pass, the CLI session from 4.56 to 1.40. Rings mark ΔE00 2 and 5.")
    svg.header("One pass brings the measured white within ΔE00 2 of D65",
               "HAN K27, two sessions with the phone re-placed · CIE 1931 xy · ΔE00 at Y = 1, the engine’s metric")
    f = Frame(svg, 76, 96, width, height, xr, yr)
    ticks = lambda a_, b_, st: [round(a_ + i * st, 4) for i in range(int(round((b_ - a_) / st)) + 1)]
    f.grid(ticks(0.304, 0.320, 0.002), ticks(0.318, 0.334, 0.002), lambda v: f"{v:.3f}", lambda v: f"{v:.3f}", "x", "y")
    svg.add(f'<clipPath id="plot"><rect x="{f.l}" y="{f.tp}" width="{width:.1f}" height="{height:.1f}"/></clipPath>')
    svg.add('<g clip-path="url(#plot)">')
    svg.path([f.p(planck(t)) for t in range(5400, 8000, 20)], "ink3", width=1)
    for limit, dash in ((5, "4 4"), (2, None)):
        svg.path([f.p(pt) for pt in contour(limit)], "ink3", width=1, dash=dash, close=True)
    svg.add("</g>")
    for t in (6000, 6500, 7000):
        x, y = f.p(planck(t))
        if f.l < x < f.l + width and f.tp < y < f.tp + height:
            svg.line(x, y - 4, x, y + 4, color="ink3")
            svg.text(x + 5, y + 15, f"{t} K", size=10.5, color="ink3")
    lx, ly = f.p(planck(6250))
    svg.text(lx + 8, ly + 30, "Planckian locus", size=10.5, color="ink3")
    two = [f.p(pt) for pt in contour(2)]
    top = min(two, key=lambda pt: pt[1])
    svg.text(top[0] + 8, top[1] + 2, "ΔE00 2", size=10.5, color="ink3")
    five = [f.p(pt) for pt in contour(5)]
    inside = [pt for pt in five if f.l + 10 < pt[0] < f.l + width - 60 and f.tp + 10 < pt[1] < f.tp + height - 10]
    lab_pt = min(inside, key=lambda pt: pt[0]) if inside else (f.l + 12, f.tp + 16)
    svg.text(lab_pt[0] + 12, lab_pt[1] - 4, "ΔE00 5", size=10.5, color="ink3")
    for sess in SESSIONS:
        pts = [f.p(sess["baseline"])] + [f.p(pt) for pt in sess["passes"]]
        svg.path(pts, sess["key"], width=2)
        for x, y in pts:
            svg.dot(x, y, sess["key"], hollow=sess["key"] == "cli")
    ax, ay = f.p(a["baseline"])
    svg.text(ax + 12, ay + 5, f"{a['recorded_dE'][0]:.2f} → {a['recorded_dE'][1]:.2f}", size=12, color="ink", weight=600)
    cx, cy = f.p(c["baseline"])
    svg.text(cx - 12, cy + 5, f"{c['recorded_dE'][0]:.2f} → {c['recorded_dE'][1]:.2f}", size=12, color="ink",
             weight=600, anchor="end")
    px, py = f.p(a["passes"][-1])
    svg.text(px - 14, py + 4, "after one pass", size=11, color="ink2", anchor="end")
    tx, ty = f.p(D65)
    svg.target(tx, ty)
    svg.text(tx + 14, ty + 4, "D65", size=12, color="ink", weight=600)
    base = 96 + height + 60
    svg.legend(76, base, [(sess["label"], sess["key"], sess["key"] == "cli") for sess in SESSIONS])
    svg.text(736, base, "Sensor: uncalibrated iPhone ALS", size=11, color="ink3", anchor="end")
    svg.save(f"whitepoint-{theme}.svg")


def gamma(theme):
    a, c = SESSIONS
    svg = SVG(760, 470, theme, "Panel response fitted from a grey ramp",
              f"Relative luminance of 20, 40, 60 and 80 percent grey patches. Least-squares fit gamma {a['gamma']:.2f} "
              f"(app session) and {c['gamma']:.2f} (CLI session); the assumed 2.2 is shown for comparison.")
    svg.header(f"Four grey patches pin the panel’s response: γ ≈ {a['gamma']:.2f}, not the assumed 2.2",
               "Emitted luminance relative to white, ambient subtracted · the fit feeds the gamma-table correction")
    f = Frame(svg, 76, 92, 620, 300, (0, 1), (0, 1))
    steps = [i / 5 for i in range(6)]
    f.grid(steps, steps, lambda v: f"{int(v * 100)} %", lambda v: f"{v:.1f}", "input level (sRGB grey)",
           "relative luminance", xlabel_below=True)
    curve = lambda g: [f.p((v / 100, (v / 100) ** g)) for v in range(0, 101)]
    svg.path(curve(2.2), "ink3", width=1, dash="4 4")
    svg.text(f.x(0.66), f.y(0.66 ** 2.2) + 22, "assumed γ 2.2", size=10.5, color="ink3")
    svg.path(curve(a["gamma"]), "app", width=2)
    svg.text(f.x(0.52), f.y(0.52 ** a["gamma"]) - 12, f"fitted γ {a['gamma']:.3f} / {c['gamma']:.3f}", size=11.5,
             color="ink", anchor="end")
    # CLI rings first, app dots on top: the two placements overlap, and both stay visible.
    for sess in reversed(SESSIONS):
        for level, rel in sess["greys"].items():
            x, y = f.p((level, rel))
            svg.dot(x, y, sess["key"], hollow=sess["key"] == "cli", r=3.5 if sess["key"] == "app" else 7)
    svg.legend(76, 448, [("§14 · Mac app greys", "app", False), ("§13 · CLI greys", "cli", True)])
    svg.text(736, 448, "Two placements, points overlap within 0.002", size=11, color="ink3", anchor="end")
    svg.save(f"gamma-{theme}.svg")


def primaries(theme):
    a = SESSIONS[0]
    xr, yr, scale = (0.1, 0.7), (0.0, 0.72), 640
    width, height = (xr[1] - xr[0]) * scale, (yr[1] - yr[0]) * scale
    svg = SVG(760, int(92 + height + 50), theme, "Primaries measured by the iPhone ambient-light sensor",
              "CIE 1931 xy. The HAN K27's measured red, green and blue against the sRGB and Display P3 gamuts. "
              "Red and blue land near sRGB; green reads less saturated than sRGB green.")
    svg.header("The iPhone’s light sensor resolves the panel’s primaries",
               "HAN K27 red, green and blue patches, ambient subtracted · reference gamuts for context, not a profile")
    f = Frame(svg, 76, 92, width, height, xr, yr)
    f.grid([0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7], [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7],
           lambda v: f"{v:.1f}", lambda v: f"{v:.1f}", "x", "y")
    srgb = [(0.64, 0.33), (0.30, 0.60), (0.15, 0.06)]
    p3 = [(0.680, 0.320), (0.265, 0.690), (0.150, 0.060)]
    svg.path([f.p(pt) for pt in p3], "ink3", width=1, dash="2 4", close=True)
    svg.path([f.p(pt) for pt in srgb], "ink3", width=1, dash="5 4", close=True)
    measured = [a["primaries"][k] for k in ("red", "green", "blue")]
    svg.path([f.p(pt) for pt in measured], "app", width=2, close=True)
    offsets = {"red": (-12, 22, "end"), "green": (12, 4, "start"), "blue": (12, 18, "start")}
    for name, pt in zip(("red", "green", "blue"), measured):
        x, y = f.p(pt)
        svg.dot(x, y, "app")
        dx, dy, anchor = offsets[name]
        svg.text(x + dx, y + dy, f"{name} {pt[0]:.3f}, {pt[1]:.3f}", size=11.5, color="ink", anchor=anchor)
    wx, wy = f.p(a["baseline"])
    svg.dot(wx, wy, "ink", r=3.5)
    svg.text(wx + 10, wy + 4, "white", size=11.5, color="ink")
    kx = 520
    rows = [("measured (§14)", "app", None, 2), ("sRGB", "ink3", "5 4", 1), ("Display P3", "ink3", "2 4", 1)]
    for i, (label, color, dash, w) in enumerate(rows):
        y = 150 + i * 26
        svg.line(kx, y - 4, kx + 28, y - 4, color=color, width=w, dash=dash)
        svg.text(kx + 38, y, label, size=12, color="ink2")
    notes = ["Red and blue land near sRGB.", "Green reads less saturated than", "sRGB green.", "",
             "The ALS is uncalibrated, so treat", "these as indicative. D65 corrects", "white only; a diagonal gain cannot",
             "move primaries."]
    for i, line in enumerate(notes):
        svg.text(kx, 262 + i * 18, line, size=11.5, color="ink3")
    svg.save(f"primaries-{theme}.svg")


if __name__ == "__main__":
    check_against_records()
    os.makedirs(OUT, exist_ok=True)
    for theme in THEMES:
        whitepoint(theme)
        gamma(theme)
        primaries(theme)
    print("figures written to", os.path.relpath(OUT, ROOT))
