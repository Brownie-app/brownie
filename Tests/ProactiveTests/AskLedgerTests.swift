import Testing
import Foundation
@testable import Proactive
import Domain

@Suite struct AskLedgerTests {
    let now = Date(timeIntervalSince1970: 1_758_000_000)
    func ask(_ id: String, person: String = "Nitesh (+919540752593)", askedAgo: TimeInterval, answeredAgo: TimeInterval? = nil, q: String = "postgres ka url kaise milega") -> Ask {
        Ask(id: id, person: person, bucket: BucketID("whatsapp:507"), askedAt: now.addingTimeInterval(-askedAgo), question: q, answeredAt: answeredAgo.map { now.addingTimeInterval(-$0) })
    }

    @Test func mergeReplacesByIDLetsGoTheUnansweredAndForgetsOldOnes() {
        let old = ask("a", askedAgo: 3600), waiting = ask("z", askedAgo: 50 * 86400), ancient = ask("y", askedAgo: 100 * 86400)
        let m = AskLedger.merge(existing: [old, waiting, ancient], found: [ask("a", askedAgo: 3600, answeredAgo: 600), ask("b", askedAgo: 60)], now: now)
        #expect(m.map(\.id) == ["b", "a", "z"] && m[1].answeredAt != nil, "the later scan carries the answer; 100 days is gone")
        #expect(m[2].lapsedAt == now && !m[2].isOpen && m[2].isLapsed, "45 days with no reply: let go, but remembered")
        // once let go, a rescan without a reply keeps it let go; a reply that finally came takes it back
        let again = AskLedger.merge(existing: m, found: [ask("z", askedAgo: 50 * 86400)], now: now)
        #expect(again.first { $0.id == "z" }?.lapsedAt == now)
        let answered = AskLedger.merge(existing: m, found: [ask("z", askedAgo: 50 * 86400, answeredAgo: 60)], now: now)
        #expect(answered.first { $0.id == "z" }?.isAnswered == true && answered.first { $0.id == "z" }?.lapsedAt == nil)
    }

    @Test func theScanReachesBackToTheOldestOpenAsk() {
        let day = 86400.0
        #expect(AskLedger.scanSince(open: [], now: now) == now.addingTimeInterval(-3 * day), "nothing waiting: three days")
        #expect(AskLedger.scanSince(open: [ask("a", askedAgo: 3600)], now: now) == now.addingTimeInterval(-3 * day), "a fresh ask is inside the three days anyway")
        #expect(AskLedger.scanSince(open: [ask("a", askedAgo: 4 * day), ask("b", askedAgo: 2 * day)], now: now) == now.addingTimeInterval(-4 * day - 3600), "an hour before the oldest one waiting, so its reply on day 4 is paired")
        #expect(AskLedger.scanSince(open: [ask("a", askedAgo: 60 * day)], now: now) == now.addingTimeInterval(-45 * day), "never past the horizon")
        #expect(AskLedger.scanSince(open: [ask("a", askedAgo: 10 * day, answeredAgo: 9 * day)], now: now) == now.addingTimeInterval(-3 * day), "an answered ask does not widen the scan")
        var gone = ask("a", askedAgo: 20 * day); gone.lapsedAt = now
        #expect(AskLedger.scanSince(open: [gone], now: now) == now.addingTimeInterval(-3 * day), "nor one let go")
    }

    @Test func theScanIsPlannedPerChatAndNamesTheRepliesAlreadyJudged() {
        let day = 86400.0
        let deep = ask("a", askedAgo: 40 * day)   // whatsapp:507, still waiting
        let off = Ask(id: "o", person: "Kanika", bucket: BucketID("whatsapp:9"), askedAt: now.addingTimeInterval(-5 * day), question: "q?", answeredAt: now.addingTimeInterval(-4 * day), reply: "lol", addressed: false)
        let done = Ask(id: "d", person: "Rohan", bucket: BucketID("whatsapp:3"), askedAt: now.addingTimeInterval(-20 * day), question: "q?", answeredAt: now.addingTimeInterval(-19 * day), reply: "done", addressed: true)
        let s = AskLedger.scan(existing: [deep, off, done], now: now)
        #expect(s.since == now.addingTimeInterval(-3 * day), "a chat with nothing waiting: three days")
        #expect(s.since(BucketID("whatsapp:507")) == now.addingTimeInterval(-40 * day - 3600), "back to its own ask")
        #expect(s.since(BucketID("whatsapp:9")) == now.addingTimeInterval(-5 * day - 3600), "not to another chat's older one")
        #expect(s.since(BucketID("whatsapp:3")) == now.addingTimeInterval(-3 * day) && s.since(BucketID("slack:D1")) == now.addingTimeInterval(-3 * day), "an answered ask widens nothing; nor does a chat with no ask")
        #expect(s.judgedReplies == ["o": off.answeredAt!], "only the reply judged to be about something else is named")
        #expect(AskLedger.scan(existing: [], now: now) == AskScan(since: now.addingTimeInterval(-3 * day)))
    }

    @Test func yourReplyClosesTheLoopAboutAnswering() {
        let loop = Loop(id: "L", direction: .mine, person: "Nitesh", what: "Answer Nitesh's PostgreSQL question", quote: "", sourceLabel: "WhatsApp", due: nil, openedAt: now.addingTimeInterval(-900))
        let promise = Loop(id: "P", direction: .mine, person: "Nitesh", what: "share the exact steps once confirmed", quote: "", sourceLabel: "WhatsApp", due: nil, openedAt: now.addingTimeInterval(-100))
        let theirs = Loop(id: "T", direction: .theirs, person: "Nitesh", what: "answer about the URL", quote: "", sourceLabel: "WhatsApp", due: nil, openedAt: now.addingTimeInterval(-900))
        let asks = [ask("a", askedAgo: 1200, answeredAgo: 300)]
        let closed = AskLedger.closures(loops: [loop, promise, theirs], asks: asks, now: now)
        #expect(closed[0].status == .closed && closed[0].closedHow == "you replied" && closed[0].closedBy == "reply" && closed[0].closedAt == asks[0].answeredAt)
        #expect(closed[1].status == .open, "a promise opened after the reply is a new thing")
        #expect(closed[2].status == .open, "only what the user owed")
        #expect(AskLedger.closures(loops: [loop], asks: [ask("a", askedAgo: 1200)], now: now)[0].status == .open, "no reply, no closure")
    }

    @Test func theJudgeHearsDatesNotWords() {
        let s = AskLedger.judgeLines([ask("a", askedAgo: 7200, answeredAgo: 3600), ask("b", person: "Kanika", askedAgo: 3 * 86400, q: "secret question")], now: now)
        #expect(s.contains("Kanika asked the user something on") && s.contains("NO REPLY YET (3 days ago)"))
        #expect(s.contains("the user replied") && s.contains("— done"))
        #expect(!s.contains("secret") && !s.contains("postgres"), "the words stay on the Mac")
        #expect(AskLedger.judgeLines([], now: now) == "")
    }

    @Test func theJudgeHearsLapsedNeverNoReplyYetAndLoopsLetGo() {
        var gone = ask("g", person: "Kanika", askedAgo: 46 * 86400); gone.lapsedAt = now.addingTimeInterval(-86400)
        var old = ask("o", person: "Rohan", askedAgo: 70 * 86400); old.lapsedAt = now.addingTimeInterval(-20 * 86400)
        let s = AskLedger.judgeLines([gone, old], now: now)
        #expect(s.contains("Kanika asked the user something on") && s.contains("LAPSED — no reply in 45 days"))
        #expect(!s.contains("NO REPLY YET"), "a question let go is never called unanswered")
        #expect(!s.contains("Rohan"), "one let go three weeks back is not worth the judge's time")
        let letGo = Loop(id: "LAPSED01-x", direction: .mine, person: "Karan", what: "send the villa share", quote: "", sourceLabel: "s", due: nil, status: .lapsed, openedAt: now.addingTimeInterval(-100 * 86400), closedAt: now.addingTimeInterval(-3600), closedBy: "lapsed", lapsedAt: now.addingTimeInterval(-3600))
        let openLoop = Loop(id: "OPEN0001-x", direction: .mine, person: "Karan", what: "cricket tickets", quote: "", sourceLabel: "s", due: nil, openedAt: now)
        let l = AskLedger.judgeLines([], loops: [letGo, openLoop], now: now)
        #expect(l.hasPrefix("LOOPS LET GO") && l.contains("- loop LAPSED01 · the user → Karan · send the villa share · let go") && !l.contains("cricket"))
        #expect(!l.contains("ASKS IN DIRECT CHATS"), "no asks, no asks section")
    }

    @Test func samePersonIsForgivingAboutNumbersAndSurnames() {
        #expect(AskLedger.samePerson("Nitesh (+919540752593)", "Nitesh"))
        #expect(AskLedger.samePerson("Kanika Pandey Loadmill", "Kanika Pandey"))
        #expect(!AskLedger.samePerson("Rohan", "Priya"))
    }
}
