import Testing
import Foundation
@testable import Proactive
import Domain

/// Three Kanika cards about one promise became one; two different asks to the same person stay two.
@Suite struct CardDedupeTests {
    func card(_ id: String, title: String, why: String = "", draft: String = "", recipe: Recipe, urgency: Urgency = .medium, verified: Bool = true, loopID: String? = nil, age: TimeInterval = 0) -> Card {
        Card(id: id, title: title, sourceLabel: "s", why: why, actionLabel: "", dueLine: "", urgency: urgency, draftLabel: "", draft: draft, recipe: recipe, evidence: [], verification: verified ? .verified : .unverified, verifiedLine: "", createdAt: Date(timeIntervalSince1970: 1_700_000_000 - age), loopID: loopID)
    }

    @Test func sameLoopIsOneCard() {
        let a = card("a", title: "Send the perpetual licensing update", recipe: .computerUse(goal: "…"), urgency: .medium, loopID: "L1")
        let b = card("b", title: "Kanika Pandey update", recipe: .whatsapp(chat: "Kanika Pandey", body: "…"), urgency: .high, loopID: "L1")
        #expect(CardDedupe.dedupe([a, b]).map(\.id) == ["b"], "the more urgent one stays")
    }

    @Test func samePersonSameAskInOtherWordsIsOneCard() {
        let a = card("a", title: "Send the perpetual licensing update", why: "The promised update on the perpetual licensing option is still pending", draft: "Hi Kanika, quick update on the perpetual licensing option — I'll share details after we connect.", recipe: .whatsapp(chat: "Kanika Pandey Loadmill", body: "…"))
        let b = card("b", title: "Kanika Pandey update", why: "Overdue by 2 days: the perpetual licensing update you promised", draft: "Hi Kanika, quick update on the perpetual licensing option — I'll share the details after we connect.", recipe: .whatsapp(chat: "Kanika Pandey", body: "…"), verified: false)
        #expect(CardDedupe.dedupe([a, b]).map(\.id) == ["a"], "verified beats unverified; 'Kanika Pandey Loadmill' and 'Kanika Pandey' are one person")
    }

    @Test func differentAsksToTheSamePersonStay() {
        let a = card("a", title: "Send the perpetual licensing update", why: "Arif asked for perpetual pricing", draft: "Hi Kanika, the perpetual licence numbers are coming tomorrow.", recipe: .whatsapp(chat: "Kanika Pandey", body: "…"))
        let b = card("b", title: "Schedule Kanika's weekly sync", why: "You agreed a recurring weekly sync on 12 Sep", draft: "Setting up our weekly sync, invite follows.", recipe: .calendar(title: "Weekly sync", startISO: "", endISO: "", notes: ""))
        let c = card("c", title: "Confirm the weekly sync", why: "You agreed a recurring weekly sync on 12 Sep", draft: "Hi Kanika, setting up our weekly sync — invite follows.", recipe: .whatsapp(chat: "Kanika Pandey", body: "…"))
        #expect(CardDedupe.dedupe([a, b, c]).map(\.id) == ["a", "b", "c"], "a message and a calendar event about the same sync are two actions, and the licensing ask is a third")
    }

    @Test func differentPeopleNeverFold() {
        let a = card("a", title: "Reply about the villa", draft: "Villa hold ends tomorrow, shall we book?", recipe: .whatsapp(chat: "Rohan", body: "…"))
        let b = card("b", title: "Reply about the villa", draft: "Villa hold ends tomorrow, shall we book?", recipe: .whatsapp(chat: "Priya", body: "…"))
        #expect(CardDedupe.dedupe([a, b]).count == 2)
    }

    @Test func orderIsKeptAndTiesGoToTheEarlier() {
        let a = card("a", title: "Pay the deposit reminder", draft: "Reminder: deposit due Friday", recipe: .imessage(to: "Amma", body: "…", attachments: []), age: 10)
        let b = card("b", title: "Nudge about the deposit", draft: "Reminder: the deposit is due Friday", recipe: .imessage(to: "Amma", body: "…", attachments: []))
        let c = card("c", title: "Book the table", draft: "Table for 4 on Sunday?", recipe: .browser(url: "u"))
        #expect(CardDedupe.dedupe([c, b, a]).map(\.id) == ["c", "a"])
    }
}
