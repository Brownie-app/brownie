import Testing
import Foundation
@testable import Domain

@Suite struct DomainTests {
    @Test func testItemKeyOrderingUsesTiebreak() {
        #expect(ItemKey(order: 1, tiebreak: "a") < ItemKey(order: 1, tiebreak: "b"))
        #expect(ItemKey(order: 1, tiebreak: "z") < ItemKey(order: 2, tiebreak: "a"))
    }
    @Test func testSurvivorOnlyWithKept() {
        #expect(Outcome(reason: .modelDrop).verdict == .drop)
        #expect(Outcome(reason: .piiBackstop).verdict == .sensitive)
    }
    @Test func testRecipeWordsAndFireLabel() {
        let c = Card(id: "1", title: "t", sourceLabel: "iMessage", why: "", actionLabel: "", dueLine: "", urgency: .high, draftLabel: "", draft: "", recipe: .imessage(to: "Amma", body: "hi", attachments: ["a.pdf"]), evidence: [], verification: .verified, verifiedLine: "", createdAt: Date())
        #expect(c.fireLabel == "Send to Amma")
        #expect(c.recipe.stepsInWords.count == 3)
        #expect(c.recipe.stepsInWords.last!.contains("you press it"))
    }
    @Test func testBrainResultJSONExtraction() {
        #expect(BrainResult(text: "Sure! {\"a\":1} bye", usage: .zero).jsonData != nil)
        #expect(BrainResult(text: "no json here", usage: .zero).jsonData == nil)
    }
}
