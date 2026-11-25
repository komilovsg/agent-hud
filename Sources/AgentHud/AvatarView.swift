import AgentHudCore
import SwiftUI

/// A session's "little friend": a procedural character generated from the session seed.
/// Three styles to choose from (Blob, Bot, Pixel), animation depends on the state.
struct AvatarView: View {
    let seed: UInt64
    let state: AgentState
    let style: AvatarStyle
    var size: CGFloat = 36
    var animated = true
    /// The session's agent - for the "Logos" style.
    var kind: AgentKind? = nil
    /// Renders only: time of the still frame for the newer styles.
    var stillTime: Double? = nil

    @State private var blink = false

    private var motion: AvatarMotion {
        guard animated, !style.isExtra else { return .still }
        switch state {
        case .working, .starting: return .sway
        case .waitingPermission: return .bounce
        default: return .still
        }
    }

    var body: some View {
        // The character is drawn once per state, motion is a layer animation in Core Animation.
        LayerMotion(layerMotion) {
            if style == .logo {
                LogoAvatar(kind: kind, state: state, size: size)
            } else if style.isExtra {
                ExtraAvatar(seed: seed, state: state, style: style, size: size, animated: animated, stillTime: stillTime)
            } else {
                Canvas { gc, sz in
                    var g = gc
                    let p = AvatarPainter(seed: seed, state: state, size: sz, blink: blink)
                    switch style {
                    case .blob, .logo, .reactor, .planet, .visor, .buddy, .ring, .origami: p.drawBlob(&g)
                    case .bot: p.drawBot(&g)
                    case .pixel: p.drawPixel(&g)
                    }
                }
                .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) { StateBadge(state: state, size: size, animated: animated) }
        .task(id: motion) {
            // Blinking every few seconds - only for characters that move.
            guard motion != .still, style != .logo, !style.isExtra else { blink = false; return }
            let period = 3.2 + Double(seed % 13) / 10
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(period))
                blink = true
                try? await Task.sleep(for: .milliseconds(130))
                blink = false
            }
        }
        .accessibilityLabel(Text(state.title))
    }

    private var layerMotion: LayerMotionKind {
        let delay = Double(seed % 997) / 997 * 0.6
        switch motion {
        case .still: return .none
        case .sway: return .sway(amplitude: size * 0.04, duration: 0.9, delay: delay)
        case .bounce: return .bounce(amplitude: size * 0.13, duration: 0.32, delay: delay)
        }
    }
}

enum AvatarMotion: Hashable { case still, sway, bounce }

struct StateBadge: View {
    let state: AgentState
    let size: CGFloat
    var animated = true

    var body: some View {
        let d = max(12, size * 0.38)
        Group {
            switch state {
            case .waitingPermission:
                LayerMotion(animated ? .pulse : .none) { badge("exclamationmark", .orange, d) }
                    .frame(width: d, height: d)
            case .expired: badge("clock", Color(red: 0.75, green: 0.5, blue: 0.25), d)
            case .done: badge("checkmark", .green, d)
            case .error: badge("xmark", .red, d)
            case .idle:
                Text("z").font(.system(size: d * 0.8, weight: .heavy, design: .rounded))
                    .foregroundStyle(.secondary).offset(x: 2, y: -2)
            default: EmptyView()
            }
        }
        .offset(x: d * 0.2, y: -d * 0.15)
    }

    private func badge(_ symbol: String, _ color: Color, _ d: CGFloat) -> some View {
        ZStack {
            Circle().fill(color)
            Circle().stroke(.white.opacity(0.9), lineWidth: 1.5)
            Image(systemName: symbol).font(.system(size: d * 0.55, weight: .black)).foregroundStyle(.white)
        }
        .frame(width: d, height: d)
        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
    }
}

extension AgentState {
    var title: String {
        switch self {
        case .starting: return "Starting"
        case .working: return "Working"
        case .waitingPermission: return "Needs permission"
        case .expired: return "Expired"
        case .idle: return "Idle"
        case .done: return "Done"
        case .error: return "Error"
        case .ended: return "Ended"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        }
    }

    var tint: Color {
        switch self {
        case .waitingPermission: return .orange
        case .expired: return Color(red: 0.75, green: 0.5, blue: 0.25)
        case .done: return .green
        case .error: return .red
        case .working, .starting: return .accentColor
        case .idle, .ended: return .secondary
        case .paused, .stopped: return .holdTint
        }
    }
}

// MARK: - Drawing

struct AvatarPainter {
    let seed: UInt64
    let state: AgentState
    let size: CGSize
    let blink: Bool

    private func bits(_ shift: UInt64, _ count: UInt64) -> UInt64 { (seed >> shift) & ((1 << count) - 1) }

    private var hue: Double { Double(bits(0, 10) % 1000) / 1000 }
    private var phase: Double { Double(bits(10, 8)) / 255 * .pi * 2 }

    private var saturationScale: Double {
        switch state {
        case .idle, .ended: return 0.18
        case .expired: return 0.45
        default: return 1
        }
    }

    private var bodyColor: Color { Color(hue: hue, saturation: 0.55 * saturationScale, brightness: 0.95) }
    private var darkColor: Color { Color(hue: hue, saturation: 0.7 * saturationScale, brightness: 0.6) }
    private var lightColor: Color { Color(hue: hue, saturation: 0.25 * saturationScale, brightness: 1) }

    // Motion is set by LayerMotion, here only the static picture.
    private let bob: CGFloat = 0
    private let squash: CGFloat = 1
    private let lookX: CGFloat = 0
    private var blinking: Bool { blink }

    // MARK: Eyes - shared by all styles

    enum EyeKind { case open, closed, happy, cross, dot }

    private var eyeKind: EyeKind {
        switch state {
        case .idle, .ended: return .closed
        case .done: return .happy
        case .error: return .cross
        case .expired: return .dot
        default: return blinking ? .closed : .open
        }
    }

    private func drawEye(_ g: inout GraphicsContext, at c: CGPoint, r: CGFloat, pupil: Color, sclera: Color = .white) {
        let lw = max(1.2, r * 0.45)
        switch eyeKind {
        case .open:
            g.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r * 1.1, width: r * 2, height: r * 2.2)), with: .color(sclera))
            let pr = r * 0.55
            let pc = CGPoint(x: c.x + lookX, y: c.y + r * 0.15)
            g.fill(Path(ellipseIn: CGRect(x: pc.x - pr, y: pc.y - pr, width: pr * 2, height: pr * 2)), with: .color(pupil))
            g.fill(Path(ellipseIn: CGRect(x: pc.x - pr * 0.1, y: pc.y - pr * 0.75, width: pr * 0.6, height: pr * 0.6)), with: .color(.white.opacity(0.9)))
        case .closed:
            var p = Path()
            p.move(to: CGPoint(x: c.x - r, y: c.y + r * 0.2))
            p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y + r * 0.2), control: CGPoint(x: c.x, y: c.y + r * 0.9))
            g.stroke(p, with: .color(pupil), style: StrokeStyle(lineWidth: lw, lineCap: .round))
        case .happy:
            var p = Path()
            p.move(to: CGPoint(x: c.x - r, y: c.y + r * 0.4))
            p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y + r * 0.4), control: CGPoint(x: c.x, y: c.y - r * 0.9))
            g.stroke(p, with: .color(pupil), style: StrokeStyle(lineWidth: lw, lineCap: .round))
        case .cross:
            var p = Path()
            p.move(to: CGPoint(x: c.x - r * 0.8, y: c.y - r * 0.8)); p.addLine(to: CGPoint(x: c.x + r * 0.8, y: c.y + r * 0.8))
            p.move(to: CGPoint(x: c.x + r * 0.8, y: c.y - r * 0.8)); p.addLine(to: CGPoint(x: c.x - r * 0.8, y: c.y + r * 0.8))
            g.stroke(p, with: .color(pupil), style: StrokeStyle(lineWidth: lw, lineCap: .round))
        case .dot:
            let pr = r * 0.45
            g.fill(Path(ellipseIn: CGRect(x: c.x - pr, y: c.y - pr, width: pr * 2, height: pr * 2)), with: .color(pupil))
        }
    }

    // MARK: Blob

    func drawBlob(_ g: inout GraphicsContext) {
        let s = min(size.width, size.height)
        let cx = size.width / 2
        let r = s * 0.38
        let cy = size.height * 0.56 + bob
        let n = 9
        var pts: [CGPoint] = []
        for k in 0..<n {
            let a = Double(k) / Double(n) * .pi * 2 - .pi / 2
            let wobble = 0.07 * sin(Double(k) * 2.3 + phase) + 0
            let rr = r * CGFloat(1 + wobble)
            // Slightly wider at the bottom - the shape of a blob / a "sitting" creature.
            let flatten: CGFloat = sin(a) > 0 ? 1.08 : 1
            pts.append(CGPoint(x: cx + CGFloat(cos(a)) * rr * flatten * (2 - squash),
                               y: cy + CGFloat(sin(a)) * rr * squash))
        }
        let body = smoothClosedPath(pts)
        g.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(0.25), radius: s * 0.04, y: s * 0.03))
            l.fill(body, with: .linearGradient(Gradient(colors: [lightColor, bodyColor, darkColor]),
                                               startPoint: CGPoint(x: cx, y: cy - r), endPoint: CGPoint(x: cx, y: cy + r)))
        }
        // Highlight
        g.fill(Path(ellipseIn: CGRect(x: cx - r * 0.55, y: cy - r * 0.78, width: r * 0.45, height: r * 0.28)),
               with: .color(.white.opacity(0.55)))
        // Little horns/ears from the seed
        if bits(20, 1) == 1 {
            for side in [-1.0, 1.0] {
                let base = CGPoint(x: cx + CGFloat(side) * r * 0.45, y: cy - r * 0.85)
                g.fill(Path(ellipseIn: CGRect(x: base.x - r * 0.13, y: base.y - r * 0.2, width: r * 0.26, height: r * 0.3)), with: .color(bodyColor))
            }
        }
        let eyeR = r * (0.17 + CGFloat(bits(24, 2)) * 0.02)
        let gap = r * (0.36 + CGFloat(bits(26, 2)) * 0.04)
        let ey = cy - r * 0.08
        drawEye(&g, at: CGPoint(x: cx - gap, y: ey), r: eyeR, pupil: Color(white: 0.12))
        drawEye(&g, at: CGPoint(x: cx + gap, y: ey), r: eyeR, pupil: Color(white: 0.12))
        // Blush
        if state == .done || state == .working {
            for side in [-1.0, 1.0] {
                g.fill(Path(ellipseIn: CGRect(x: cx + CGFloat(side) * gap * 1.45 - r * 0.1, y: ey + r * 0.3, width: r * 0.2, height: r * 0.1)),
                       with: .color(.pink.opacity(0.5)))
            }
        }
    }

    // MARK: Bot

    func drawBot(_ g: inout GraphicsContext) {
        let s = min(size.width, size.height)
        let w = s * 0.74, h = s * 0.58
        let cx = size.width / 2
        let cy = size.height * 0.6 + bob
        let head = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h * squash)
        // Antenna
        let topY = head.minY
        var ant = Path()
        ant.move(to: CGPoint(x: cx, y: topY))
        ant.addLine(to: CGPoint(x: cx, y: topY - s * 0.14))
        g.stroke(ant, with: .color(darkColor), style: StrokeStyle(lineWidth: max(1.5, s * 0.05), lineCap: .round))
        let ballR = s * 0.065
        let waiting = state == .waitingPermission
        let ballColor: Color = waiting ? .orange : (state == .error ? .red : lightColor)
        g.fill(Path(ellipseIn: CGRect(x: cx - ballR, y: topY - s * 0.14 - ballR, width: ballR * 2, height: ballR * 2)), with: .color(ballColor))
        // Ears
        for side in [-1.0, 1.0] {
            let ex = side < 0 ? head.minX - s * 0.06 : head.maxX
            g.fill(Path(roundedRect: CGRect(x: ex, y: cy - s * 0.09, width: s * 0.06, height: s * 0.18), cornerRadius: s * 0.02), with: .color(darkColor))
        }
        g.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(0.25), radius: s * 0.04, y: s * 0.03))
            l.fill(Path(roundedRect: head, cornerRadius: s * 0.14),
                   with: .linearGradient(Gradient(colors: [lightColor, bodyColor, darkColor]),
                                         startPoint: CGPoint(x: cx, y: head.minY), endPoint: CGPoint(x: cx, y: head.maxY)))
        }
        // Screen face
        let face = head.insetBy(dx: w * 0.12, dy: h * 0.17)
        g.fill(Path(roundedRect: face, cornerRadius: s * 0.08), with: .color(Color(white: 0.1).opacity(0.85)))
        let glow = Color(hue: (hue + 0.5).truncatingRemainder(dividingBy: 1), saturation: 0.6 * saturationScale + 0.1, brightness: 1)
        let er = face.height * 0.22
        let ey = face.midY
        drawEye(&g, at: CGPoint(x: face.midX - face.width * 0.24, y: ey), r: er, pupil: glow, sclera: glow.opacity(0.3))
        drawEye(&g, at: CGPoint(x: face.midX + face.width * 0.24, y: ey), r: er, pupil: glow, sclera: glow.opacity(0.3))
    }

    // MARK: Pixel

    func drawPixel(_ g: inout GraphicsContext) {
        let s = min(size.width, size.height)
        let n = 7
        let cell = s * 0.8 / CGFloat(n)
        let ox = (size.width - cell * CGFloat(n)) / 2
        let oy = (size.height - cell * CGFloat(n)) / 2 + s * 0.04 + bob
        // Symmetric 7x7 mask: the left half + the center from the seed bits, the base shape is always filled.
        var grid = Array(repeating: Array(repeating: false, count: n), count: n)
        var bit: UInt64 = 0
        for row in 0..<n {
            for col in 0...3 {
                let core = row >= 1 && row <= 5 && col >= 1   // body
                let on = core || ((seed >> (bit % 60)) & 1) == 1 && row > 0 && row < n
                bit += 1
                grid[row][col] = on
                grid[row][n - 1 - col] = on
            }
        }
        // Feet
        grid[6][2] = true; grid[6][4] = true; grid[6][3] = false
        let eyeRow = 2
        for row in 0..<n {
            for col in 0..<n where grid[row][col] {
                let rect = CGRect(x: ox + CGFloat(col) * cell, y: oy + CGFloat(row) * cell * squash, width: cell * 0.92, height: cell * 0.92 * squash)
                let shade = Double(row) / Double(n)
                let c = Color(hue: hue, saturation: (0.45 + shade * 0.25) * saturationScale, brightness: 1 - shade * 0.3)
                g.fill(Path(roundedRect: rect, cornerRadius: cell * 0.2), with: .color(c))
            }
        }
        for col in [2, 4] {
            let c = CGPoint(x: ox + (CGFloat(col) + 0.46) * cell + lookX * 0.5, y: oy + (CGFloat(eyeRow) + 0.46) * cell)
            drawEye(&g, at: c, r: cell * 0.48, pupil: Color(white: 0.1))
        }
    }

    // MARK: Geometry

    private func smoothClosedPath(_ pts: [CGPoint]) -> Path {
        var p = Path()
        let n = pts.count
        guard n > 2 else { return p }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        p.move(to: mid(pts[n - 1], pts[0]))
        for i in 0..<n {
            p.addQuadCurve(to: mid(pts[i], pts[(i + 1) % n]), control: pts[i])
        }
        p.closeSubpath()
        return p
    }
}
