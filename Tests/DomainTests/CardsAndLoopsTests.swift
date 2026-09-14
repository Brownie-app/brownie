import XCTest
@testable import Domain

final class CardsAndLoopsTests: XCTestCase {
    func card(_ id: String, state: CardState = .ready, cameBack: Bool? = nil, loopID: String? = nil) -> Card {
        Card(id: id, title: "t", sourceLabel: "s", why: "", actionLabel: "", dueLine: "", urgency: .low, draftLabel: "", draft: "d", recipe: .browser(url: "https://x"), evidence: [], verification: .verified, verifiedLine: "", state: state, createdAt: Date(), cameBack: cameBack, loopID: loopID)
    }
    func testCardDecodesWithoutNewFields() throws {
        // Cards saved before loops existed have no cameBack/loopID; they must still load.
        var json = String(data: try JSONEncoder().encode(card("1")), encoding: .utf8)!
        XCTAssertFalse(json.contains("loopID"))
        json = json.replacingOccurrences(of: "\"cameBack\":", with: "\"zz\":")
        let c = try JSONDecoder().decode(Card.self, from: Data(json.utf8))
        XCTAssertFalse(c.isComeBack); XCTAssertNil(c.loopID)
    }
    func testWithDraftKeepsLoopFields() {
        let c = card("1", cameBack: true, loopID: "L").withDraft("new")
        XCTAssertEqual(c.draft, "new"); XCTAssertTrue(c.isComeBack); XCTAssertEqual(c.loopID, "L")
    }
    func testHousekeepingExpiresAndUnsnoozes() {
        let now = Date()
        let old = Card(id: "1", title: "t", sourceLabel: "s", why: "", actionLabel: "", dueLine: "", urgency: .low, draftLabel: "", draft: "", recipe: .browser(url: "u"), evidence: [], verification: .verified, verifiedLine: "", createdAt: now.addingTimeInterval(-3 * 86400))
        XCTAssertEqual(old.housekept(now: now).state, .expired)
        var s = card("2", state: .snoozed); s.snoozedUntil = now.addingTimeInterval(-60)
        XCTAssertEqual(s.housekept(now: now).state, .ready)
    }
    func testLoopRoundTripAndDefaults() throws {
        let l = Loop(direction: .mine, person: "Amma", what: "call", quote: "Sunday", sourceLabel: "iMessage · Thu", due: "Sunday", openedAt: Date())
        let back = try JSONDecoder().decode(Loop.self, from: JSONEncoder().encode(l))
        XCTAssertEqual(back, l); XCTAssertEqual(back.status, .open); XCTAssertEqual(back.cameBackCount, 0)
    }
    func testRunTriggerIncludesDaytime() throws {
        XCTAssertEqual(try JSONDecoder().decode(RunTrigger.self, from: Data("\"daytime\"".utf8)), .daytime)
    }
}
