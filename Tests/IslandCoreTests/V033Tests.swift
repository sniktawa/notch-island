import XCTest
@testable import IslandCore

/// v0.3.3: a copied drop tells the host where it came from (`origin`); links and restores don't.
final class DropOriginTests: XCTestCase {
    func testOriginOnlyWhenKnown() {
        let copy = ShelfItem(id: "a", name: "clip.mov", path: "/shelf/clip.mov", bytes: 10, origin: "/Users/a/Desktop/clip.mov")
        XCTAssertEqual(copy.eventFields("add")["origin"] as? String, "/Users/a/Desktop/clip.mov")
        XCTAssertEqual(copy.eventFields("add")["op"] as? String, "add")
        XCTAssertEqual(copy.eventFields("add")["path"] as? String, "/shelf/clip.mov")
        let link = ShelfItem(id: "b", name: "Big", path: "/Users/a/Big", linked: true)
        XCTAssertNil(link.eventFields("add")["origin"])
        XCTAssertNil(ShelfItem(id: "c", name: "x", path: "/s/x", origin: "").eventFields("add")["origin"])
    }

    func testEncodedEventKeepsOldFields() throws {
        let line = encodeEvent("shelf", ShelfItem(id: "a", name: "n", path: "/s/n", bytes: 1, origin: "/o/n").eventFields("add"))
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(o["ev"] as? String, "shelf")
        XCTAssertEqual(o["id"] as? String, "a")
        XCTAssertEqual(o["path"] as? String, "/s/n")
        XCTAssertEqual(o["origin"] as? String, "/o/n")
        XCTAssertEqual(o["linked"] as? Bool, false)
    }

    func testRestoreDecodesWithoutOrigin() throws {
        let json = #"{"id":"a","name":"n","path":"/s/n","bytes":1,"linked":false}"#.data(using: .utf8)!
        let item = try JSONDecoder().decode(ShelfItem.self, from: json)
        XCTAssertNil(item.origin)
    }
}
