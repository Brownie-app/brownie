import Testing
import Foundation
@testable import Proactive
import Domain

/// Every ledger now asks `PersonKey` whether two names are one person, so the same spellings that fold in
/// one place fold in all of them: the loops ledger, the household ledger, card dedupe, the quiet check, the asks.
@Suite struct PersonMatchTests {
    let now = Date(timeIntervalSince1970: 1_758_000_000)
    func loop(_ person: String, _ what: String, dir: LoopDirection = .mine, id: String = UUID().uuidString) -> Loop {
        Loop(id: id, direction: dir, person: person, what: what, quote: "q", sourceLabel: "WhatsApp · Fri", due: nil, openedAt: now)
    }
    func card(_ id: String, to person: String, draft: String, state: CardState = .ready, resolvedAgo: TimeInterval? = nil) -> Card {
        var c = Card(id: id, title: "Update \(person)", sourceLabel: "WhatsApp", why: "", actionLabel: "", dueLine: "", urgency: .medium, draftLabel: "", draft: draft, recipe: .whatsapp(chat: person, body: draft), evidence: [], verification: .verified, verifiedLine: "", state: state, createdAt: now.addingTimeInterval(-600))
        if let r = resolvedAgo { c.resolvedAt = now.addingTimeInterval(-r) }
        return c
    }

    @Test func loopsAboutOnePersonUnderTwoSpellingsMerge() {
        let existing = [loop("Lalita Pathak Tideline", "send the perpetual licensing update")]
        let out = LoopLedger.merge(existing: existing, found: [loop("Lalita Pathak", "perpetual licensing update to send")], updates: [], items: [], now: now)
        #expect(out.count == 1, "the chat's suffix is not a second person")
        #expect(LoopLedger.same(loop("Lokesh (+919000000111)", "share the postgres url"), loop("Lokesh", "share the postgres url")))
        #expect(!LoopLedger.same(loop("Lalita Dalal", "send the update"), loop("Lalita Pathak", "send the update")), "another surname is another person")
        #expect(LoopLedger.merge(existing: [loop("Lalita Dalal", "send the update")], found: [loop("Lalita Pathak", "send the update")], updates: [], items: [], now: now).count == 2)
    }

    @Test func householdLoopsFoldByTheSameRule() {
        let a = HouseholdEntry(loopID: "A", memberID: "m-v", person: "Lokesh (+919000000111)", what: "book the table for 12", direction: .mine, owner: "either", status: .open, updatedAt: now)
        let b = HouseholdEntry(loopID: "B", memberID: "m-p", person: "Lokesh", what: "table for 12 to book", direction: .mine, owner: "either", status: .closed, closedBy: "m-p", updatedAt: now.addingTimeInterval(60))
        let merged = HouseholdLedger.merge([a], [b], now: now)
        #expect(merged.count == 1 && merged[0].loopID == "A" && merged[0].status == .closed, "the other Mac's closure lands on the earlier id")
        let c = HouseholdEntry(loopID: "C", memberID: "m-p", person: "Tanvi", what: "table for 12 to book", direction: .mine, owner: "either", status: .open, updatedAt: now)
        #expect(HouseholdLedger.merge([a], [c], now: now).count == 2)
    }

    @Test func cardsToOnePersonUnderTwoSpellingsAreOneCard() {
        let a = card("a", to: "Lalita Pathak Tideline", draft: "Hi Lalita, quick update on the perpetual licensing option, details after we connect.")
        let b = card("b", to: "Lalita Pathak", draft: "Hi Lalita, quick update on the perpetual licensing option, the details after we connect.")
        #expect(CardDedupe.dedupe([a, b]).map(\.id) == ["a"])
        let c = card("c", to: "Lalita Dalal", draft: "Hi Lalita, quick update on the perpetual licensing option, the details after we connect.")
        #expect(CardDedupe.dedupe([a, c]).count == 2, "a different surname keeps its card")
        let n = card("n", to: "+91 90000 00666", draft: "same words"), m = card("m", to: "+91 90000 00725", draft: "same words")
        #expect(CardDedupe.dedupe([n, m]).count == 2, "two unnamed numbers are not one person")
    }

    @Test func theQuietCheckKnowsYouWroteToThemWhateverTheChatIsCalled() {
        let sent = card("old", to: "Lalita Pathak Tideline", draft: "hi", state: .fired, resolvedAgo: 120)
        let r = QuietCheck.run(cards: [card("new", to: "Lalita Pathak", draft: "hi")], loops: [], past: [sent], noteUpdated: { _ in nil }, fileExists: { _ in true }, now: now, staleDays: 7)
        #expect(r.kept.isEmpty && r.dropped.first?.why == "you wrote to Lalita 2 minutes ago")
        #expect(QuietCheck.samePerson("Lokesh (+919000000111)", "Lokesh") && !QuietCheck.samePerson(nil, "Lokesh") && !QuietCheck.samePerson("Lalita Dalal", "Lalita Pathak"))
    }

    @Test func theAsksLedgerUsesTheSameMatcher() {
        #expect(AskLedger.samePerson("Lalita Pathak Tideline", "Lalita Pathak") == PersonKey.same("Lalita Pathak Tideline", "Lalita Pathak"))
        #expect(AskLedger.samePerson("Kiran", "Kiran Bose") == PersonKey.same("Kiran", "Kiran Bose"))
        #expect(!AskLedger.samePerson("Lalita Dalal", "Lalita Pathak") && !AskLedger.samePerson("", ""))
    }
}
