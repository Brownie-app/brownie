import Testing
import Foundation
@testable import Proactive
import Domain

/// The clock rules of the status block, against a fixed clock: what is let go when, and how long a settled item stays.
@Suite struct StatusRulesTests {
    let now = Date(timeIntervalSince1970: 1_758_000_000)
    let day = 86400.0
    func ask(_ id: String, askedDaysAgo: Double, answeredDaysAgo: Double? = nil, addressed: Bool? = nil) -> Ask {
        Ask(id: id, person: "Nitesh", bucket: BucketID("whatsapp:1"), askedAt: now.addingTimeInterval(-askedDaysAgo * day), question: "q?", answeredAt: answeredDaysAgo.map { now.addingTimeInterval(-$0 * day) }, addressed: addressed)
    }
    func loop(_ id: String, openedDaysAgo: Double, dueDaysAgo: Double? = nil, status: LoopStatus = .open, fired: [String] = [], cameBack: Int = 0) -> Loop {
        Loop(id: id, direction: .mine, person: "Karan", what: "villa share", quote: "", sourceLabel: "s", due: dueDaysAgo.map { _ in "a date" }, dueDate: dueDaysAgo.map { now.addingTimeInterval(-$0 * day) },
             status: status, openedAt: now.addingTimeInterval(-openedDaysAgo * day), firedCardIDs: fired, cameBackCount: cameBack)
    }

    @Test func anAskWithNoReplyIsLetGoAfterFortyFiveDays() {
        let out = StatusRules.lapse(asks: [ask("young", askedDaysAgo: 44.9), ask("old", askedDaysAgo: 45), ask("answered", askedDaysAgo: 60, answeredDaysAgo: 59), ask("offTopic", askedDaysAgo: 50, answeredDaysAgo: 49, addressed: false)], now: now)
        #expect(out[0].lapsedAt == nil && out[0].isOpen, "44 days is still waiting")
        #expect(out[1].lapsedAt == now && !out[1].isOpen && out[1].isLapsed, "45 days: let go, dated today")
        #expect(out[2].lapsedAt == nil && out[2].isAnswered, "an answered ask is never let go")
        #expect(out[3].lapsedAt == now, "a reply about something else is no reply")
        #expect(StatusRules.lapse(asks: out, now: now.addingTimeInterval(5 * day))[1].lapsedAt == now, "the date it was let go does not move")
    }

    @Test func aPromiseToGetToItLapsesLikeNoReplyFromTheAsking() {
        var young = ask("young", askedDaysAgo: 44.9, answeredDaysAgo: 1); young.settle(.promised, at: young.answeredAt!, by: "rules")
        var old = ask("old", askedDaysAgo: 45, answeredDaysAgo: 1); old.settle(.promised, at: old.answeredAt!, by: "rules")
        var theirs = ask("theirs", askedDaysAgo: 60); theirs.settle(.confirmedByThem, at: now.addingTimeInterval(-59 * day), by: "rules")
        var no = ask("no", askedDaysAgo: 60, answeredDaysAgo: 59); no.settle(.declined, at: no.answeredAt!, by: "rules")
        let out = StatusRules.lapse(asks: [young, old, theirs, no], now: now)
        #expect(out[0].isOpen && out[0].lapsedAt == nil, "a promise made yesterday on a question asked 44 days ago is still open")
        #expect(out[1].lapsedAt == now && out[1].isLapsed && !out[1].isOpen, "45 days from the asking, a promise counts for nothing")
        #expect(out[2].lapsedAt == nil && out[2].isAnswered && out[3].lapsedAt == nil && out[3].isAnswered, "their word and the user's no are settled, never let go")
        #expect(StatusRules.settledAt(out[1]) == now && StatusRules.settledAt(young) == nil && StatusRules.settledAt(theirs) == now.addingTimeInterval(-59 * day))
    }

    @Test func anUntouchedLoopIsLetGoAfterNinetyDays() {
        let out = StatusRules.lapse(loops: [loop("young", openedDaysAgo: 89.9), loop("old", openedDaysAgo: 90), loop("done", openedDaysAgo: 200, status: .closed)], now: now)
        #expect(out[0].status == .open && out[0].lapsedAt == nil)
        #expect(out[1].status == .lapsed && out[1].lapsedAt == now && out[1].closedAt == now && out[1].closedBy == "lapsed")
        #expect(out[2].status == .closed && out[2].lapsedAt == nil, "only open loops are let go")
    }

    @Test func aLoopWithNewsNeverLapses() {
        let out = StatusRules.lapse(loops: [loop("fired", openedDaysAgo: 400, fired: ["card1"]), loop("back", openedDaysAgo: 400, cameBack: 1)], now: now)
        #expect(out.allSatisfy { $0.status == .open }, "a card fired or a came-back is news; the user is in this one")
    }

    @Test func aDatedLoopNeverLapsesBeforeItsDate() {
        let out = StatusRules.lapse(loops: [loop("ahead", openedDaysAgo: 120, dueDaysAgo: -10), loop("recent", openedDaysAgo: 120, dueDaysAgo: 30), loop("long past", openedDaysAgo: 200, dueDaysAgo: 90)], now: now)
        #expect(out[0].status == .open, "due in ten days: not let go however old")
        #expect(out[1].status == .open, "due a month ago: the ninety days count from the date")
        #expect(out[2].status == .lapsed, "due ninety days ago and nothing since")
    }

    @Test func settledItemsAreShownFourteenDaysThenLeave() {
        #expect(StatusRules.isShown(settledAt: nil, now: now), "open: always")
        #expect(StatusRules.isShown(settledAt: now.addingTimeInterval(-13.9 * day), now: now))
        #expect(!StatusRules.isShown(settledAt: now.addingTimeInterval(-14 * day), now: now))
        #expect(!StatusRules.leftLately(settledAt: nil, now: now) && !StatusRules.leftLately(settledAt: now.addingTimeInterval(-13 * day), now: now))
        #expect(StatusRules.leftLately(settledAt: now.addingTimeInterval(-14.5 * day), now: now), "left the block since yesterday's run")
        #expect(StatusRules.leftLately(settledAt: now.addingTimeInterval(-15 * day), now: now) && StatusRules.leftLately(settledAt: now.addingTimeInterval(-27.9 * day), now: now),
                "still offered for a fortnight after it left: a night the Mac was closed does not lose the trace, and the gardener keeps a clause once")
        #expect(!StatusRules.leftLately(settledAt: now.addingTimeInterval(-28 * day), now: now), "a fortnight on, it is either kept or gone for good")
        var answered = ask("a", askedDaysAgo: 20, answeredDaysAgo: 13); #expect(StatusRules.settledAt(answered) == answered.answeredAt)
        answered.addressed = false; answered.lapsedAt = now; #expect(StatusRules.settledAt(answered) == now, "an off-topic reply settles nothing; being let go does")
        #expect(StatusRules.settledAt(ask("b", askedDaysAgo: 1)) == nil)
        let gone = StatusRules.lapse(loops: [loop("l", openedDaysAgo: 100)], now: now)[0]
        #expect(StatusRules.settledAt(gone) == now && StatusRules.settledAt(loop("o", openedDaysAgo: 1)) == nil)
        var closed = loop("c", openedDaysAgo: 5, status: .closed); closed.closedAt = now.addingTimeInterval(-day)
        #expect(StatusRules.settledAt(closed) == closed.closedAt)
    }
}
