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
        // "you replied" is true only of the user's own reply in the chat: their word and the judge's settle an ask another way
        var byThem = ask("t", askedAgo: 1200); byThem.settle(.confirmedByThem, at: now.addingTimeInterval(-300), by: "rules")
        var slack = ask("s", askedAgo: 1200); slack.settle(.answered, at: now, by: "judge", how: "on Slack")
        var no = ask("n", askedAgo: 1200, answeredAgo: 300); no.settle(.declined, at: no.answeredAt!, by: "rules")
        #expect(AskLedger.closures(loops: [loop], asks: [byThem], now: now)[0].status == .open && AskLedger.closures(loops: [loop], asks: [slack], now: now)[0].status == .open)
        #expect(AskLedger.closures(loops: [loop], asks: [no], now: now)[0].status == .closed, "a no is a reply")
    }

    @Test func theJudgeHearsDatesNotWords() {
        let s = AskLedger.judgeLines([ask("a", askedAgo: 7200, answeredAgo: 3600), ask("b", person: "Kanika", askedAgo: 3 * 86400, q: "secret question")], now: now)
        #expect(s.contains("- ask b · Kanika asked the user something on") && s.contains("NO REPLY YET (3 days ago)"), "an open ask carries its id, for ask_updates")
        #expect(s.contains("the user replied") && s.contains("— done") && !s.contains("- ask a ·"), "a settled one needs no id")
        #expect(!s.contains("secret") && !s.contains("postgres"), "the words stay on the Mac")
        #expect(s.contains("goes in ask_updates by its id"))
        #expect(AskLedger.judgeLines([], now: now) == "")
    }

    @Test func theJudgeHearsEachVerdictInItsOwnWords() {
        var promised = ask("p", askedAgo: 2 * 86400, answeredAgo: 86400); promised.settle(.promised, at: promised.answeredAt!, by: "rules")
        var theirs = ask("t", person: "Kanika", askedAgo: 7200); theirs.settle(.confirmedByThem, at: now.addingTimeInterval(-3600), by: "rules")
        var no = ask("n", person: "Rohan", askedAgo: 7200, answeredAgo: 3600); no.settle(.declined, at: no.answeredAt!, by: "rules")
        var slack = ask("s", person: "Meera", askedAgo: 7200); slack.settle(.answered, at: now, by: "judge", how: "on Slack"); slack.answeredAt = now
        let s = AskLedger.judgeLines([promised, theirs, no, slack], now: now)
        #expect(s.contains("- ask p · Nitesh (+919540752593) asked the user something on") && s.contains("the user said they would get to it (") && s.contains("— still open (2 days ago)"), "a promise is still open, and listed with its id")
        #expect(s.contains("Kanika asked the user something on") && s.contains("they said it is settled") && s.contains("Rohan asked") && s.contains("the user said no"))
        #expect(s.contains("Meera asked the user something on") && s.contains("answered on Slack"))
        #expect(!s.contains("- ask t ·") && !s.contains("- ask n ·") && !s.contains("- ask s ·"))
    }

    @Test func theJudgesWordClosesAnOpenAskAndNeverReopensOne() {
        let open = Ask(id: "ask-a1b2c3d4e5f6", person: "Nitesh", bucket: BucketID("whatsapp:507"), askedAt: now.addingTimeInterval(-86400), question: "postgres ka url?", answeredAt: now.addingTimeInterval(-3600), reply: "lol", addressed: false, outcome: .open, outcomeAt: now.addingTimeInterval(-3600), outcomeBy: "rules")
        var no = Ask(id: "ask-ffff00001111", person: "Rohan", bucket: BucketID("whatsapp:3"), askedAt: now.addingTimeInterval(-86400), question: "q?", answeredAt: now.addingTimeInterval(-3600), reply: "no"); no.settle(.declined, at: no.answeredAt!, by: "rules")
        var gone = Ask(id: "ask-eeee00002222", person: "Kanika", bucket: BucketID("whatsapp:9"), askedAt: now.addingTimeInterval(-50 * 86400), question: "q?"); gone.lapsedAt = now.addingTimeInterval(-86400)
        let silent = Ask(id: "ask-dddd00003333", person: "Meera", bucket: BucketID("whatsapp:2"), askedAt: now.addingTimeInterval(-7200), question: "q?")
        let out = AskLedger.apply(updates: [(idPrefix: "ask-a1b2c3d4e5f6", how: "on Slack."), (idPrefix: "ffff0000", how: "by mail"), (idPrefix: "ask eeee0000", how: "on Slack"), (idPrefix: "DDDD0000", how: "  "), (idPrefix: "ask-", how: "x")], to: [open, no, gone, silent], now: now)
        #expect(out[0].outcome == .answered && out[0].outcomeBy == "judge" && out[0].outcomeHow == "on Slack" && out[0].outcomeAt == now && out[0].isAnswered && !out[0].isOpen, "closed as answered, dated tonight, the judge's words on where")
        #expect(out[0].answeredAt == open.answeredAt && out[0].addressed == true, "the reply in the chat stays what it was")
        #expect(out[1] == no, "a settled ask is not the judge's to touch")
        #expect(out[2] == gone, "nor one let go")
        #expect(out[3].outcome == .answered && out[3].outcomeHow == nil && out[3].answeredAt == now, "an id cut short and in capitals still matches; with no reply in the chat, tonight is the answer's date")
        #expect(StatusRules.settledAt(out[0]) == now && StatusRules.settledAt(out[3]) == now)
        #expect(AskLedger.apply(updates: [], to: [open], now: now) == [open])
    }

    @Test func aLoopAboutWhatAnAskAskedForClosesWhenTheAskDoes() {
        let day = 86400.0
        // asked five days ago, answered three days ago
        var sent = ask("a", askedAgo: 5 * day, answeredAgo: 3 * day, q: "can you send the estimates for the three tasks?"); sent.settle(.answered, at: sent.answeredAt!, by: "rules")
        let loop = Loop(id: "EST", direction: .mine, person: "Nitesh", what: "Send Nitesh the estimates for the three tasks", quote: "", sourceLabel: "WhatsApp", due: nil, openedAt: now.addingTimeInterval(-4 * day))
        let earlier = Loop(id: "OLD", direction: .mine, person: "Nitesh", what: "Send the task estimates", quote: "", sourceLabel: "WhatsApp", due: nil, openedAt: now.addingTimeInterval(-10 * day))
        let other = Loop(id: "DECK", direction: .mine, person: "Nitesh", what: "Send Nitesh the deck", quote: "", sourceLabel: "WhatsApp", due: nil, openedAt: now.addingTimeInterval(-4 * day))
        let someoneElse = Loop(id: "KAN", direction: .mine, person: "Kanika", what: "Send Kanika the estimates for the three tasks", quote: "", sourceLabel: "WhatsApp", due: nil, openedAt: now.addingTimeInterval(-4 * day))
        let newer = Loop(id: "NEW", direction: .mine, person: "Nitesh", what: "Send Nitesh the estimates for the three tasks", quote: "", sourceLabel: "WhatsApp", due: nil, openedAt: now.addingTimeInterval(-day))
        let theirs = Loop(id: "THEIRS", direction: .theirs, person: "Nitesh", what: "Send the estimates for the three tasks", quote: "", sourceLabel: "WhatsApp", due: nil, openedAt: now.addingTimeInterval(-4 * day))
        let out = AskLedger.followers(loops: [loop, earlier, other, someoneElse, newer, theirs], asks: [sent], now: now)
        #expect(out[0].status == .closed && out[0].closedBy == "ask" && out[0].closedHow == "the ask it came from was answered" && out[0].closedAt == sent.answeredAt, "the promise about the very thing asked for")
        #expect(out[1].status == .closed, "opened before the ask, about the same thing: the answer settles it too")
        #expect(out[2].status == .open, "another deliverable to the same person")
        #expect(out[3].status == .open, "the same words to someone else")
        #expect(out[4].status == .open, "opened more than a day after the ask settled: newer news")
        #expect(out[5].status == .closed, "either direction")
        // only a settled ask closes: not one that promised, one judged open, one given the benefit of the doubt, or one let go
        var promised = sent; promised.settle(.promised, at: sent.answeredAt!, by: "rules")
        var open = sent; open.settle(.open, at: sent.answeredAt!, by: "rules")
        let unjudged = ask("u", askedAgo: 5 * day, answeredAgo: 3 * day, q: "can you send the estimates for the three tasks?")
        var gone = ask("g", askedAgo: 50 * day, q: "can you send the estimates for the three tasks?"); gone.lapsedAt = now
        for a in [promised, open, unjudged, gone] { #expect(AskLedger.followers(loops: [loop], asks: [a], now: now)[0].status == .open, Comment(rawValue: a.id)) }
        // their word and the judge's close it just the same, dated by that word
        var confirmed = ask("c", askedAgo: 5 * day, q: "can you send the estimates for the three tasks?"); confirmed.settle(.confirmedByThem, at: now.addingTimeInterval(-day), by: "rules")
        #expect(AskLedger.followers(loops: [loop], asks: [confirmed], now: now)[0].closedAt == now.addingTimeInterval(-day))
        var slack = ask("s", askedAgo: 5 * day, q: "can you send the estimates for the three tasks?"); slack.settle(.answered, at: now, by: "judge", how: "on Slack")
        #expect(AskLedger.followers(loops: [loop], asks: [slack], now: now)[0].closedAt == now)
        // once: a loop already closed is left as it is
        var done = loop; done.status = .closed; done.closedBy = "judge"; done.closedHow = "sent"; done.closedAt = now.addingTimeInterval(-day)
        #expect(AskLedger.followers(loops: [done], asks: [sent], now: now)[0] == done)
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
