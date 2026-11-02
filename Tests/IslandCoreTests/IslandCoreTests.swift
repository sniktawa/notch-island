import XCTest
@testable import IslandCore

final class ProtocolTests: XCTestCase {
    func testDecodeView() {
        let line = #"{"t":"view","view":{"mode":"deck","glyph":"read","last":"Read a.csv 219 rows","now":"Writing the summary","startedAt":1000,"open":true}}"#
        guard case let .view(v)? = decodeInbound(line) else { return XCTFail("not a view") }
        XCTAssertEqual(v.mode, "deck")
        XCTAssertEqual(v.glyph, "read")
        XCTAssertEqual(v.last, "Read a.csv 219 rows")
        XCTAssertEqual(v.startedAt, 1000)
        XCTAssertEqual(v.open, true)
        XCTAssertFalse(v.isRest)
    }

    func testDecodeAskAndMeeting() {
        let a = #"{"t":"view","view":{"mode":"ask","ask":{"id":"ask:7","question":"Move these 3 to the Trash?","allow":"Move to Trash","deny":"Cancel","always":"Always","keys":"⌃⌥Y · ⌃⌥N"}}}"#
        guard case let .view(v)? = decodeInbound(a) else { return XCTFail("not a view") }
        XCTAssertEqual(v.ask, AskInfo(id: "ask:7", question: "Move these 3 to the Trash?", allow: "Move to Trash", deny: "Cancel", always: "Always", keys: "⌃⌥Y · ⌃⌥N"))
        let m = #"{"t":"view","view":{"mode":"meeting","meeting":{"title":"Call with Sam","when":"Starts in 4 min","join":true}}}"#
        guard case let .view(mv)? = decodeInbound(m) else { return XCTFail("not a view") }
        XCTAssertEqual(mv.meeting?.join, true)
    }

    func testOtherMessagesAndJunk() {
        XCTAssertEqual(decodeInbound(#"{"t":"tray","open":true}"#), .tray(true))
        XCTAssertEqual(decodeInbound(#"{"t":"tray"}"#), .tray(false))
        XCTAssertEqual(decodeInbound(#"{"t":"ping"}"#), .ping)
        XCTAssertEqual(decodeInbound(#"{"t":"quit"}"#), .quit)
        XCTAssertNil(decodeInbound(""))
        XCTAssertNil(decodeInbound("not json"))
        XCTAssertNil(decodeInbound(#"{"t":"view"}"#))
        XCTAssertNil(decodeInbound(#"{"t":"nope"}"#))
        // unknown fields are ignored
        guard case .view? = decodeInbound(#"{"t":"view","view":{"mode":"rest","extra":1}}"#) else { return XCTFail() }
    }

    func testEncodeEvent() {
        XCTAssertEqual(encodeEvent("hover"), #"{"ev":"hover"}"#)
        XCTAssertEqual(encodeEvent("action", ["id": "allow", "ask": "ask:7"]), #"{"ask":"ask:7","ev":"action","id":"allow"}"#)
    }

    func testLineBuffer() {
        var b = LineBuffer()
        XCTAssertEqual(b.feed(Data("{\"t\":\"pi".utf8)), [])
        XCTAssertEqual(b.feed(Data("ng\"}\n{\"t\":\"quit\"}\n{\"t".utf8)), [#"{"t":"ping"}"#, #"{"t":"quit"}"#])
        XCTAssertEqual(b.feed(Data("\":\"ping\"}\n".utf8)), [#"{"t":"ping"}"#])
        var small = LineBuffer(maxLine: 8)
        XCTAssertEqual(small.feed(Data("0123456789abc".utf8)), [])
        XCTAssertEqual(small.feed(Data("x\n".utf8)), ["x"])
    }
}

final class GeometryTests: XCTestCase {
    let notch = NotchMetrics(width: 185, height: 32, hasNotch: true)

    func testNotchMetrics() {
        XCTAssertEqual(notchMetrics(screenWidth: 1512, topInset: 32, leftAux: 663.5, rightAux: 663.5, menuBar: 37), NotchMetrics(width: 185, height: 32, hasNotch: true))
        XCTAssertEqual(notchMetrics(screenWidth: 2560, topInset: 0, leftAux: 0, rightAux: 0, menuBar: 25), NotchMetrics(width: fakeNotchWidth, height: 25, hasNotch: false))
    }

    func testSizes() {
        let rest = islandSize(.rest, expanded: false, tray: false, notch: notch)
        XCTAssertEqual(rest.w, 185)
        XCTAssertEqual(rest.h, 32)
        let deck = IslandView(mode: "deck", glyph: "read", startedAt: 0)
        let compact = islandSize(deck, expanded: false, tray: false, notch: notch)
        XCTAssertEqual(compact.w, 185 + 2 * Layout.wing)
        XCTAssertEqual(compact.h, 32)
        let open = islandSize(deck, expanded: true, tray: false, notch: notch)
        XCTAssertEqual(open.h, 32 + Layout.deckExtra)
        XCTAssertGreaterThanOrEqual(open.w, compact.w)
        let ask = islandSize(IslandView(mode: "ask"), expanded: true, tray: false, notch: notch)
        XCTAssertEqual(ask.h, 32 + Layout.askExtra)
        let tray = islandSize(deck, expanded: true, tray: true, notch: notch)
        XCTAssertEqual(tray, IslandSize(w: Layout.trayW, h: 32, r: 0))
        // everything fits the canvas with room for the shoulders and overshoot
        for s in [rest, compact, open, ask, tray] {
            XCTAssertLessThanOrEqual(s.w + 2 * Layout.shoulder, Layout.canvasW - 20)
            XCTAssertLessThanOrEqual(s.h, Layout.canvasH - 40)
        }
    }

    func testPathHasStableShape() {
        let a = islandPath(IslandSize(w: 185, h: 32, r: 9), canvasW: Layout.canvasW, canvasH: Layout.canvasH)
        let b = islandPath(IslandSize(w: 420, h: 124, r: 22), canvasW: Layout.canvasW, canvasH: Layout.canvasH)
        let c = islandPath(IslandSize(w: 520, h: 32, r: 0), canvasW: Layout.canvasW, canvasH: Layout.canvasH)
        XCTAssertEqual(a.count, 9)
        XCTAssertEqual(b.count, 9)
        XCTAssertEqual(c.count, 9)
        func kind(_ op: PathOp) -> Int {
            switch op {
            case .move: return 0
            case .line: return 1
            case .curve: return 2
            case .close: return 3
            }
        }
        XCTAssertEqual(a.map(kind), b.map(kind))
        XCTAssertEqual(a.map(kind), c.map(kind))
        // starts on the top edge, left of the island by the shoulder; centred
        guard case let .move(x0, y0) = b[0], case let .curve(_, _, _, _, xe, ye) = b[7] else { return XCTFail() }
        XCTAssertEqual(y0, Layout.canvasH)
        XCTAssertEqual(ye, Layout.canvasH)
        XCTAssertEqual(x0 + xe, Layout.canvasW, accuracy: 0.001)
        // bottom edge sits h below the top
        guard case let .line(_, yb) = b[4] else { return XCTFail() }
        XCTAssertEqual(yb, Layout.canvasH - 124)
    }

    func testRects() {
        let s = IslandSize(w: 313, h: 32, r: 12)
        let r = islandRect(s, canvasW: 580, canvasH: 200)
        XCTAssertTrue(r.contains(290, 190))
        XCTAssertFalse(r.contains(290, 150))
        XCTAssertTrue(r.contains(290, 166, pad: 4))
        let n = notchRect(notch, canvasW: 580, canvasH: 200)
        XCTAssertEqual(n.w, 185)
        XCTAssertEqual(n.y, 168)
    }

    func testElapsed() {
        XCTAssertEqual(elapsedText(0), "0:00")
        XCTAssertEqual(elapsedText(42.9), "0:42")
        XCTAssertEqual(elapsedText(725), "12:05")
        XCTAssertEqual(elapsedText(3723), "1:02:03")
        XCTAssertEqual(elapsedText(-5), "0:00")
    }
}

final class HoverTests: XCTestCase {
    func testRestOpensLeaveCloses() {
        var g = HoverGate()
        XCTAssertNil(g.update(x: 290, y: 190, t: 0, inHot: true, inShape: true))
        XCTAssertEqual(g.nextCheck() ?? 0, 0.3, accuracy: 1e-9)
        XCTAssertNil(g.update(x: 290, y: 190, t: 0.2, inHot: true, inShape: true))
        XCTAssertEqual(g.update(x: 290, y: 190, t: 0.31, inHot: true, inShape: true), .enter)
        XCTAssertTrue(g.hovering)
        XCTAssertNil(g.update(x: 290, y: 100, t: 1.0, inHot: false, inShape: false))
        XCTAssertEqual(g.nextCheck() ?? 0, 1.35, accuracy: 1e-9)
        XCTAssertNil(g.update(x: 290, y: 100, t: 1.2, inHot: false, inShape: false))
        XCTAssertEqual(g.update(x: 290, y: 100, t: 1.36, inHot: false, inShape: false), .leave)
        XCTAssertFalse(g.hovering)
    }

    func testFastPassDoesNotOpen() {
        var g = HoverGate()
        _ = g.update(x: 0, y: 190, t: 0, inHot: true, inShape: true)
        // 300 points in 0.1 s = 3000 pt/s: passing through, the rest restarts
        XCTAssertNil(g.update(x: 300, y: 190, t: 0.1, inHot: true, inShape: true))
        XCTAssertNil(g.update(x: 300, y: 190, t: 0.35, inHot: true, inShape: true))
        XCTAssertEqual(g.update(x: 300, y: 190, t: 0.41, inHot: true, inShape: true), .enter)
    }

    func testButtonAndComingBack() {
        var g = HoverGate()
        XCTAssertNil(g.update(x: 290, y: 190, t: 0, inHot: true, inShape: true, buttonDown: true))
        XCTAssertNil(g.update(x: 290, y: 190, t: 1, inHot: true, inShape: true, buttonDown: true))
        XCTAssertNil(g.nextCheck())
        _ = g.update(x: 290, y: 190, t: 2, inHot: true, inShape: true)
        XCTAssertEqual(g.update(x: 290, y: 190, t: 2.31, inHot: true, inShape: true), .enter)
        // leaving briefly and coming back keeps it open
        XCTAssertNil(g.update(x: 290, y: 100, t: 3, inHot: false, inShape: false))
        XCTAssertNil(g.update(x: 290, y: 190, t: 3.2, inHot: true, inShape: true))
        XCTAssertNil(g.update(x: 290, y: 190, t: 4, inHot: true, inShape: true))
        XCTAssertTrue(g.hovering)
        g.reset()
        XCTAssertFalse(g.hovering)
    }
}
