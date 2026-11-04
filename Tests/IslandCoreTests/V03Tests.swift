import XCTest
@testable import IslandCore

final class V03ProtocolTests: XCTestCase {
    func testVersionAndCaps() {
        XCTAssertEqual(helperVersion, "0.3.0")
        XCTAssertEqual(protocolVersion, 1)
        for cap in ["traySize", "peek", "peekText", "countdown", "screenFrame", "settled", "moves", "shelf", "capture", "progress"] {
            XCTAssertTrue(capabilities.contains(cap), cap)
        }
    }

    func testMovesCaptureAndMeeting() {
        let line = #"{"t":"view","view":{"mode":"moves","open":true,"badge":3,"peek":"3 moves","moves":[{"id":"m1","title":"Send the one-pager","sub":"LabTested","kind":"email"},{"id":"m2","title":"Confirm the Zelle","sub":"Pacific Interlude","kind":"money"}]}}"#
        guard case let .view(v)? = decodeInbound(line) else { return XCTFail("moves") }
        XCTAssertEqual(v.moves?.count, 2)
        XCTAssertEqual(v.badge, 3)
        XCTAssertEqual(v.moves?.first?.id, "m1")
        XCTAssertFalse(v.isRest)

        let meet = #"{"t":"view","view":{"mode":"meeting","open":true,"meeting":{"id":"cal:1","title":"Buyer call","when":"Soon","startsAt":1730000000000,"brief":"You owe the one-pager.","join":true}}}"#
        guard case let .view(mv)? = decodeInbound(meet) else { return XCTFail("meeting") }
        XCTAssertEqual(mv.meeting?.id, "cal:1")
        XCTAssertEqual(mv.meeting?.startsAt, 1730000000000)
        XCTAssertEqual(mv.meeting?.brief, "You owe the one-pager.")

        let cap = #"{"t":"view","view":{"mode":"capture","open":true,"capture":{"id":"c1","prompt":"Note, to-do, or reminder","text":"","shelf":"s1"}}}"#
        guard case let .view(cv)? = decodeInbound(cap) else { return XCTFail("capture") }
        XCTAssertEqual(cv.capture?.shelf, "s1")
        XCTAssertEqual(decodeInbound(#"{"t":"captureText","id":"c1","text":"remind me","partial":true}"#), .captureText(id: "c1", text: "remind me", partial: true))
    }

    func testUnknownModeIsNotRest() {
        guard case let .view(v)? = decodeInbound(#"{"t":"view","view":{"mode":"weather","now":"72"}}"#) else { return XCTFail() }
        XCTAssertFalse(v.isRest)
        XCTAssertFalse(v.isKnown)
        let notch = NotchMetrics(width: 185, height: 32, hasNotch: true)
        let open = islandSize(v, expanded: true, tray: false, notch: notch)
        XCTAssertEqual(open.h, 32 + Layout.deckExtra)
    }

    func testShelfAndWatch() {
        XCTAssertEqual(decodeInbound(#"{"t":"shelfDir","path":"/tmp/shelf"}"#), .shelfDir("/tmp/shelf"))
        guard case let .shelf(items)? = decodeInbound(#"{"t":"shelf","items":[{"id":"s1","name":"PO.pdf","path":"/tmp/shelf/PO.pdf","bytes":12}]}"#) else { return XCTFail("shelf") }
        XCTAssertEqual(items.first?.bytes, 12)
        XCTAssertEqual(items.first?.linked, false)
        XCTAssertEqual(decodeInbound(#"{"t":"watch","dirs":["/tmp/Exports"]}"#), .watch(["/tmp/Exports"]))
        XCTAssertEqual(decodeInbound(#"{"t":"watch"}"#), .watch([]))
        XCTAssertNil(decodeInbound(#"{"t":"shelfDir"}"#))
        XCTAssertNil(decodeInbound(#"{"t":"captureText","text":"x"}"#))
    }

    func testTextDoesNotChangeGeometry() {
        let notch = NotchMetrics(width: 185, height: 32, hasNotch: true)
        var a = IslandView(mode: "deck", now: "Writing")
        var b = a
        b.now = "Still writing"
        let sa = islandSize(a, expanded: true, tray: false, notch: notch)
        let sb = islandSize(b, expanded: true, tray: false, notch: notch)
        XCTAssertEqual(sa, sb)
        XCTAssertFalse(shouldSpring(from: sa, to: sb))
        a.mode = "ask"
        XCTAssertTrue(shouldSpring(from: sa, to: islandSize(a, expanded: true, tray: false, notch: notch)))
    }

    func testScreenFields() {
        let n = NotchMetrics(width: 185, height: 32, hasNotch: true)
        let json = encodeEvent("screen", screenFields(notch: n, hz: 120, frameX: 466, frameY: 900, frameW: 580, frameH: 480, display: 1, scale: 2, displayX: 0, displayY: 0, displayW: 1512, displayH: 982))
        XCTAssertTrue(json.contains(#""origin":"appkit-bottom-left""#))
        XCTAssertTrue(json.contains(#""display":1"#))
        XCTAssertTrue(json.contains(#""scale":2"#))
        XCTAssertTrue(json.contains(#""ev":"screen""#))
    }

    func testBadgeGrowsTheRestingNotch() {
        let notch = NotchMetrics(width: 185, height: 32, hasNotch: true)
        let bare = islandSize(.rest, expanded: false, tray: false, notch: notch)
        XCTAssertEqual(bare.w, 185)
        let counted = islandSize(IslandView(mode: "rest", badge: 3), expanded: false, tray: false, notch: notch)
        XCTAssertEqual(counted.w, 185 + 2 * Layout.wing)
        let wing = islandSize(.rest, expanded: false, tray: false, notch: notch, forceWing: true)
        XCTAssertEqual(wing.w, counted.w)
    }
}

final class ShelfLogicTests: XCTestCase {
    func testParkDecisions() {
        XCTAssertEqual(decidePark(isDirectory: false, isPackage: false, bytes: 100, count: 0), .copy)
        XCTAssertEqual(decidePark(isDirectory: false, isPackage: false, bytes: shelfByteLimit + 1, count: 0), .link)
        XCTAssertEqual(decidePark(isDirectory: true, isPackage: false, bytes: 10, count: 0), .link)
        XCTAssertEqual(decidePark(isDirectory: false, isPackage: true, bytes: 10, count: 0), .link)
        XCTAssertEqual(decidePark(isDirectory: false, isPackage: false, bytes: 10, count: shelfCap), .refuse("shelf is full"))
        XCTAssertEqual(decidePark(isDirectory: false, isPackage: false, bytes: 10, count: 0, aliasBroken: true), .refuse("broken alias"))
    }

    func testNamesAndPaths() {
        XCTAssertEqual(uniqueShelfName("PO.pdf", taken: []), "PO.pdf")
        XCTAssertEqual(uniqueShelfName("PO.pdf", taken: ["PO.pdf"]), "PO 2.pdf")
        XCTAssertEqual(uniqueShelfName("PO.pdf", taken: ["PO.pdf", "PO 2.pdf"]), "PO 3.pdf")
        XCTAssertTrue(pathIsInside("/tmp/shelf/PO.pdf", directory: "/tmp/shelf"))
        XCTAssertFalse(pathIsInside("/tmp/shelf", directory: "/tmp/shelf"))
        XCTAssertFalse(pathIsInside("/tmp/shelf-other/a", directory: "/tmp/shelf"))
        XCTAssertFalse(pathIsInside("/tmp/shelf/../../etc/passwd", directory: "/tmp/shelf"))
        let kept = shelfItemsInside([
            ShelfItem(id: "a", name: "PO.pdf", path: "/tmp/shelf/PO.pdf"),
            ShelfItem(id: "b", name: "big.mov", path: "/Volumes/Media/big.mov", linked: true),
        ], directory: "/tmp/shelf")
        XCTAssertEqual(kept.map(\.id), ["a"])
    }
}

final class ProgressLogicTests: XCTestCase {
    func testClassify() {
        XCTAssertEqual(classifyGrowth(GrowthSample(name: "a.crdownload", bytes: 10, role: "downloads")), "download")
        XCTAssertEqual(classifyGrowth(GrowthSample(name: "shot.mov", bytes: 10, role: "downloads", quarantine: "sharingd")), "airdrop")
        XCTAssertEqual(classifyGrowth(GrowthSample(name: "Interview.mov", bytes: 10, role: "export", changed: true)), "export")
        XCTAssertNil(classifyGrowth(GrowthSample(name: "notes.txt", bytes: 10, role: "export")))
        XCTAssertEqual(classifyGrowth(GrowthSample(name: "file.bin", bytes: 10, role: "drive", changed: true)), "drive")
        XCTAssertNil(classifyGrowth(GrowthSample(name: "Interview.mov", bytes: 10, role: "other", apps: ["Mail"])))
        XCTAssertEqual(classifyGrowth(GrowthSample(name: "Interview.mov", bytes: 10, role: "other", apps: ["Final Cut Pro"])), "export")
        XCTAssertTrue(exportAppIsRunning(["Adobe Premiere Pro 2025"]))
    }

    func testSettledAndVisible() {
        XCTAssertFalse(isSettled(name: "a.crdownload", bytes: 100, stillSeconds: 30, media: false))
        XCTAssertFalse(isSettled(name: "a.mov", bytes: 100, stillSeconds: 2, media: true))
        XCTAssertTrue(isSettled(name: "a.mov", bytes: 100, stillSeconds: 3, media: true))
        XCTAssertFalse(isSettled(name: "a.mov", bytes: 4_000_000_000, stillSeconds: 4, media: true))
        XCTAssertTrue(isSettled(name: "a.mov", bytes: 4_000_000_000, stillSeconds: 5, media: true))
        let rows = (0..<5).map { Transfer(id: "\($0)", label: "f", path: "/t/\($0)", kind: "download", state: $0 < 2 ? "active" : "done", bytes: 1, updatedAt: Double($0)) }
        let shown = visibleTransfers(rows)
        XCTAssertEqual(shown.count, 3)
        XCTAssertEqual(shown.map(\.state), ["active", "active", "done"])
        XCTAssertEqual(doneWord(kind: "drive", publishedComplete: false), "copied")
        XCTAssertEqual(doneWord(kind: "drive", publishedComplete: true), "done")
        XCTAssertEqual(doneWord(kind: "export", publishedComplete: false), "done")
    }

    func testWatchDirs() {
        XCTAssertFalse(allowedWatchDir("/"))
        XCTAssertFalse(allowedWatchDir("/Users/a/Library/Messages"))
        XCTAssertFalse(allowedWatchDir("/Users/a/Library/Mail"))
        XCTAssertEqual(resolveWatchDirs([], downloads: "/Users/a/Downloads"), ["/Users/a/Downloads"])
        XCTAssertEqual(roleOfDir("/Users/a/Downloads"), "downloads")
        XCTAssertEqual(roleOfDir("/Users/a/Library/CloudStorage/GoogleDrive/My Drive"), "drive")
        XCTAssertEqual(roleOfDir("/Users/a/Movies/Exports"), "export")
        XCTAssertEqual(roleForFile("/Users/a/Movies/Exports/a.mov", dirs: ["/Users/a/Downloads", "/Users/a/Movies/Exports"]), "export")
        XCTAssertEqual(formatBytes(1536), "2 KB")
    }
}

final class KeysAndMoneyTests: XCTestCase {
    func testCaption() {
        let chords = parseKeyCaption("⌃⌥Y · ⌃⌥N")
        XCTAssertEqual(chords.count, 2)
        XCTAssertEqual(chords[0], KeyChord(action: "allow", key: "y", control: true, option: true))
        XCTAssertEqual(chords[1], KeyChord(action: "deny", key: "n", control: true, option: true))
        XCTAssertEqual(parseKeyCaption(""), [])
        XCTAssertEqual(parseKeyCaption("⌘⇧P").first?.command, true)
        XCTAssertEqual(parseKeyCaption("⌘⇧P").first?.key, "p")
    }

    func testCountdownAndPeek() {
        XCTAssertEqual(countdownLabel(startsAt: 10_000, now: 0), "in 10s")
        XCTAssertEqual(countdownLabel(startsAt: 240_000, now: 0), "in 4 min")
        XCTAssertEqual(countdownLabel(startsAt: 0, now: 0), "now")
        XCTAssertEqual(countdownLabel(startsAt: 0, now: 120_000), "started")
        XCTAssertEqual(restPeekText(peek: nil, badge: nil), "Nothing running")
        XCTAssertEqual(restPeekText(peek: "Clear", badge: 0), "Clear")
        XCTAssertEqual(restPeekText(peek: nil, badge: 3), "3 moves")
        XCTAssertEqual(restPeekText(peek: "3 moves · $4,800", badge: 3), "3 moves")
    }

    func testRedactMoneyLeavesTimesAlone() {
        XCTAssertEqual(redactMoney("Paid?"), "Paid?")
        XCTAssertEqual(redactMoney("in 4 min"), "in 4 min")
        XCTAssertEqual(redactMoney("$4,800"), "")
        XCTAssertEqual(redactMoney("USD 1200 outstanding"), "outstanding")
        XCTAssertEqual(redactMoney("Confirm Zelle"), "Confirm Zelle")
    }
}
