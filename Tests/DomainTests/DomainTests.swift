import XCTest
@testable import Domain

final class DomainTests: XCTestCase {
    func testItemKeyOrderingUsesTiebreak() {
        XCTAssertTrue(ItemKey(order: 1, tiebreak: "a") < ItemKey(order: 1, tiebreak: "b"))
        XCTAssertTrue(ItemKey(order: 1, tiebreak: "z") < ItemKey(order: 2, tiebreak: "a"))
    }
    func testSurvivorOnlyWithKept() {
        XCTAssertEqual(Outcome(reason: .modelDrop).verdict, .drop)
        XCTAssertEqual(Outcome(reason: .piiBackstop).verdict, .sensitive)
    }
    func testRecipeWordsAndFireLabel() {
        let c = Card(id: "1", title: "t", sourceLabel: "iMessage", why: "", actionLabel: "", dueLine: "", urgency: .high, draftLabel: "", draft: "", recipe: .imessage(to: "Amma", body: "hi", attachments: ["a.pdf"]), evidence: [], verification: .verified, verifiedLine: "", createdAt: Date())
        XCTAssertEqual(c.fireLabel, "Send to Amma")
        XCTAssertEqual(c.recipe.stepsInWords.count, 3)
        XCTAssertTrue(c.recipe.stepsInWords.last!.contains("you press it"))
    }
    func testBrainResultJSONExtraction() {
        XCTAssertNotNil(BrainResult(text: "Sure! {\"a\":1} bye", usage: .zero).jsonData)
        XCTAssertNil(BrainResult(text: "no json here", usage: .zero).jsonData)
    }
}
