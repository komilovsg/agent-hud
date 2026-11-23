// Draws the Agent HUD icon and writes a 1024x1024 PNG.
// Usage: swift scripts/make-icon.swift <out-dir>   (creates <out-dir>/icon-1024.png)
//
// Rebuilding Resources/AppIcon.icns (keep intermediate files outside the repository):
//   D=<out-dir>; swift scripts/make-icon.swift $D
//   mkdir -p $D/AppIcon.iconset
//   for s in 16 32 128 256 512; do
//     sips -z $s $s $D/icon-1024.png --out $D/AppIcon.iconset/icon_${s}x${s}.png
//     sips -z $((s*2)) $((s*2)) $D/icon-1024.png --out $D/AppIcon.iconset/icon_${s}x${s}@2x.png
//   done
//   iconutil -c icns $D/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let S = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 32)!
NSGraphicsContext.saveGraphicsState()
let nsctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = nsctx
let ctx = nsctx.cgContext

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: a)
}
func rounded(_ r: CGRect, _ rad: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
}

// Background: rounded square 824x824, radius 185, vertical gradient
let shape = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.saveGState()
ctx.addPath(rounded(shape, 185))
ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [rgb(0x2B2A6B), rgb(0x0E0F24)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: shape.maxY), end: CGPoint(x: 0, y: shape.minY), options: [])
// Inner highlight along the top edge (2 px)
ctx.clip(to: CGRect(x: 0, y: shape.maxY - 90, width: 1024, height: 90))
ctx.addPath(rounded(shape.insetBy(dx: 1, dy: 1), 184))
ctx.setStrokeColor(rgb(0xFFFFFF, 0.12))
ctx.setLineWidth(2)
ctx.strokePath()
ctx.restoreGState()

// Session rows
let rowW: CGFloat = 440, rowH: CGFloat = 100, gap: CGFloat = 36
let x0 = 512 - rowW / 2
let totalH = rowH * 3 + gap * 2
let top = 512 + totalH / 2
let dots: [UInt32] = [0x34D399, 0xFBBF24, 0xF87171]
let lens: [CGFloat] = [250, 180, 110]
for i in 0..<3 {
    let y = top - rowH - CGFloat(i) * (rowH + gap)
    ctx.addPath(rounded(CGRect(x: x0, y: y, width: rowW, height: rowH), rowH / 2))
    ctx.setFillColor(rgb(0xFFFFFF, 0.14))
    ctx.fillPath()
    let d: CGFloat = 52
    ctx.setFillColor(rgb(dots[i]))
    ctx.fillEllipse(in: CGRect(x: x0 + 26, y: y + (rowH - d) / 2, width: d, height: d))
    let lh: CGFloat = 28
    ctx.addPath(rounded(CGRect(x: x0 + 26 + d + 26, y: y + (rowH - lh) / 2, width: lens[i], height: lh), lh / 2))
    ctx.setFillColor(rgb(0xFFFFFF, 0.85))
    ctx.fillPath()
}

// Viewfinder corner brackets
let half: CGFloat = 282, arm: CGFloat = 90
ctx.setStrokeColor(rgb(0xFFFFFF, 0.7))
ctx.setLineWidth(22)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
for (sx, sy) in [(-1.0, 1.0), (1.0, 1.0), (-1.0, -1.0), (1.0, -1.0)] as [(CGFloat, CGFloat)] {
    let cx = 512 + sx * half, cy = 512 + sy * half
    ctx.move(to: CGPoint(x: cx - sx * arm, y: cy))
    ctx.addLine(to: CGPoint(x: cx, y: cy))
    ctx.addLine(to: CGPoint(x: cx, y: cy - sy * arm))
    ctx.strokePath()
}

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
try! png.write(to: URL(fileURLWithPath: outDir + "/icon-1024.png"))
