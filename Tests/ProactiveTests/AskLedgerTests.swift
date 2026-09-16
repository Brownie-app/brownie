import Testing
import Foundation
@testable import Proactive
import Domain

@Suite struct AskLedgerTests {
    let now = Date(timeIntervalSince1970: 1_758_000_000)
    func ask(_ id: String, person: String = "Nitesh (+919540752593)", askedAgo: TimeInterval, answeredAgo: TimeInterval? = nil, q: String = "postgres ka url kaise milega") -> Ask {
        Ask(id: id, person: person, bucket: BucketID("whatsapp:507"), askedAt: now.addingTimeInterval(-askedAgo), question: q, answeredAt: answeredAgo.map { now.addingTimeInterval(-$0) })
    }

    @Test func mergeReplacesByIDAndForgetsOldOnes() {
        let old = ask("a", askedAgo: 3600), ancient = ask("z", askedAgo: 50 * 86400)
        let m = AskLedger.merge(existing: [old, ancient], found: [ask("a", askedAgo: 3600, answeredAgo: 600), ask("b", askedAgo: 60)], now: now)
        #expect(m.map(\.id) == ["b", "a"] && m[1].answeredAt != nil, "the later scan carries the answer; 50 days is gone")
    }

    @Test func yourReplyClosesTheLoopAboutAnswering() {
        let loop = Loop(id: "L", direction: .mine, person: "Nitesh", what: "Answer Nitesh's PostgreSQL question", quote: "", sourceLabel: "WhatsApp", due: nil, openedAt: now.addingTimeInterval(-900))
        let promise = Loop(id: "P", direction: .mine, person: "Nitesh", what: "share the exact steps once confirmed", quote: "", sourceLabel: "WhatsApp", due: nil, openedAt: now.addingTimeInterval(-100))
        let theirs = Loop(id: "T", direction: .theirs, person: "Nitesh", what: "answer about the URL", quote: "", sourceLabel: "WhatsApp", due: nil, openedAt: now.addingTimeInterval(-900))
        let asks = [ask("a", askedAgo: 1200, answeredAgo: 300)]
        let closed = AskLedger.closures(loops: [loop, promise, theirs], asks: asks, now: now)
        #expect(closed[0].status == .closed && closed[0].closedHow == "you replied 5 min ago" && closed[0].closedAt == asks[0].answeredAt)
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

    @Test func samePersonIsForgivingAboutNumbersAndSurnames() {
        #expect(AskLedger.samePerson("Nitesh (+919540752593)", "Nitesh"))
        #expect(AskLedger.samePerson("Kanika Pandey Loadmill", "Kanika Pandey"))
        #expect(!AskLedger.samePerson("Rohan", "Priya"))
    }
}

@Suite struct BetweenYouTests {
    let now = Date(timeIntervalSince1970: 1_758_000_000)
    @Test func rendersAsksAndLoopsForThatPersonOnly() {
        let asks = [Ask(id: "a", person: "Nitesh (+91)", bucket: BucketID("w:1"), askedAt: now.addingTimeInterval(-7200), question: "postgres ka url kaise milega\nbata do", answeredAt: now.addingTimeInterval(-3600)),
                    Ask(id: "b", person: "Nitesh", bucket: BucketID("w:1"), askedAt: now.addingTimeInterval(-600), question: "beer?"),
                    Ask(id: "c", person: "Kanika", bucket: BucketID("w:2"), askedAt: now, question: "x")]
        let loops = [Loop(id: "L", direction: .mine, person: "Nitesh", what: "share the exact steps once confirmed", quote: "", sourceLabel: "s", due: "Friday", openedAt: now.addingTimeInterval(-100)),
                     Loop(id: "K", direction: .theirs, person: "Kanika", what: "send the deck", quote: "", sourceLabel: "s", due: nil, openedAt: now)]
        let b = BetweenYou.render(person: "Nitesh", asks: asks, loops: loops, now: now)
        #expect(b.hasPrefix(BetweenYou.open + "\n## Between you"))
        #expect(b.contains("✅") && b.contains("they asked: “postgres ka url kaise milega bata do” — you replied"))
        #expect(b.contains("⏳") && b.contains("they asked: “beer?” — **no reply yet** (10 min ago)"))
        #expect(b.contains("you promised: share the exact steps once confirmed · due Friday"))
        #expect(!b.contains("Kanika") && !b.contains("deck"))
        #expect(BetweenYou.render(person: "Nobody", asks: asks, loops: loops, now: now) == "")
    }

    @Test func upsertInsertsAfterTheTitleReplacesInPlaceAndRemovesWhenEmpty() {
        let body = "# Nitesh\n\nRecurring contact.\n\n## Pending\n- stuff\n"
        let block = BetweenYou.open + "\n## Between you\n- one\n" + BetweenYou.close + "\n"
        let once = BetweenYou.upsert(into: body, block: block)
        #expect(once == "# Nitesh\n\n" + block + "\nRecurring contact.\n\n## Pending\n- stuff\n")
        #expect(BetweenYou.upsert(into: once, block: block) == once, "unchanged when the block is the same")
        let block2 = BetweenYou.open + "\n## Between you\n- two\n" + BetweenYou.close + "\n"
        let twice = BetweenYou.upsert(into: once, block: block2)
        #expect(twice.contains("- two") && !twice.contains("- one") && twice.components(separatedBy: "## Between you").count == 2)
        #expect(BetweenYou.upsert(into: twice, block: "") == "# Nitesh\n\nRecurring contact.\n\n## Pending\n- stuff\n", "an empty block takes the old one out")
        #expect(BetweenYou.upsert(into: "no title here", block: block) == block.trimmingCharacters(in: .newlines) + "\n\nno title here")
    }
}
