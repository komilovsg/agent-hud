import CoreGraphics
import Foundation

/// Pure geometry for the floating session icons ("tokens") and their card.
/// AppKit screen coordinates: the origin is the bottom-left corner, y grows upwards.
public enum TokenLayout {
    public static let gap: CGFloat = 8
    public static let margin: CGFloat = 12

    /// Number of slots that fit in one row of the default grid (at least one).
    private static func columns(_ vf: CGRect, _ size: CGSize) -> Int {
        max(1, Int((vf.width - 2 * margin + gap) / (size.width + gap)))
    }

    private static func rows(_ vf: CGRect, _ size: CGSize) -> Int {
        max(1, Int((vf.height - 2 * margin + gap) / (size.height + gap)))
    }

    /// Slot `index` of a grid that starts at the top-right corner, fills leftwards, then goes one row down.
    /// Indexes past the last slot wrap around, so the result is always on screen.
    public static func defaultSlot(index: Int, in vf: CGRect, tokenSize: CGSize) -> CGPoint {
        let cols = columns(vf, tokenSize)
        let capacity = cols * rows(vf, tokenSize)
        let i = ((index % capacity) + capacity) % capacity
        let col = i % cols
        let row = i / cols
        return CGPoint(x: vf.maxX - margin - tokenSize.width - CGFloat(col) * (tokenSize.width + gap),
                       y: vf.maxY - margin - tokenSize.height - CGFloat(row) * (tokenSize.height + gap))
    }

    /// First default slot that does not touch any occupied frame; slot 0 if every slot is taken.
    public static func freeSlot(in vf: CGRect, tokenSize: CGSize, occupied: [CGRect]) -> CGPoint {
        let capacity = columns(vf, tokenSize) * rows(vf, tokenSize)
        for i in 0..<capacity {
            let p = defaultSlot(index: i, in: vf, tokenSize: tokenSize)
            let r = CGRect(origin: p, size: tokenSize)
            if !occupied.contains(where: { $0.intersects(r) }) { return p }
        }
        return defaultSlot(index: 0, in: vf, tokenSize: tokenSize)
    }

    /// Moves a frame so that it lies fully inside `vf` (the top-left wins if it is larger than `vf`).
    public static func clamp(_ frame: CGRect, to vf: CGRect) -> CGRect {
        var r = frame
        if r.maxX > vf.maxX { r.origin.x = vf.maxX - r.width }
        if r.maxY > vf.maxY { r.origin.y = vf.maxY - r.height }
        if r.minX < vf.minX { r.origin.x = vf.minX }
        if r.minY < vf.minY { r.origin.y = vf.minY }
        return r
    }

    /// Card placement: directly below the token (above if it does not fit below), aligned to the token's right edge
    /// when the token is in the right half of the screen and to its left edge otherwise. If neither fits vertically,
    /// the card goes beside the token. The result is always inside `vf`.
    public static func cardFrame(token: CGRect, cardSize: CGSize, in vf: CGRect) -> CGRect {
        let size = CGSize(width: min(cardSize.width, vf.width), height: min(cardSize.height, vf.height))
        let rightHalf = token.midX >= vf.midX
        let x = rightHalf ? token.maxX - size.width : token.minX
        let below = CGRect(x: x, y: token.minY - gap - size.height, width: size.width, height: size.height)
        if below.minY >= vf.minY { return clamp(below, to: vf) }
        let above = CGRect(x: x, y: token.maxY + gap, width: size.width, height: size.height)
        if above.maxY <= vf.maxY { return clamp(above, to: vf) }
        // Beside the token, top edges aligned.
        let sideX = rightHalf ? token.minX - gap - size.width : token.maxX + gap
        let side = CGRect(x: sideX, y: token.maxY - size.height, width: size.width, height: size.height)
        if side.minX >= vf.minX, side.maxX <= vf.maxX { return clamp(side, to: vf) }
        return clamp(below, to: vf)
    }

    // MARK: - Click or drag

    /// Pointer travel (points) after which a press on a token turns from a click into a drag.
    public static let dragThreshold: CGFloat = 4

    /// True when the pointer moved far enough from the press point that the gesture is a drag, not a click.
    public static func isDrag(from down: CGPoint, to current: CGPoint, threshold: CGFloat = dragThreshold) -> Bool {
        hypot(current.x - down.x, current.y - down.y) > threshold
    }

    // MARK: - Saved position

    public static func encode(_ p: CGPoint) -> String { "\(p.x),\(p.y)" }

    public static func decode(_ s: String) -> CGPoint? {
        let parts = s.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]), x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }
}
