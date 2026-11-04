import XCTest
@testable import IslandCore

final class V031Tests: XCTestCase {
    // Files already there at start never become rows; only growth after start does.
    func testWarmupIsSilentBaseline() {
        var g = GrowthGate()
        XCTAssertEqual(g.observe(path: "/d/Arnie3 - 2_h264.mov", name: "Arnie3 - 2_h264.mov", bytes: 4_100_000, now: 0, warming: true), .ignore)
        XCTAssertEqual(g.baseline["/d/Arnie3 - 2_h264.mov"], 4_100_000)
        XCTAssertFalse(g.isWatching)
        // same size later (a touch, an FSEvent): still nothing
        XCTAssertEqual(g.observe(path: "/d/Arnie3 - 2_h264.mov", name: "Arnie3 - 2_h264.mov", bytes: 4_100_000, now: 100, warming: false), .ignore)
        // it grows after start: now it is a transfer
        XCTAssertEqual(g.observe(path: "/d/Arnie3 - 2_h264.mov", name: "Arnie3 - 2_h264.mov", bytes: 5_000_000, now: 101, warming: false), .promote)
    }

    func testTempFileAtWarmupIsWatchedAndShownWhenGrowing() {
        var g = GrowthGate()
        XCTAssertEqual(g.observe(path: "/d/a.zip.crdownload", name: "a.zip.crdownload", bytes: 100, now: 0, warming: true), .watch)
        XCTAssertTrue(g.candidatePaths.contains("/d/a.zip.crdownload"))
        XCTAssertEqual(g.observe(path: "/d/a.zip.crdownload", name: "a.zip.crdownload", bytes: 900, now: 1, warming: false), .promote)
    }

    // A Finder move or rename of a finished file appears whole and never grows: no row.
    func testFinderMoveIsNotATransfer() {
        var g = GrowthGate(watchFor: 8)
        let p = "/d/Exports/Arnie4 - 5_h264.mov"
        XCTAssertEqual(g.observe(path: p, name: "Arnie4 - 5_h264.mov", bytes: 7_000_000, now: 10, warming: false), .watch)
        XCTAssertEqual(g.observe(path: p, name: "Arnie4 - 5_h264.mov", bytes: 7_000_000, now: 13, warming: false), .watch)
        XCTAssertEqual(g.observe(path: p, name: "Arnie4 - 5_h264.mov", bytes: 7_000_000, now: 18.5, warming: false), .ignore)
        XCTAssertFalse(g.isWatching)
        XCTAssertEqual(g.observe(path: p, name: "Arnie4 - 5_h264.mov", bytes: 7_000_000, now: 30, warming: false), .ignore)
    }

    func testNewFileThatGrowsIsPromoted() {
        var g = GrowthGate()
        let p = "/d/Exports/cut.mov"
        XCTAssertEqual(g.observe(path: p, name: "cut.mov", bytes: 1_000, now: 0, warming: false), .watch)
        XCTAssertEqual(g.observe(path: p, name: "cut.mov", bytes: 2_000, now: 1, warming: false), .promote)
    }

    func testBrowserRenameIsExpected() {
        var g = GrowthGate()
        XCTAssertEqual(finalNameForTemp("/d/a.zip.crdownload"), "/d/a.zip")
        XCTAssertEqual(finalNameForTemp("/d/a.zip.part"), "/d/a.zip")
        XCTAssertNil(finalNameForTemp("/d/a.zip"))
        g.expect(finalPath: "/d/a.zip", now: 0)
        XCTAssertEqual(g.observe(path: "/d/a.zip", name: "a.zip", bytes: 500, now: 1, warming: false), .promote)
        // an old expectation does not promote
        g.expect(finalPath: "/d/b.zip", now: 0)
        XCTAssertEqual(g.observe(path: "/d/b.zip", name: "b.zip", bytes: 500, now: 100, warming: false), .watch)
    }

    func testSettledRowJoinsBaseline() {
        var g = GrowthGate()
        g.settle(path: "/d/x.mov", bytes: 9)
        XCTAssertEqual(g.observe(path: "/d/x.mov", name: "x.mov", bytes: 9, now: 0, warming: false), .ignore)
    }

    // The wing shows a finished transfer for a few seconds only; the tray keeps it two minutes.
    func testDoneWindow() {
        let done = Transfer(id: "p1", label: "a.mov", path: "/d/a.mov", kind: "export", state: "done", bytes: 10, updatedAt: 100, doneAt: 100)
        XCTAssertTrue(wingShowsTransfer(done, now: 103))
        XCTAssertFalse(wingShowsTransfer(done, now: 100 + wingDoneSeconds + 0.1))
        XCTAssertTrue(trayKeepsTransfer(done, now: 160))
        XCTAssertFalse(trayKeepsTransfer(done, now: 100 + trayDoneSeconds + 1))
        let d1 = transferDisplay([done], now: 102)
        XCTAssertEqual(d1.wing?.id, "p1")
        XCTAssertEqual(d1.tray.count, 1)
        XCTAssertEqual(d1.nextChange, 100 + wingDoneSeconds)
        let d2 = transferDisplay([done], now: 110)
        XCTAssertNil(d2.wing)
        XCTAssertEqual(d2.tray.count, 1)
        XCTAssertEqual(d2.nextChange, 100 + trayDoneSeconds)
        let d3 = transferDisplay([done], now: 300)
        XCTAssertNil(d3.wing)
        XCTAssertTrue(d3.tray.isEmpty)
        XCTAssertNil(d3.nextChange)
        // a done row without doneAt (never seen finishing) never takes the wing
        var old = done
        old.doneAt = nil
        XCTAssertFalse(wingShowsTransfer(old, now: 100))
        let active = Transfer(id: "p2", label: "b.mov", path: "/d/b.mov", kind: "export", state: "active", bytes: 5, updatedAt: 50)
        XCTAssertEqual(transferDisplay([done, active], now: 1000).wing?.id, "p2")
        XCTAssertEqual(transferDisplay([done, active], now: 1000).tray.map(\.id), ["p2"])
    }

    func testPublishOnlyOnChange() {
        let a = Transfer(id: "p1", label: "a", path: "/a", kind: "download", state: "active", bytes: 1, updatedAt: 1)
        let b = Transfer(id: "p2", label: "b", path: "/b", kind: "download", state: "done", bytes: 2, updatedAt: 2, doneAt: 2)
        XCTAssertFalse(transfersChanged([a, b], [b, a]))
        var a2 = a
        a2.bytes = 3
        XCTAssertTrue(transfersChanged([a, b], [b, a2]))
        XCTAssertTrue(transfersChanged([a], [a, b]))
        XCTAssertFalse(transfersChanged([], []))
    }

    // The open rest body is never shorter than what it draws.
    func testRestSizeFitsEveryRow() {
        let notch = NotchMetrics(width: 185, height: 32, hasNotch: true)
        let v = IslandView(mode: "rest", badge: 2)
        for t in 0...5 {
            for shelf in [0, 1] {
                for msg in [false, true] {
                    let s = islandSize(v, expanded: true, tray: false, notch: notch, shelfRows: shelf, transferRows: t, messageRow: msg)
                    var need = RestBody.topPad + RestBody.line + RestBody.gap + RestBody.button + RestBody.bottomPad
                    need += Double(min(3, t)) * (RestBody.gap + RestBody.transferRow)
                    if shelf > 0 { need += RestBody.gap + RestBody.shelfRow }
                    if msg { need += RestBody.gap + RestBody.line }
                    XCTAssertGreaterThanOrEqual(s.h, 32 + need, "t=\(t) shelf=\(shelf) msg=\(msg)")
                    XCTAssertLessThanOrEqual(s.h, Layout.canvasH - 40)
                }
            }
        }
        // three rows + shelf strip: wide enough for five tiles
        let wide = islandSize(v, expanded: true, tray: false, notch: notch, shelfRows: 1, transferRows: 3)
        XCTAssertGreaterThanOrEqual(wide.w, 32 + Double(RestBody.maxTiles) * (RestBody.tileW + 8))
    }

    // Moves show only moves: shelf rows do not change the moves body.
    func testMovesBodyIgnoresShelf() {
        let notch = NotchMetrics(width: 185, height: 32, hasNotch: true)
        let v = IslandView(mode: "moves", moves: [MoveInfo(id: "m1", title: "a"), MoveInfo(id: "m2", title: "b")])
        let a = islandSize(v, expanded: true, tray: false, notch: notch)
        let b = islandSize(v, expanded: true, tray: false, notch: notch, shelfRows: 1)
        XCTAssertEqual(a, b)
        XCTAssertGreaterThanOrEqual(a.h, 32 + 6 + 2 * Layout.moveRow)
    }

    func testExpandedRule() {
        XCTAssertFalse(wantsExpanded(hovering: false, hostOpen: false, ping: false, drop: false))
        XCTAssertTrue(wantsExpanded(hovering: false, hostOpen: false, ping: true, drop: false))
        XCTAssertTrue(wantsExpanded(hovering: false, hostOpen: false, ping: false, drop: true))
        XCTAssertTrue(pingSeconds <= 6)
    }
}
