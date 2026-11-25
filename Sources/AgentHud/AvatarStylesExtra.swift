import AgentHudCore
import SwiftUI

// Animated avatar styles drawn with Canvas: Reactor, Planet, Visor, Buddy, Ring, Origami.
// All drawing lives in pure functions of (context, size, time, state, hue), so a still frame can be rendered at any time value.
// Coordinates inside the drawing code are on a 96 x 96 grid; the context is scaled to the real size first.

/// The seven looks every style knows. The app's session states are folded into these.
enum AvaState: Int, CaseIterable {
    case idle, working, attention, paused, stopped, done, error

    init(_ s: AgentState) {
        switch s {
        case .working, .starting: self = .working
        case .waitingPermission: self = .attention
        case .idle: self = .idle
        case .done: self = .done
        case .error: self = .error
        case .paused, .expired: self = .paused
        case .stopped, .ended: self = .stopped
        }
    }

    /// How busy the avatar is: drives the speed of its motion.
    var act: Double {
        switch self {
        case .idle: return 0.3
        case .working: return 1
        case .attention: return 0.7
        case .paused: return 0.08
        case .stopped: return 0
        case .done: return 0.25
        case .error: return 0.6
        }
    }

    /// Number of orbiting moons on the planet.
    var moons: Double {
        switch self {
        case .idle, .paused, .done: return 1
        case .working: return 3
        case .attention, .error: return 2
        case .stopped: return 0
        }
    }
}

/// One-hot weight of each look (1 for the current state, 0 for the rest).
struct AvaK {
    var idle = 0.0, working = 0.0, attention = 0.0, paused = 0.0, stopped = 0.0, done = 0.0, error = 0.0
    init(_ s: AvaState) {
        switch s {
        case .idle: idle = 1
        case .working: working = 1
        case .attention: attention = 1
        case .paused: paused = 1
        case .stopped: stopped = 1
        case .done: done = 1
        case .error: error = 1
        }
    }
}

/// Everything a frame needs.
struct AvaP {
    var t: Double              // seconds on the avatar's own clock
    var w: Double              // motion phase, advances faster the busier the state is
    var sT: Double             // seconds since the state last changed
    var k: AvaK
    var act: Double
    var moons: Double
    var sat: Double
    var bri: Double
    var hue: Double            // degrees
    var variant: Int
    var minLine: Double        // thinnest visible line on the 96 grid for the real size

    init(time: Double, sinceChange: Double, state: AvaState, hue: Double, variant: Int, scale: Double) {
        t = time
        sT = sinceChange
        k = AvaK(state)
        act = state.act
        moons = state.moons
        w = time * state.act * 3
        sat = 1 - 0.95 * k.stopped - 0.5 * k.paused
        bri = 1 - 0.4 * k.stopped - 0.15 * k.paused
        // Errors turn red whatever the session's own hue is.
        self.hue = AvaP.lerpHue(hue, 2, k.error * 0.92)
        self.variant = variant
        minLine = 1.0 / max(scale, 0.01)
    }

    static func lerpHue(_ a: Double, _ b: Double, _ t: Double) -> Double {
        let d = (b - a + 540).truncatingRemainder(dividingBy: 360) - 180
        return (a + d * t + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Colour from hue offset, saturation / lightness in percent (scaled by the state's look) and alpha.
    func C(_ dh: Double, _ s: Double, _ l: Double, _ a: Double = 1) -> Color {
        var h = (hue + dh).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        return AvaP.hsl(h, min(100, max(0, s * sat)), min(100, max(0, l * bri)), min(1, max(0, a)))
    }

    /// White that dims together with the state.
    func W(_ a: Double) -> Color { Color.white.opacity(min(1, max(0, a * (0.4 + 0.6 * bri)))) }

    func lw(_ w: Double) -> Double { max(w, minLine) }

    static func hsl(_ h: Double, _ s: Double, _ l: Double, _ a: Double) -> Color {
        let s = s / 100, l = l / 100
        let c = (1 - abs(2 * l - 1)) * s
        let hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        var r = 0.0, g = 0.0, b = 0.0
        switch hp {
        case ..<1: (r, g, b) = (c, x, 0)
        case ..<2: (r, g, b) = (x, c, 0)
        case ..<3: (r, g, b) = (0, c, x)
        case ..<4: (r, g, b) = (0, x, c)
        case ..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        let m = l - c / 2
        return Color(.sRGB, red: r + m, green: g + m, blue: b + m, opacity: a)
    }
}

// MARK: - Drawing helpers

private let tau = Double.pi * 2
private let pi = Double.pi

private func hash(_ n: Double) -> Double {
    let s = sin(n * 127.1 + 311.7) * 43758.5453
    return s - s.rounded(.down)
}

private func clamp(_ v: Double, _ a: Double, _ b: Double) -> Double { v < a ? a : (v > b ? b : v) }
private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
private func fmod(_ a: Double, _ b: Double) -> Double { a.truncatingRemainder(dividingBy: b) }
private func nz(_ x: Double) -> Double { (sin(x) + sin(x * 2.3 + 1.7) * 0.5 + sin(x * 4.1 + 0.3) * 0.25) / 1.75 }
private func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

private func circle(_ x: Double, _ y: Double, _ r: Double) -> Path {
    Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}

private func ellipse(_ x: Double, _ y: Double, _ rx: Double, _ ry: Double, rot: Double = 0) -> Path {
    Path(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
        .applying(CGAffineTransform(translationX: x, y: y).rotated(by: rot))
}

/// Arc as a stroke segment; angles grow clockwise on screen.
private func arc(_ p: inout Path, _ x: Double, _ y: Double, _ r: Double, _ a0: Double, _ a1: Double) {
    p.move(to: pt(x + cos(a0) * r, y + sin(a0) * r))
    p.addArc(center: pt(x, y), radius: r, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
}

private func arcPath(_ x: Double, _ y: Double, _ r: Double, _ a0: Double, _ a1: Double) -> Path {
    var p = Path(); arc(&p, x, y, r, a0, a1); return p
}

private func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Path {
    var p = Path(); p.move(to: pt(x0, y0)); p.addLine(to: pt(x1, y1)); return p
}

private func stroked(_ w: Double) -> StrokeStyle { StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round) }

private func glow(_ g: inout GraphicsContext, _ x: Double, _ y: Double, _ r: Double, _ c0: Color, _ c1: Color) {
    g.fill(circle(x, y, r), with: .radialGradient(Gradient(colors: [c0, c1]), center: pt(x, y), startRadius: 0, endRadius: r))
}

private func pill(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Path {
    Path(roundedRect: CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h), cornerRadius: min(w, h) / 2)
}

private func poly(_ pts: [CGPoint]) -> Path {
    var p = Path()
    guard let f = pts.first else { return p }
    p.move(to: f)
    for q in pts.dropFirst() { p.addLine(to: q) }
    p.closeSubpath()
    return p
}

// MARK: - Entry point

enum AvatarStylesExtra {
    static func hue(forSeed seed: UInt64) -> Double { Double((seed & 1023) % 1000) / 1000 * 360 }
    static func variant(forSeed seed: UInt64) -> Int { Int((seed >> 12) % 3) }

    /// Draws one frame of `style` (a new style) into a context of `size`.
    static func draw(_ g: inout GraphicsContext, size: CGSize, style: AvatarStyle, time: Double, sinceChange: Double,
                     state: AvaState, hue: Double, variant: Int) {
        let s = min(size.width, size.height)
        let scale = s / 96
        let p = AvaP(time: time, sinceChange: sinceChange, state: state, hue: hue, variant: variant, scale: scale)
        g.translateBy(x: (size.width - s) / 2, y: (size.height - s) / 2)
        g.scaleBy(x: scale, y: scale)
        switch style {
        case .reactor: reactor(&g, p)
        case .planet: planet(&g, p)
        case .visor: visor(&g, p)
        case .buddy: buddy(&g, p)
        case .ring: voice(&g, p)
        case .origami: fox(&g, p)
        default: break
        }
    }

    // MARK: Reactor

    static func reactor(_ g: inout GraphicsContext, _ p: AvaP) {
        let k = p.k, t = p.t
        let saw = fmod(t * 1.4, 1), sharp = pow(1 - saw, 3) * k.attention
        glow(&g, 48, 48, 32, p.C(0, 100, 60, 0.5 * (0.35 + 0.4 * p.act + sharp * 0.8)), p.C(0, 100, 60, 0))
        let rings: [(Double, Int, Double, Double, Double)] = [(18, 6, 3.6, 1, 1.0), (26, 10, 3, -1, 1.5), (33, 14, 2.4, 1, 0.8)]
        for (i, ring) in rings.enumerated() {
            let fi = Double(i)
            let (r, n, lw, dir, sp) = ring
            let a0 = dir * p.w * sp + fi * 1.3 + k.error * (hash((t * 10).rounded(.down) + fi) - 0.5) * 1.2
            let sc = 1 + sharp * 0.07 * (fi + 1) / 3
            let seg = tau / Double(n), len = seg * (0.64 - 0.1 * k.stopped)
            let fl = (k.error > 0.5 && hash((t * 16).rounded(.down) + fi * 7) > 0.6) ? 0.35 : 1
            var path = Path()
            for j in 0..<n {
                let s = a0 + Double(j) * seg
                arc(&path, 48, 48, r * sc, s, s + len)
            }
            g.stroke(path, with: .color(p.C(fi * 6, 90, 64 - fi * 4, 0.95 * fl)), style: stroked(p.lw(lw)))
        }
        let cr = 8 + 1.6 * sin(t * 2.2) * (0.4 + p.act) + sharp * 5
        glow(&g, 48, 48, cr * 2, p.C(0, 100, 85, 1), p.C(0, 100, 55, 0))
        g.fill(circle(48, 48, cr * 0.55), with: .color(p.W(0.95)))
        if k.attention > 0.02 {
            let ph = fmod(t * 1.4, 1)
            g.stroke(circle(48, 48, 12 + ph * 30), with: .color(p.C(0, 100, 75, pow(1 - ph, 2) * k.attention)), style: stroked(p.lw(2.6)))
        }
        if k.done > 0.5 && p.sT < 1.1 {
            let q = p.sT / 1.1
            g.stroke(circle(48, 48, 14 + q * 30), with: .color(p.C(0, 100, 75, (1 - q) * 0.9)), style: stroked(p.lw(3)))
        }
    }

    // MARK: Planet

    static func planet(_ g: inout GraphicsContext, _ p: AvaP) {
        let k = p.k, t = p.t, tilt = -0.38, R = 18.0
        let ox = (hash((t * 25).rounded(.down)) - 0.5) * 2.4 * k.error
        let oy = (hash((t * 25).rounded(.down) + 9) - 0.5) * 2.4 * k.error
        let hop = k.done * max(0, 1 - p.sT / 1.2) * abs(sin(p.sT * 6)) * 8
        let cx = 48 + ox, cy = 48 + oy - hop - k.attention * 3 * (0.5 + 0.5 * sin(t * 6))

        func moonState(_ j: Int) -> (x: Double, y: Double, d: Double, a: Double) {
            let fj = Double(j)
            let ang = p.w * (0.55 + fj * 0.3) + fj * 2.1
            let lx = cos(ang) * 37, ly = sin(ang) * 11
            return (cx + lx * cos(tilt) - ly * sin(tilt), cy + lx * sin(tilt) + ly * cos(tilt), sin(ang), clamp(p.moons - fj, 0, 1))
        }
        func moon(_ g: inout GraphicsContext, _ j: Int) {
            let m = moonState(j)
            if m.a < 0.02 { return }
            let fj = Double(j), r = 3.2 + fj * 0.6
            glow(&g, m.x, m.y, r * 2.4, p.C(40 + fj * 30, 70, 75, 0.25 * m.a), p.C(40 + fj * 30, 70, 75, 0))
            g.fill(circle(m.x, m.y, r), with: .color(p.C(40 + fj * 30, 55, 80, m.a)))
            g.fill(circle(m.x + r * 0.35, m.y + r * 0.2, r * 0.8), with: .color(Color(red: 10 / 255, green: 14 / 255, blue: 40 / 255).opacity(0.3 * m.a)))
        }

        glow(&g, cx, cy, R + 10, p.C(0, 80, 65, 0.3 + 0.3 * k.attention), p.C(0, 80, 65, 0))
        g.stroke(ellipse(cx, cy, 37, 11, rot: tilt), with: .color(p.C(0, 60, 80, 0.12 + 0.1 * p.moons / 3)), style: stroked(p.lw(1)))
        for j in 0..<3 where moonState(j).d < 0 { moon(&g, j) }

        var c = g
        c.clip(to: circle(cx, cy, R))
        c.fill(Path(CGRect(x: cx - R, y: cy - R, width: R * 2, height: R * 2)),
               with: .radialGradient(Gradient(colors: [p.C(0, 75, 62), p.C(10, 80, 32)]), center: pt(cx - 5, cy - 6), startRadius: 2, endRadius: R * 1.45))
        for i in 0..<3 {
            let fi = Double(i)
            let x = fmod(fi * 26 + p.w * 9, 78) - 39
            c.fill(ellipse(cx + x, cy + (fi - 1) * 9, 9 + fi * 2, 5 + fi, rot: 0.3 * fi), with: .color(p.C(70, 55, 62, 0.9)))
        }
        let ph = p.w * 0.5 + t * 0.12, off = R * (1.2 + 0.8 * sin(ph))
        let night = Color(red: 6 / 255, green: 10 / 255, blue: 32 / 255)
        c.fill(Path(CGRect(x: cx - R, y: cy - R, width: R * 2, height: R * 2)),
               with: .radialGradient(Gradient(stops: [.init(color: night.opacity(0.78), location: 0), .init(color: night.opacity(0.78), location: 0.8),
                                                      .init(color: night.opacity(0), location: 1)]),
                                     center: pt(cx + off, cy), startRadius: R * 0.55, endRadius: R * 1.12))
        g.stroke(circle(cx, cy, R), with: .color(p.C(0, 90, 78, 0.55)), style: stroked(p.lw(1.4)))
        if k.error > 0.02 {
            var cr = Path()
            cr.move(to: pt(cx - 6, cy - R + 1)); cr.addLine(to: pt(cx - 2, cy - 8)); cr.addLine(to: pt(cx - 7, cy - 3))
            cr.addLine(to: pt(cx + 1, cy + 4)); cr.addLine(to: pt(cx - 1, cy + R - 1))
            g.stroke(cr, with: .color(.white.opacity(0.8 * k.error)), style: stroked(p.lw(1.2)))
        }
        for j in 0..<3 where moonState(j).d >= 0 { moon(&g, j) }
        if k.attention > 0.02 {
            let q = fmod(t * 1.1, 1)
            g.stroke(circle(cx, cy, R + 3 + q * 17), with: .color(p.C(0, 90, 72, (1 - q) * k.attention)), style: stroked(p.lw(2)))
        }
        if k.done > 0.5 && p.sT < 1.2 {
            let u = p.sT / 1.2
            g.stroke(circle(cx, cy, R + 2 + u * 20), with: .color(p.C(0, 90, 78, (1 - u) * 0.9)), style: stroked(p.lw(2.5)))
        }
    }

    // MARK: Visor

    static func visor(_ g: inout GraphicsContext, _ p: AvaP) {
        let k = p.k, t = p.t
        let dy = sin(t * 1.6) * 2 - k.attention * 5 + k.stopped * 6
        let rot = k.paused * 0.14 + k.error * (hash((t * 22).rounded(.down)) - 0.5) * 0.12 + k.stopped * 0.05
        var c = g
        c.translateBy(x: 48, y: 48 + dy)
        c.rotate(by: .radians(rot))
        glow(&c, 0, 0, 36, p.C(0, 90, 55, 0.14 + 0.1 * k.attention), p.C(0, 90, 55, 0))
        var head = Path()
        head.move(to: pt(-27, -8))
        head.addCurve(to: pt(0, -20), control1: pt(-27, -24), control2: pt(-14, -20))
        head.addCurve(to: pt(27, -8), control1: pt(14, -20), control2: pt(27, -24))
        head.addCurve(to: pt(0, 19), control1: pt(27, 8), control2: pt(16, 19))
        head.addCurve(to: pt(-27, -8), control1: pt(-16, 19), control2: pt(-27, 8))
        head.closeSubpath()
        c.fill(head, with: .linearGradient(Gradient(colors: [p.C(0, 45, 32), p.C(0, 55, 14)]), startPoint: pt(0, -20), endPoint: pt(0, 19)))
        c.stroke(head, with: .color(p.C(0, 80, 66, 0.9)), style: stroked(p.lw(1.8)))
        var clipped = c
        clipped.clip(to: head)
        clipped.fill(Path(CGRect(x: -28, y: -21, width: 56, height: 22)),
                     with: .linearGradient(Gradient(colors: [p.W(0.22), p.W(0)]), startPoint: pt(0, -20), endPoint: pt(0, 0)))

        let H = k.idle * 13 + k.working * 4.5 + k.attention * 17 + k.paused * 6 + k.stopped * 1.4 + k.done * 3 + k.error * 7
        let Wd = k.idle * 9 + k.working * 12 + k.attention * 11 + k.paused * 9 + k.stopped * 9 + k.done * 11 + k.error * 11
        let b = fmod(t, 4.3)
        var bl = b < 0.14 ? abs(b / 0.07 - 1) : 1
        bl = 1 - (1 - bl) * (1 - 0.7 * k.working) * (1 - k.stopped)
        let h = max(1.4, H * bl)
        let gx = nz(t * 0.5) * 4 * (k.idle + k.paused * 0.3) + sin(p.w * 1.2) * 4 * k.working + (hash((t * 18).rounded(.down)) - 0.5) * 3 * k.error
        let gy = nz(t * 0.4 + 4) * 1.6 * k.idle + 2 * k.working
        for s in [-1.0, 1.0] {
            let ex = s * 11 + gx, ey = -1 + gy
            var e = c
            e.translateBy(x: ex, y: ey)
            e.rotate(by: .radians(-s * (k.working * 0.22 + k.error * 0.4)))
            glow(&e, 0, 0, 13, p.C(0, 100, 70, 0.4 * (1 - k.done) * (1 - k.stopped * 0.7)), p.C(0, 100, 70, 0))
            e.fill(pill(0, 0, Wd, h), with: .color(p.C(0, 100, 82, 1 - k.done)))
            if k.done > 0.02 {
                c.stroke(arcPath(ex, ey + 3, 5, pi * 1.05, pi * 1.95), with: .color(p.C(0, 100, 82, k.done)), style: stroked(p.lw(3)))
            }
        }
    }

    // MARK: Voice ring

    static func voice(_ g: inout GraphicsContext, _ p: AvaP) {
        let k = p.k, t = p.t, N = 36, r0 = 21.0
        let saw = fmod(t * 1.2, 1), pulse = pow(1 - saw, 2) * k.attention
        let fr = 1 - fmod(t, 8) / 8
        g.stroke(circle(48, 48, r0 - 4), with: .color(p.C(0, 70, 70, 0.25)), style: stroked(p.lw(1)))
        let sweepPos = fmod(t * 0.5, 1)
        for i in 0..<N {
            let a = Double(i) / Double(N) * tau - pi / 2, fi = Double(i) / Double(N)
            let v = (sin(a * 3 + p.w * 1.6) + sin(a * 5 - p.w * 2.3 + 1) * 0.8 + sin(a * 2 + p.w * 3.1) * 0.6) / 2.4
            let lIdle = 4 + 2.2 * sin(t * 1.8) + 0.5 * sin(a * 3 + t)
            let lWork = 4 + 13 * (0.5 + 0.5 * v)
            let lAtt = 6 + 9 * pulse + 2.5 * sin(a * 6 + t * 6) * k.attention
            let lDone = 8 - 3 * max(0, 1 - p.sT / 0.8)
            let lErr = 3 + 14 * hash(Double(i) + (t * 14).rounded(.down))
            let len = k.idle * lIdle + k.working * lWork + k.attention * lAtt + k.paused * 3.4 + k.stopped * 2 + k.done * lDone + k.error * lErr
            var al = 0.9
            al = lerp(al, fi < fr ? 0.95 : 0.25, k.paused)
            al = lerp(al, 0.5, k.stopped)
            if k.done > 0.02 {
                let sw = exp(-pow(fmod(fi - sweepPos + 1.5, 1) - 0.5, 2) * 40)
                al = lerp(al, 0.6 + 0.4 * sw, k.done)
            }
            g.stroke(line(48 + cos(a) * r0, 48 + sin(a) * r0, 48 + cos(a) * (r0 + len), 48 + sin(a) * (r0 + len)),
                     with: .color(p.C(fi * 40 - 20, 85, 60, al)), style: stroked(p.lw(2.6)))
        }
        let cr = 7 + 1.5 * sin(t * 1.8) + pulse * 3
        glow(&g, 48, 48, cr * 2.4, p.C(0, 95, 72, 0.9), p.C(0, 95, 60, 0))
        g.fill(circle(48, 48, cr * 0.45), with: .color(p.W(0.9)))
        if k.attention > 0.02 {
            for rp in 0..<2 {
                let q = fmod(t * 1.2 + Double(rp) * 0.5, 1)
                g.stroke(circle(48, 48, r0 + 8 + q * (44 - r0 - 8)), with: .color(p.C(0, 95, 78, (1 - q) * 0.85 * k.attention)), style: stroked(p.lw(2)))
            }
        }
    }

    // MARK: Origami animal

    private static let fx: [(p: [CGPoint], s: Double, ear: Double, cream: Bool)] = [
        ([pt(-32, -36), pt(-34, -4), pt(-10, -18)], 1.0, -1, false),
        ([pt(32, -36), pt(34, -4), pt(10, -18)], 0.9, 1, false),
        ([pt(-34, -4), pt(-10, -18), pt(0, 4)], 0.95, 0, false),
        ([pt(34, -4), pt(10, -18), pt(0, 4)], 0.8, 0, false),
        ([pt(-10, -18), pt(10, -18), pt(0, 4)], 1.12, 0, false),
        ([pt(-34, -4), pt(0, 4), pt(-12, 24)], 1.05, 0, true),
        ([pt(34, -4), pt(0, 4), pt(12, 24)], 0.93, 0, true),
        ([pt(-12, 24), pt(12, 24), pt(0, 4)], 1.0, 0, true),
        ([pt(-12, 24), pt(12, 24), pt(0, 34)], 1.08, 0, true),
    ]

    static func fox(_ g: inout GraphicsContext, _ p: AvaP) {
        let k = p.k, t = p.t
        let fold = k.stopped * 0.6 + k.paused * 0.28 + k.error * 0.18
        let tilt = sin(t * 0.8) * 0.1 * k.idle + sin(p.w * 0.5) * 0.05 * k.working + k.paused * 0.2
            + k.attention * 0.2 * sin(t * 2.6) + k.error * (hash((t * 30).rounded(.down)) - 0.5) * 0.25 + k.stopped * 0.06
        let dropY = k.stopped * 5 + k.paused * 2 + k.working * sin(p.w * 1.1) * 0.8
        let perk = k.attention * (5 + 1.5 * sin(t * 7)) + k.done * 3 + k.done * 4 * max(0, 1 - p.sT)
        var c = g
        c.translateBy(x: 48, y: 48 + dropY)
        c.scaleBy(x: 0.95, y: 0.95)
        c.translateBy(x: 0, y: 20)
        c.rotate(by: .radians(tilt))
        c.translateBy(x: 0, y: -20)

        func ear(_ x: Double, _ y: Double, _ e: Double) -> CGPoint {
            pt(x + (e != 0 ? e * k.working * sin(p.w * 1.7) * 1.5 : 0), y - (e != 0 ? perk : 0))
        }
        let tick = (t * 14).rounded(.down)
        for (i, f) in fx.enumerated() {
            let fi = Double(i)
            let u = clamp(1 - fold - k.working * 0.05 * (1 + sin(p.w * 2 + fi * 0.9)) - k.idle * 0.03 * (1 + sin(t * 1.4 + fi * 0.8)), 0.3, 1)
            let s = 0.55 + 0.45 * u
            let cx = (f.p[0].x + f.p[1].x + f.p[2].x) / 3, cy = (f.p[0].y + f.p[1].y + f.p[2].y) / 3
            var pts: [CGPoint] = []
            for j in 0..<3 {
                let fj = Double(j)
                let x = cx + (f.p[j].x - cx) * s + (hash(fi * 3 + fj + tick) - 0.5) * 3 * k.error
                let y = cy + (f.p[j].y - cy) * s + (hash(fi * 3 + fj + 5 + tick) - 0.5) * 3 * k.error
                pts.append(ear(x, y, f.ear))
            }
            let uu = 0.72 + 0.28 * u
            let path = poly(pts)
            c.fill(path, with: .color(f.cream ? p.C(0, 28, 84 * f.s * uu) : p.C(0, 78, 52 * f.s * uu)))
            c.stroke(path, with: .color(p.C(0, 60, 30, 0.35)), style: stroked(p.lw(0.7)))
        }
        let inner: [[CGPoint]] = [[pt(-27, -24), pt(-28, -9), pt(-17, -17)], [pt(27, -24), pt(28, -9), pt(17, -17)]]
        for i in 0..<2 {
            let e = inner[i]
            c.fill(poly(e.map { ear($0.x, $0.y, i == 1 ? 1 : -1) }), with: .color(p.C(0, 60, 26, 0.8)))
        }
        c.fill(poly([pt(-4, 28), pt(4, 28), pt(0, 34)]), with: .color(p.C(0, 40, 16)))
        let bt = fmod(t, 4)
        let bl = bt < 0.13 ? abs(bt / 0.065 - 1) : 1
        let eo = max(0.05, (1 - k.working * 0.55 - k.paused * 0.5 - k.stopped * 0.95 + k.attention * 0.4) * bl)
        for sd in [-1.0, 1.0] {
            if k.done > 0.02 {
                c.stroke(arcPath(sd * 17, 4.5, 4.5, pi * 1.1, pi * 1.9), with: .color(p.C(0, 50, 16, k.done)), style: stroked(p.lw(2.4)))
            }
            c.stroke(line(sd * 23, 0, sd * 11, 5), with: .color(p.C(0, 50, 16, 1 - k.done)), style: stroked(p.lw(0.9 + eo * 3)))
        }
        if k.done > 0.5 && p.sT < 2.4 {
            var cf = g
            cf.translateBy(x: 48, y: 48)
            for i in 0..<8 {
                let fi = Double(i)
                let tt = p.sT
                let px = (hash(fi) - 0.5) * 70, py = -44 + tt * (22 + hash(fi + 3) * 22)
                var q = cf
                q.translateBy(x: px, y: py)
                q.rotate(by: .radians(tt * (3 + fi)))
                q.fill(Path(CGRect(x: -2.5, y: -2.5, width: 5, height: 5)), with: .color(p.C(fi * 45, 80, 62, clamp(1 - tt / 2.4, 0, 1))))
            }
        }
    }

    // MARK: Mini 3D character

    private struct Part {
        var v: [SIMD3<Double>]
        var pyramid: Bool
        var hue: Double, sat: Double, light: Double
        var em: Bool
    }

    private static let boxFaces: [[Int]] = [[0, 2, 6, 4], [1, 3, 7, 5], [0, 1, 5, 4], [2, 3, 7, 6], [0, 1, 3, 2], [4, 5, 7, 6]]
    private static let pyrFaces: [[Int]] = [[0, 1, 2, 3], [0, 1, 4], [1, 2, 4], [2, 3, 4], [3, 0, 4]]

    private static func rotate(_ v: inout [SIMD3<Double>], rx: Double, rz: Double, piv: SIMD3<Double>) {
        if rx == 0 && rz == 0 { return }
        for i in 0..<v.count {
            var x = v[i].x - piv.x, y = v[i].y - piv.y, z = v[i].z - piv.z
            if rx != 0 {
                let cs = cos(rx), sn = sin(rx)
                let y2 = y * cs - z * sn, z2 = y * sn + z * cs
                y = y2; z = z2
            }
            if rz != 0 {
                let cs = cos(rz), sn = sin(rz)
                let x2 = x * cs - y * sn, y2 = x * sn + y * cs
                x = x2; y = y2
            }
            v[i] = SIMD3(x + piv.x, y + piv.y, z + piv.z)
        }
    }

    private static func box(_ cx: Double, _ cy: Double, _ cz: Double, _ w: Double, _ h: Double, _ d: Double,
                            _ col: (Double, Double, Double), em: Bool = false, rx: Double = 0, rz: Double = 0, piv: SIMD3<Double>? = nil) -> Part {
        let hx = w / 2, hy = h / 2, hz = d / 2
        var v: [SIMD3<Double>] = []
        v.reserveCapacity(8)
        for i in 0..<8 {
            v.append(SIMD3(cx + ((i & 1) != 0 ? hx : -hx), cy + ((i & 2) != 0 ? hy : -hy), cz + ((i & 4) != 0 ? hz : -hz)))
        }
        rotate(&v, rx: rx, rz: rz, piv: piv ?? SIMD3(cx, cy, cz))
        return Part(v: v, pyramid: false, hue: col.0, sat: col.1, light: col.2, em: em)
    }

    private static func pyr(_ cx: Double, _ by: Double, _ cz: Double, _ w: Double, _ h: Double, _ d: Double,
                            _ col: (Double, Double, Double)) -> Part {
        let hx = w / 2, hz = d / 2
        let v = [SIMD3(cx - hx, by, cz - hz), SIMD3(cx + hx, by, cz - hz), SIMD3(cx + hx, by, cz + hz), SIMD3(cx - hx, by, cz + hz), SIMD3(cx, by + h, cz)]
        return Part(v: v, pyramid: true, hue: col.0, sat: col.1, light: col.2, em: false)
    }

    private static func char3(_ p: AvaP, _ v: Int) -> [Part] {
        let k = p.k, t = p.t
        var parts: [Part] = []
        parts.reserveCapacity(16)
        let hop = k.attention * abs(sin(t * 7)) * 6 + k.done * max(0, 1 - p.sT / 1.4) * abs(sin(p.sT * 8)) * 9
        let slump = k.stopped * 5 + k.paused * 2
        let br = sin(t * 2.1) * 0.7 * (1 - k.working * 0.5)
        let dims: [(bw: Double, bh: Double, bd: Double, hw: Double, hh: Double, hd: Double, lh: Double)] = [
            (24, 20, 16, 26, 20, 20, 10), (18, 18, 14, 28, 18, 20, 9), (30, 14, 18, 30, 17, 20, 7)]
        let D = dims[v]
        let y0 = hop
        let legC = (0.0, 50.0, 38.0)
        parts.append(box(-D.bw * 0.25, D.lh / 2 + y0, 0, 7, D.lh, 7, legC))
        parts.append(box(D.bw * 0.25, D.lh / 2 + y0, 0, 7, D.lh, 7, legC))
        let bb = D.lh + y0, bh = D.bh + br * 0.6 - slump * 0.4
        parts.append(box(0, bb + bh / 2, 0, D.bw, bh, D.bd, (0, 65, 50)))
        let hb = bb + bh + 1 - slump * 0.6, hh = D.hh, nod = sin(p.w * 2.2) * 0.9 * k.working
        let hc = hb + hh / 2 + nod, ht = hb + hh + nod
        parts.append(box(0, hc, 0, D.hw, hh, D.hd, (0, 65, 58)))
        let blk = fmod(t, 3.7), bl = blk < 0.14 ? abs(blk / 0.07 - 1) : 1
        let eo = (1 - k.working * 0.5 - k.paused * 0.55 - k.stopped * 0.9 - k.done * 0.35 + k.attention * 0.3 - k.error * 0.2) * bl
        let eh = max(0.5, 5.2 * eo)
        let ez = D.hd / 2 + 0.3
        parts.append(box(-D.hw * 0.24, hc + 1, ez, 5, eh, 0.6, (0, 100, 78), em: true))
        parts.append(box(D.hw * 0.24, hc + 1, ez, 5, eh, 0.6, (0, 100, 78), em: true))
        let sy = bb + bh - 3, ax = D.bw / 2 + 3, aH = 14.0
        let env = fmod(t, 6) < 1.6 ? sin(fmod(t, 6) / 1.6 * pi) : 0
        let rzR = 0.08 + k.attention * (2.6 + sin(t * 14) * 0.3) + k.done * 2.7 + k.idle * env * (2.2 + sin(t * 11) * 0.35) + k.error * sin(t * 28) * 0.5
        let rzL = -(0.08 + k.attention * (2.6 + sin(t * 14 + 1) * 0.3) + k.done * 2.7 + k.error * sin(t * 26) * 0.5)
        let rxL = -(1 + sin(p.w * 5) * 0.3) * k.working, rxR = -(1 + sin(p.w * 5 + pi) * 0.3) * k.working
        parts.append(box(-ax, sy - aH / 2, 0, 5, aH, 5, (10, 55, 44), rx: rxL, rz: rzL, piv: SIMD3(-ax, sy, 0)))
        parts.append(box(ax, sy - aH / 2, 0, 5, aH, 5, (10, 55, 44), rx: rxR, rz: rzR, piv: SIMD3(ax, sy, 0)))
        let tipGlow = k.working + k.attention
        if v == 0 {
            parts.append(box(0, ht + 4, 0, 2, 8, 2, (0, 40, 60)))
            parts.append(box(0, ht + 9.5, 0, 4.5, 4.5, 4.5, (0, 100, 70), em: tipGlow > 0.4 || k.error > 0.4))
        } else if v == 1 {
            parts.append(pyr(-D.hw * 0.3, ht, 0, 8, 9, 6, (0, 65, 52)))
            parts.append(pyr(D.hw * 0.3, ht, 0, 8, 9, 6, (0, 65, 52)))
            parts.append(box(0, bb + 4, -D.bd / 2 - 6, 3, 3, 12, (0, 60, 46), rx: sin(t * 3) * 0.4 * (0.3 + p.act), piv: SIMD3(0, bb + 4, -D.bd / 2)))
        } else {
            parts.append(pyr(0, ht, 0, 10, 10, 10, (0, 70, 46)))
        }
        return parts
    }

    private struct Face {
        var sc: [CGPoint]
        var z: Double
        var lam: Double
        var part: Int
    }

    static func buddy(_ g: inout GraphicsContext, _ p: AvaP) {
        let k = p.k, t = p.t
        let parts = char3(p, p.variant % 3)
        var yaw = 0.6 + sin(t * 0.8) * 0.22
        yaw = yaw * (1 - k.attention * 0.85) + k.error * (hash((t * 24).rounded(.down)) - 0.5) * 0.5
        if k.working > 0.5 { yaw = lerp(yaw, 0.45, k.working) }
        let cyw = cos(yaw), syw = sin(yaw), pit = 0.5, cp = cos(pit), sp = sin(pit), S = 1.08
        var L = SIMD3(-0.45, 0.7, 0.55)
        L /= (L * L).sum().squareRoot()
        func tr(_ q: SIMD3<Double>) -> SIMD3<Double> {
            let x1 = q.x * cyw + q.z * syw, z1 = -q.x * syw + q.z * cyw
            return SIMD3(x1, q.y * cp - z1 * sp, q.y * sp + z1 * cp)
        }
        var faces: [Face] = []
        faces.reserveCapacity(48)
        for (pi_, part) in parts.enumerated() {
            var pc = SIMD3<Double>(0, 0, 0)
            for q in part.v { pc += q }
            pc /= Double(part.v.count)
            let T = part.v.map(tr)
            for ids in (part.pyramid ? pyrFaces : boxFaces) {
                let a = part.v[ids[0]], b = part.v[ids[1]], d = part.v[ids[2]]
                let u = b - a, w = d - a
                var n = SIMD3(u.y * w.z - u.z * w.y, u.z * w.x - u.x * w.z, u.x * w.y - u.y * w.x)
                var fc = SIMD3<Double>(0, 0, 0)
                for i in ids { fc += part.v[i] }
                fc /= Double(ids.count)
                let toFace = fc - pc
                if (n * toFace).sum() < 0 { n = -n }
                let nl = (n * n).sum().squareRoot()
                n = tr(n / (nl == 0 ? 1 : nl))
                if n.z <= 0.001 { continue }
                var z = 0.0
                var sc: [CGPoint] = []
                sc.reserveCapacity(4)
                for i in ids {
                    let q = T[i]
                    z += q.z
                    sc.append(pt(48 + q.x * S, 52 - (q.y - 24) * S))
                }
                faces.append(Face(sc: sc, z: z / Double(ids.count) + (part.em ? 0.5 : 0), lam: max(0, (n * L).sum()), part: pi_))
            }
        }
        faces.sort { $0.z < $1.z }
        let airborne = k.attention * abs(sin(t * 7)) * 6 + k.done * max(0, 1 - p.sT / 1.4) * abs(sin(p.sT * 8)) * 9
        let gs = 1 - min(1, airborne / 16)
        g.fill(ellipse(48, 78, 20 * gs, 6.5 * gs), with: .color(.black.opacity(0.28)))
        for f in faces {
            let part = parts[f.part]
            let col = part.em ? p.C(part.hue, 100, 76) : p.C(part.hue, part.sat, part.light * (0.55 + 0.62 * f.lam))
            let path = poly(f.sc)
            g.fill(path, with: .color(col))
            g.stroke(path, with: .color(col), style: stroked(p.lw(0.7)))
        }
    }
}

// MARK: - View

/// The view for the new styles: one TimelineView per avatar, one Canvas inside.
struct ExtraAvatar: View {
    let seed: UInt64
    let state: AgentState
    let style: AvatarStyle
    var size: CGFloat
    var animated = true
    /// For renders: the time of the still frame (default: a fixed pleasant moment).
    var stillTime: Double? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var since = Date.distantPast

    private var ava: AvaState { AvaState(state) }
    private var offset: Double { Double(seed % 997) / 997 * 6 }

    var body: some View {
        let live = animated && !reduceMotion
        Group {
            if live {
                // Busy states tick at 30 fps, calm ones at 12 fps, a stopped avatar does not tick at all.
                TimelineView(.animation(minimumInterval: interval, paused: ava == .stopped)) { ctx in
                    let now = ctx.date
                    canvas(time: fmod(now.timeIntervalSinceReferenceDate, 7200) + offset,
                           sinceChange: min(5, now.timeIntervalSince(since)))
                }
            } else {
                canvas(time: stillTime ?? (2.2 + offset), sinceChange: 5)
            }
        }
        .frame(width: size, height: size)
        // Without a plate the figure needs a soft edge to read on bright wallpapers.
        .shadow(color: .black.opacity(0.35), radius: max(1, size * 0.025), y: size * 0.02)
        .onChange(of: state) { since = Date() }
    }

    private var interval: Double {
        switch ava {
        case .working, .attention: return 1.0 / 30
        default: return 1.0 / 12
        }
    }

    private func canvas(time: Double, sinceChange: Double) -> some View {
        let hue = AvatarStylesExtra.hue(forSeed: seed), variant = AvatarStylesExtra.variant(forSeed: seed)
        let style = style, ava = ava
        return Canvas { gc, sz in
            var g = gc
            AvatarStylesExtra.draw(&g, size: sz, style: style, time: time, sinceChange: sinceChange, state: ava, hue: hue, variant: variant)
        }
        .frame(width: size, height: size)
    }
}
