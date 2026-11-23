import CoreGraphics
import Testing
@testable import AgentHudCore

@Suite struct TokenLayoutTests {
    let vf = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let tok = CGSize(width: 96, height: 108)

    func slot(_ i: Int) -> CGPoint { TokenLayout.defaultSlot(index: i, in: vf, tokenSize: tok) }

    @Test func gridStartsTopRightAndFillsLeftwards() {
        let a = slot(0), b = slot(1)
        #expect(a.x + tok.width == vf.maxX - TokenLayout.margin)
        #expect(a.y + tok.height == vf.maxY - TokenLayout.margin)
        #expect(b.y == a.y)
        #expect(a.x - b.x == tok.width + TokenLayout.gap)
    }

    @Test func gridWrapsToNextRow() {
        let cols = Int((vf.width - 24 + 8) / 104)
        let first = slot(0), wrapped = slot(cols)
        #expect(wrapped.x == first.x)
        #expect(first.y - wrapped.y == tok.height + TokenLayout.gap)
        #expect(slot(cols - 1).x >= vf.minX + TokenLayout.margin)
    }

    @Test func freeSlotSkipsOccupied() {
        let taken = [CGRect(origin: slot(0), size: tok), CGRect(origin: slot(1), size: tok)]
        #expect(TokenLayout.freeSlot(in: vf, tokenSize: tok, occupied: taken) == slot(2))
        #expect(TokenLayout.freeSlot(in: vf, tokenSize: tok, occupied: []) == slot(0))
        // A token dragged halfway onto slot 0 still blocks it.
        let nudged = CGRect(x: slot(0).x - 40, y: slot(0).y + 30, width: tok.width, height: tok.height)
        #expect(TokenLayout.freeSlot(in: vf, tokenSize: tok, occupied: [nudged]) != slot(0))
    }

    @Test func clampOnAllEdges() {
        let r = CGRect(x: 0, y: 0, width: 96, height: 108)
        #expect(TokenLayout.clamp(r.offsetBy(dx: -50, dy: 300), to: vf).minX == 0)
        #expect(TokenLayout.clamp(r.offsetBy(dx: 2000, dy: 300), to: vf).maxX == vf.maxX)
        #expect(TokenLayout.clamp(r.offsetBy(dx: 300, dy: -90), to: vf).minY == 0)
        #expect(TokenLayout.clamp(r.offsetBy(dx: 300, dy: 2000), to: vf).maxY == vf.maxY)
        let inside = r.offsetBy(dx: 300, dy: 300)
        #expect(TokenLayout.clamp(inside, to: vf) == inside)
    }

    let card = CGSize(width: 380, height: 560)

    @Test func cardBelowRightAlignedInRightHalf() {
        let t = CGRect(x: 1300, y: 780, width: 96, height: 108)
        let c = TokenLayout.cardFrame(token: t, cardSize: card, in: vf)
        #expect(c.maxY == t.minY - TokenLayout.gap)
        #expect(c.maxX == t.maxX)
        #expect(c.size == card)
    }

    @Test func cardBelowLeftAlignedInLeftHalf() {
        let t = CGRect(x: 100, y: 780, width: 96, height: 108)
        let c = TokenLayout.cardFrame(token: t, cardSize: card, in: vf)
        #expect(c.maxY == t.minY - TokenLayout.gap)
        #expect(c.minX == t.minX)
    }

    @Test func cardGoesAboveWhenBelowDoesNotFit() {
        let t = CGRect(x: 1300, y: 100, width: 96, height: 108)
        let c = TokenLayout.cardFrame(token: t, cardSize: card, in: vf)
        #expect(c.minY == t.maxY + TokenLayout.gap)
        #expect(vf.contains(c))
    }

    @Test func cardStaysInsideAndNeverCoversTokenWhenSpaceExists() {
        for x in stride(from: CGFloat(0), through: 1344, by: 96) {
            for y in stride(from: CGFloat(0), through: 792, by: 108) {
                let t = CGRect(x: x, y: y, width: 96, height: 108)
                let c = TokenLayout.cardFrame(token: t, cardSize: card, in: vf)
                #expect(vf.contains(c))
                let fitsBelow = t.minY - 8 - card.height >= vf.minY
                let fitsAbove = t.maxY + 8 + card.height <= vf.maxY
                if fitsBelow || fitsAbove { #expect(!c.intersects(t)) }
            }
        }
    }

    @Test func tinyScreenFallbackStaysInside() {
        let small = CGRect(x: 0, y: 0, width: 300, height: 400)
        let t = CGRect(x: 100, y: 150, width: 96, height: 108)
        let c = TokenLayout.cardFrame(token: t, cardSize: card, in: small)
        #expect(small.contains(c))
        #expect(c.width == 300 && c.height == 400)
    }

    @Test func positionRoundTrip() {
        let p = CGPoint(x: -120.5, y: 733.25)
        #expect(TokenLayout.decode(TokenLayout.encode(p)) == p)
        #expect(TokenLayout.decode("nope") == nil)
        #expect(TokenLayout.decode("1,2,3") == nil)
        #expect(TokenLayout.decode("nan,1") == nil)
    }

    @Test func clickVersusDrag() {
        let d = CGPoint(x: 50, y: 50)
        #expect(!TokenLayout.isDrag(from: d, to: d))
        #expect(!TokenLayout.isDrag(from: d, to: CGPoint(x: 53, y: 52)))     // 3.6 pt
        #expect(!TokenLayout.isDrag(from: d, to: CGPoint(x: 54, y: 50)))     // exactly 4 pt is still a click
        #expect(TokenLayout.isDrag(from: d, to: CGPoint(x: 54.5, y: 50)))
        #expect(TokenLayout.isDrag(from: d, to: CGPoint(x: 47, y: 46)))      // 5 pt diagonal
    }
}
