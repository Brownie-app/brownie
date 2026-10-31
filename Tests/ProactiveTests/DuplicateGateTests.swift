import Testing
import Foundation
import Domain
@testable import Proactive

/// UNIT. The two holes a dismissal used to fall through.
///
/// From a real ledger: twenty-three cards, of which four were about one subscription, three about turning
/// on two-factor somewhere, and two identically titled payment cards — with the user having dismissed one of each.
/// And twenty-two loops, of which seven were duplicates: the same container image promised three times, the
/// same hosting promised twice, the same update to Sam twice.
///
/// Neither pile-up was the model being stupid. Both were the matchers declining to compare: `twin` gave up
/// unless both cards named a person, and `merge` only ever compared a new loop against the open ones.
@Suite struct DuplicateGateTests {

    let now = Date(timeIntervalSinceReferenceDate: 814_900_000)

    func card(_ id: String, _ title: String, why: String = "", recipe: Recipe = .browser(url: "u"),
              state: CardState = .ready, resolvedAgo: TimeInterval? = nil) -> Card {
        var c = Card(id: id, title: title, sourceLabel: "s", why: why, actionLabel: "", dueLine: "", urgency: .medium,
                     draftLabel: "", draft: "", recipe: recipe, evidence: [], verification: .verified, verifiedLine: "",
                     state: state, createdAt: now.addingTimeInterval(-3600))
        if let r = resolvedAgo { c.resolvedAt = now.addingTimeInterval(-r) }
        return c
    }

    /// `from` is the message it came from — the thing that tells a promise found twice from a promise made
    /// twice. Nil stands for a loop written before spans existed, or one whose chat could not be read.
    func loop(_ what: String, person: String = "Ravi", status: LoopStatus = .open, closedAgo: TimeInterval? = nil,
              from: String? = nil, id: String = UUID().uuidString) -> Loop {
        var l = Loop(id: id, direction: .mine, person: person, what: what, quote: what, sourceLabel: "WhatsApp", due: nil, openedAt: now.addingTimeInterval(-10 * 86400))
        l.status = status
        if let c = closedAgo { l.closedAt = now.addingTimeInterval(-c) }
        if let from { l.span = Span(text: "…", messageID: from, said: now.addingTimeInterval(-10 * 86400)) }
        return l
    }

    // MARK: - Cards about nobody

    /// The hole. `CardDedupe.person` answers only for a card whose recipe is a message; a bill, a renewal or a
    /// setting has no person, so the old `twin` returned false before it compared a single word.
    @Test func twoCardsAboutNobodyAreStillComparedWithEachOther() {
        let dismissed = card("1", "Enable two-factor authentication", why: "your account has no second factor")
        let again = card("2", "Enable two-factor authentication", why: "your account has no second factor")
        #expect(QuietCheck.twin(dismissed, again))
    }

    @Test func aDismissedSettingCardDoesNotComeBackTheNextNight() {
        let past = card("1", "Fix the mail subscription payment", why: "the card on file was declined", state: .dismissed, resolvedAgo: 2 * 86400)
        let tonight = card("2", "Fix the mail subscription payment", why: "the card on file was declined")
        let out = QuietCheck.run(cards: [tonight], loops: [], past: [past], noteUpdated: { _ in nil }, fileExists: { _ in true },
                                 now: now, staleDays: QuietCheck.defaultStaleDays)
        #expect(out.kept.isEmpty)
        #expect(out.dropped.first?.why.contains("turned this down") == true)
    }

    /// The other half: two genuinely different errands with nobody on them must both still get through, which
    /// is why the bar for a nameless pair is higher than for a pair that share a person.
    @Test func twoDifferentErrandsAboutNobodyBothSurvive() {
        let a = card("1", "Renew the domain before it lapses", why: "usebrownie.com expires on the 30th")
        let b = card("2", "Enable two-factor authentication", why: "your account has no second factor")
        #expect(!QuietCheck.twin(a, b))
    }

    @Test func aSharedWordOrTwoIsNotEnoughToSilenceACard() {
        let a = card("1", "Update the mail subscription billing", why: "the plan price changed on 1 October")
        let b = card("2", "Check the mail subscription price change", why: "the provider wrote about a new rate for your seats")
        #expect(!QuietCheck.twin(a, b), "same subject, different errands — folding them loses one")
    }

    @Test func aCardWithAPersonIsStillMatchedOnThePersonAndNotOnWordsAlone() {
        let a = card("1", "Answer Ravi's open question", recipe: .whatsapp(chat: "Ravi", body: "hi"))
        let b = card("2", "Answer Ravi's open question", recipe: .whatsapp(chat: "Ravi", body: "hi"))
        let c = card("3", "Answer Tanvi's open question", recipe: .whatsapp(chat: "Tanvi", body: "hi"))
        #expect(QuietCheck.twin(a, b))
        #expect(!QuietCheck.twin(a, c), "the same sentence to two people is two errands")
    }

    /// One has a person and one does not: nothing proves they are the same errand, so neither silences the other.
    @Test func aNamedCardAndANamelessOneAreNeverTwins() {
        let named = card("1", "Fix the subscription payment", recipe: .whatsapp(chat: "Ravi", body: "hi"))
        let nameless = card("2", "Fix the subscription payment")
        #expect(!QuietCheck.twin(named, nameless))
    }

    // MARK: - Loops found again after they were done

    /// The same message, read again out of a summary the judge still has in its week. Not a new promise.
    @Test func aPromiseFoundAgainInTheSameMessageDoesNotOpenASecondTime() {
        let done = loop("Share the corrected api-worker:latest image", status: .closed, closedAgo: 3 * 86400, from: "msg-88")
        let found = loop("Share Ravi the corrected api-worker:latest image", from: "msg-88")
        let out = LoopLedger.merge(existing: [done], found: [found], updates: [], items: [], now: now)
        #expect(out.count == 1, "one message, one promise, one loop — it was closed, not forgotten")
        #expect(out[0].status == .closed)
    }

    @Test func thatHoldsEvenWhenTheIdInsideItCameBackGarbled() {
        let done = loop("Share the corrected api-worker:latest image with 100200300400500", status: .closed, closedAgo: 86400, from: "msg-88")
        let found = loop("Share Ravi the corrected api-worker:latest image with 10020030040050010", from: "msg-88")
        #expect(LoopLedger.merge(existing: [done], found: [found], updates: [], items: [], now: now).count == 1)
    }

    /// The limit, and the reason the rule is the message rather than a stretch of time: a thing genuinely
    /// promised again, in a later message, is a second promise and must get its own loop.
    @Test func thesSamePromiseInALaterMessageIsANewPromise() {
        let done = loop("Send the venue shortlist", person: "Dev", status: .closed, closedAgo: 86400, from: "msg-10")
        let found = loop("Send the venue shortlist", person: "Dev", from: "msg-77")
        let out = LoopLedger.merge(existing: [done], found: [found], updates: [], items: [], now: now)
        #expect(out.filter { $0.status == .open }.count == 1, "he asked again; that is a new promise")
    }

    /// And the conservative default: with no span there is no way to tell the two apart, so nothing changes
    /// from how the ledger has always behaved.
    @Test func withoutASpanAClosedLoopBlocksNothing() {
        let done = loop("Send the venue shortlist", person: "Dev", status: .closed, closedAgo: 86400)
        let found = loop("Send the venue shortlist", person: "Dev")
        #expect(LoopLedger.merge(existing: [done], found: [found], updates: [], items: [], now: now).filter { $0.status == .open }.count == 1)
    }

    @Test func aDifferentPromiseFromTheSameMessageStillOpens() {
        let done = loop("Share the corrected image", status: .closed, closedAgo: 86400, from: "msg-88")
        let found = loop("Send the signed invoice for September", from: "msg-88")
        #expect(LoopLedger.merge(existing: [done], found: [found], updates: [], items: [], now: now).count == 2,
                "one message can carry two promises")
    }

    @Test func theSameWordsToADifferentPersonStillOpens() {
        let done = loop("Host the system after ensuring a backup is taken", person: "Ravi", status: .closed, closedAgo: 86400, from: "msg-5")
        let found = loop("Host the system after ensuring a backup is taken", person: "Tanvi", from: "msg-5")
        #expect(LoopLedger.merge(existing: [done], found: [found], updates: [], items: [], now: now).count == 2)
    }

    @Test func anOpenLoopStillWinsOverAClosedOneSoNothingAlreadyTrackedIsLost() {
        let open = loop("Send Sam the update after speaking with Tanvi", person: "Sam", id: "OPEN")
        let found = loop("Send Sam the update about Noor's request after speaking with Tanvi", person: "Sam")
        let out = LoopLedger.merge(existing: [open], found: [found], updates: [], items: [], now: now)
        #expect(out.count == 1 && out[0].id == "OPEN")
    }
}
