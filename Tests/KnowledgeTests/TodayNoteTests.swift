import Testing
import Foundation
@testable import Knowledge
import Domain

/// Today.md: cards out as checkboxes, ticks back as “done”.
@Suite struct TodayNoteTests {
    let now = Date(timeIntervalSince1970: 1_758_000_000)
    func card(_ id: String, title: String, urgency: Urgency = .medium, state: CardState = .ready, draft: String = "", due: String = "") -> Card {
        Card(id: id, title: title, sourceLabel: "s", why: "because\nof this", actionLabel: "", dueLine: due, urgency: urgency, draftLabel: "", draft: draft, recipe: .browser(url: "u"), evidence: [], verification: .verified, verifiedLine: "", state: state, createdAt: now)
    }
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Kolkata")!; return c }

    @Test func rendersReadyCardsMostUrgentFirstWithHiddenIDs() {
        let md = TodayNote.render(cards: [card("a", title: "Reply to Rohan"), card("b", title: "Pay the deposit", urgency: .high, draft: "Paying\ntoday", due: "Due Friday"), card("c", title: "Old", state: .fired)], date: now, calendar: cal)
        #expect(md.hasPrefix("# Today — Tuesday 16 September"))
        let lines = md.split(separator: "\n").map(String.init)
        let cardLines = lines.filter { $0.hasPrefix("- [ ]") }
        #expect(cardLines.count == 2 && cardLines[0].contains("Pay the deposit") && cardLines[1].contains("Reply to Rohan"), "fired cards are not listed; urgent first")
        #expect(cardLines[0] == "- [ ] **Pay the deposit** — because of this · _Due Friday_ <!-- card:b -->")
        #expect(lines.contains("    > Paying") && lines.contains("    > today"), "the draft rides along as a quote")
        #expect(md.contains("a tick here only says “done”"))
    }

    @Test func emptyMorning() {
        #expect(TodayNote.render(cards: [], date: now, calendar: cal).contains("Nothing waiting this morning."))
    }

    @Test func parseReadsTicksHoweverThePhoneWroteThem() {
        let md = """
        # Today
        - [x] **Pay the deposit** — why <!-- card:b -->
            > draft
        - [ ] **Reply to Rohan** — why <!-- card:a -->
        - [X] **Book the table** — why <!--  card:c  -->
        - [ ] a line someone typed by hand with no id
        """
        #expect(TodayNote.parse(md) == [.init(cardID: "b", checked: true), .init(cardID: "a", checked: false), .init(cardID: "c", checked: true)])
    }

    @Test func roundTrip() {
        let md = TodayNote.render(cards: [card("a", title: "Reply to Rohan"), card("b", title: "Pay")], date: now, calendar: cal)
        #expect(TodayNote.parse(md).map(\.cardID).sorted() == ["a", "b"] && TodayNote.parse(md).allSatisfy { !$0.checked })
    }

    @Test func applyMarksTickedCardsDoneAndNothingElse() {
        var cards = [card("a", title: "A"), card("b", title: "B"), card("c", title: "C", state: .snoozed)]
        let changed = TodayNote.apply([.init(cardID: "a", checked: true), .init(cardID: "b", checked: false), .init(cardID: "c", checked: true), .init(cardID: "zzz", checked: true)], to: &cards, now: now)
        #expect(changed == ["a"], "only ready cards can be ticked; unknown ids are ignored")
        #expect(cards[0].state == .fired && cards[0].resolvedAt == now && cards[1].state == .ready && cards[2].state == .snoozed)
    }
}
