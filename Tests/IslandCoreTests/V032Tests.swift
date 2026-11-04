import XCTest
@testable import IslandCore

/// v0.3.2: the bare notch at rest, every visible piece takes clicks, the shelf is visible.
final class RestingShapeTests: XCTestCase {
    let notch = NotchMetrics(width: 185, height: 32, hasNotch: true)
    var bare: IslandSize { IslandSize(w: 185, h: 32, r: 9) }

    func testVersion() {
        XCTAssertEqual(helperVersion, "0.3.2")
        XCTAssertEqual(protocolVersion, 1)
    }

    func testNoWingsWhenIdle() {
        XCTAssertFalse(wingsLive(.rest, transferLive: false))
        XCTAssertFalse(wingsLive(IslandView(mode: "rest", badge: 3), transferLive: false))
        XCTAssertFalse(wingsLive(IslandView(mode: "", badge: 1), transferLive: false))
        // the morning moves sit on the notch only during the host's intro (open: true)
        XCTAssertFalse(wingsLive(IslandView(mode: "moves", glyph: "plan", moves: [MoveInfo(id: "m1", title: "a")], badge: 3), transferLive: false))
        XCTAssertFalse(wingsLive(IslandView(mode: "moves", open: false, badge: 2), transferLive: false))
        XCTAssertTrue(wingsLive(IslandView(mode: "moves", open: true, badge: 2), transferLive: false))
        XCTAssertFalse(wingsLive(IslandView(mode: "capture", open: false), transferLive: false))
    }

    func testWingsForLiveThings() {
        XCTAssertTrue(wingsLive(.rest, transferLive: true))
        XCTAssertTrue(wingsLive(IslandView(mode: "deck", glyph: "read", startedAt: 0), transferLive: false))
        XCTAssertTrue(wingsLive(IslandView(mode: "ask", ask: AskInfo(id: "a", question: "q")), transferLive: false))
        XCTAssertTrue(wingsLive(IslandView(mode: "meeting", meeting: MeetingInfo(title: "Call", startsAt: 1)), transferLive: false))
        XCTAssertTrue(wingsLive(IslandView(mode: "weather"), transferLive: false))
    }

    func testIdleShapeIsTheBareNotch() {
        let idle: [IslandView] = [
            .rest,
            IslandView(mode: "rest", badge: 3),
            IslandView(mode: "rest", peek: "3 moves", badge: 3),
            IslandView(mode: "moves", glyph: "plan", moves: [MoveInfo(id: "m1", title: "a")], peek: "1 move", badge: 1),
            IslandView(mode: "moves", open: false, moves: [MoveInfo(id: "m1", title: "a"), MoveInfo(id: "m2", title: "b"), MoveInfo(id: "m3", title: "c")], badge: 3),
        ]
        for v in idle {
            XCTAssertEqual(islandSize(v, expanded: false, tray: false, notch: notch), bare, "\(v.mode) badge=\(String(describing: v.badge))")
        }
    }

    func testLiveCompactStaysNarrow() {
        let ask = islandSize(IslandView(mode: "ask"), expanded: false, tray: false, notch: notch)
        XCTAssertEqual(ask, IslandSize(w: 185 + 2 * Layout.wing, h: 32, r: 12))
        XCTAssertLessThanOrEqual(Layout.wing, 56)
        let moving = islandSize(.rest, expanded: false, tray: false, notch: notch, transferLive: true)
        XCTAssertEqual(moving.w, ask.w)
        let intro = islandSize(IslandView(mode: "moves", open: true), expanded: false, tray: false, notch: notch)
        XCTAssertEqual(intro.w, ask.w)
    }
}

final class HitTestTests: XCTestCase {
    let notch = NotchMetrics(width: 185, height: 32, hasNotch: true)
    let cw = Layout.canvasW
    let ch = Layout.canvasH

    func testRestOnlyTheNotchTakesClicks() {
        let s = islandSize(IslandView(mode: "rest", badge: 2), expanded: false, tray: false, notch: notch)
        // where 0.3.0 / 0.3.1 drew the count wing: the menu bar behind it must get the click
        let wing = islandHit(x: cw / 2 + 130, y: ch - 16, size: s, notch: notch, wings: false, tray: false, trayH: nil, accepting: false, buttonDown: false)
        XCTAssertFalse(wing.take)
        XCTAssertFalse(wing.inHot)
        let onNotch = islandHit(x: cw / 2, y: ch - 16, size: s, notch: notch, wings: false, tray: false, trayH: nil, accepting: false, buttonDown: false)
        XCTAssertTrue(onNotch.take)
        XCTAssertTrue(onNotch.inHot)
        let below = islandHit(x: cw / 2, y: ch - 60, size: s, notch: notch, wings: false, tray: false, trayH: nil, accepting: false, buttonDown: false)
        XCTAssertFalse(below.take)
    }

    func testLiveWingsTakeClicks() {
        let s = islandSize(IslandView(mode: "ask"), expanded: false, tray: false, notch: notch)
        let wing = islandHit(x: cw / 2 + s.w / 2 - 10, y: ch - 16, size: s, notch: notch, wings: true, tray: false, trayH: nil, accepting: false, buttonDown: false)
        XCTAssertTrue(wing.take)
        XCTAssertTrue(wing.inHot)
        let outside = islandHit(x: cw / 2 + s.w / 2 + 20, y: ch - 16, size: s, notch: notch, wings: true, tray: false, trayH: nil, accepting: false, buttonDown: false)
        XCTAssertFalse(outside.take)
    }

    func testTrayStripTakesClicksBodyPassesThrough() {
        let s = islandSize(.rest, expanded: false, tray: true, notch: notch, trayH: 236)
        XCTAssertEqual(s.h, 32 + 236)
        // the strip beside the notch across the top of the open tray (the "1" he clicked): the island takes it
        let strip = islandHit(x: cw / 2 + 210, y: ch - 16, size: s, notch: notch, wings: false, tray: true, trayH: 236, accepting: false, buttonDown: false)
        XCTAssertTrue(strip.take)
        XCTAssertFalse(strip.trayBody)
        // the tray body: Brain's window above answers there
        let body = islandHit(x: cw / 2, y: ch - 32 - 100, size: s, notch: notch, wings: false, tray: true, trayH: 236, accepting: false, buttonDown: false)
        XCTAssertTrue(body.trayBody)
        XCTAssertFalse(body.take)
        XCTAssertTrue(body.inShape)
        // beside the tray: click-through
        let beside = islandHit(x: cw / 2 + s.w / 2 + 12, y: ch - 100, size: s, notch: notch, wings: false, tray: true, trayH: 236, accepting: false, buttonDown: false)
        XCTAssertFalse(beside.take)
    }

    func testShelfBandUnderTrayTakesClicks() {
        let s = islandSize(.rest, expanded: false, tray: true, notch: notch, trayH: 236, shelfRows: 1)
        XCTAssertEqual(s.h, 32 + 236 + ShelfBand.height)
        let band = islandHit(x: cw / 2, y: ch - 32 - 236 - ShelfBand.height / 2, size: s, notch: notch, wings: false, tray: true, trayH: 236, accepting: false, buttonDown: false)
        XCTAssertTrue(band.take)
        XCTAssertFalse(band.trayBody)
        XCTAssertTrue(band.inHot)
    }
}

final class ShelfVisibilityTests: XCTestCase {
    let notch = NotchMetrics(width: 185, height: 32, hasNotch: true)

    func testPlace() {
        let rest = IslandView.rest
        let moves = IslandView(mode: "moves", moves: [MoveInfo(id: "m1", title: "a")])
        XCTAssertEqual(shelfPlace(rest, expanded: true, tray: false, trayH: nil, count: 0), .none)
        XCTAssertEqual(shelfPlace(rest, expanded: false, tray: false, trayH: nil, count: 2), .none)
        XCTAssertEqual(shelfPlace(rest, expanded: true, tray: false, trayH: nil, count: 2), .top)
        XCTAssertEqual(shelfPlace(moves, expanded: true, tray: false, trayH: nil, count: 1), .top)
        XCTAssertEqual(shelfPlace(IslandView(mode: "deck"), expanded: true, tray: false, trayH: nil, count: 1), .top)
        XCTAssertEqual(shelfPlace(IslandView(mode: "ask"), expanded: true, tray: false, trayH: nil, count: 1), .none)
        XCTAssertEqual(shelfPlace(IslandView(mode: "meeting"), expanded: true, tray: false, trayH: nil, count: 1), .none)
        XCTAssertEqual(shelfPlace(IslandView(mode: "capture"), expanded: true, tray: false, trayH: nil, count: 1), .none)
        // Brain's open view (the sized tray): the band sits under it
        XCTAssertEqual(shelfPlace(moves, expanded: false, tray: true, trayH: 236, count: 1), .trayBottom)
        XCTAssertEqual(shelfPlace(rest, expanded: true, tray: true, trayH: 236, count: 3), .trayBottom)
        XCTAssertEqual(shelfPlace(rest, expanded: true, tray: true, trayH: nil, count: 3), .none)
        XCTAssertEqual(shelfPlace(rest, expanded: false, tray: true, trayH: 236, count: 0), .none)
    }

    func testBandFitsEverywhere() {
        XCTAssertEqual(ShelfBand.height, ShelfBand.header + ShelfBand.gap + RestBody.shelfRow + ShelfBand.gap)
        for nh in [24.0, 32.0, 38.0] {
            let n = NotchMetrics(width: 185, height: nh, hasNotch: true)
            let tallest = islandSize(.rest, expanded: false, tray: true, notch: n, trayH: 5000, shelfRows: 1)
            XCTAssertEqual(tallest.h, nh + Layout.trayMaxH + ShelfBand.height)
            XCTAssertLessThanOrEqual(tallest.h, Layout.canvasH - 40)
        }
        XCTAssertEqual(Layout.trayMaxH, 400)
        let rest = islandSize(.rest, expanded: true, tray: false, notch: notch, shelfRows: 1, transferRows: 3, messageRow: true)
        XCTAssertGreaterThanOrEqual(rest.h, 32 + ShelfBand.height + RestBody.line + 3 * (RestBody.gap + RestBody.transferRow) + RestBody.button)
        XCTAssertGreaterThanOrEqual(rest.w, 32 + Double(RestBody.maxTiles) * (RestBody.tileW + 8))
        let plain = islandSize(.rest, expanded: true, tray: false, notch: notch)
        XCTAssertEqual(islandSize(.rest, expanded: true, tray: false, notch: notch, shelfRows: 1).h, plain.h + ShelfBand.height)
        let deck = IslandView(mode: "deck", now: "Working")
        XCTAssertEqual(islandSize(deck, expanded: true, tray: false, notch: notch, shelfRows: 1).h, 32 + Layout.deckExtra + ShelfBand.height)
    }
}
