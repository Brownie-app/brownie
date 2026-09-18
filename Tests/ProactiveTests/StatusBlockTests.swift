import Testing
import Foundation
@testable import Proactive
import Domain

/// The status block on a person's note: absolute dates, the same bytes on any day, migration from the old markers.
@Suite struct StatusBlockTests {
    /// 16 Sep 2025 05:20 UTC.
    let now = Date(timeIntervalSince1970: 1_758_000_000)
    let utc = TimeZone(identifier: "UTC")!
    let day = 86400.0
    func ask(_ id: String, person: String = "Nitesh (+91)", askedAgo: TimeInterval, answeredAgo: TimeInterval? = nil, q: String = "beer?", addressed: Bool? = nil, lapsedAgo: TimeInterval? = nil) -> Ask {
        Ask(id: id, person: person, bucket: BucketID("w:1"), askedAt: now.addingTimeInterval(-askedAgo), question: q, answeredAt: answeredAgo.map { now.addingTimeInterval(-$0) }, addressed: addressed, lapsedAt: lapsedAgo.map { now.addingTimeInterval(-$0) })
    }
    func loop(_ id: String, person: String = "Nitesh", what: String, dir: LoopDirection = .mine, due: String? = nil, openedAgo: TimeInterval, status: LoopStatus = .open, closedAgo: TimeInterval? = nil, how: String? = nil) -> Loop {
        Loop(id: id, direction: dir, person: person, what: what, quote: "", sourceLabel: "s", due: due, status: status, openedAt: now.addingTimeInterval(-openedAgo), closedAt: closedAgo.map { now.addingTimeInterval(-$0) }, closedHow: how,
             closedBy: status == .lapsed ? "lapsed" : nil, lapsedAt: status == .lapsed ? closedAgo.map { now.addingTimeInterval(-$0) } : nil)
    }

    @Test func rendersThisPersonOnlyWithAbsoluteDates() {
        let asks = [ask("a", askedAgo: 7200, answeredAgo: 3600, q: "postgres ka url kaise milega\nbata do"), ask("b", person: "Nitesh", askedAgo: 600), ask("c", person: "Kanika", askedAgo: 0, q: "x")]
        let loops = [loop("L", what: "share the exact steps once confirmed", due: "Friday", openedAgo: 100), loop("K", person: "Kanika", what: "send the deck", dir: .theirs, openedAgo: 0)]
        let b = StatusBlock.render(person: "Nitesh", asks: asks, loops: loops, now: now, timeZone: utc)
        #expect(b == """
        <!-- brownie:status -->
        ## Between you
        _Kept by Brownie from the chats and the loops ledger. Not written by the brain._
        - ⏳ 16 Sep — they asked: “beer?” — no reply yet
        - ✅ 16 Sep — they asked: “postgres ka url kaise milega bata do” — you replied 16 Sep 04:20 _(not checked)_
        - ⏳ you promised (16 Sep): share the exact steps once confirmed · due Friday
        <!-- /brownie:status -->

        """)
        #expect(StatusBlock.render(person: "Nobody", asks: asks, loops: loops, now: now, timeZone: utc) == "")
    }

    @Test func theSameLedgersGiveTheSameBytesOnAnotherDay() {
        let asks = [ask("a", askedAgo: 7200, answeredAgo: 3600, addressed: true), ask("b", askedAgo: 600), ask("g", askedAgo: 46 * day, q: "old one?", lapsedAgo: day)]
        let loops = [loop("L", what: "share the steps", due: "Friday", openedAgo: 100), loop("C", what: "answer Nitesh", openedAgo: 4 * day, status: .closed, closedAgo: 2 * day, how: "you replied"),
                     loop("Z", what: "the old thing", openedAgo: 100 * day, status: .lapsed, closedAgo: 3 * day)]
        let today = StatusBlock.render(person: "Nitesh", asks: asks, loops: loops, now: now, timeZone: utc)
        #expect(today == StatusBlock.render(person: "Nitesh", asks: asks, loops: loops, now: now.addingTimeInterval(3 * day + 7 * 3600), timeZone: utc), "no 'x days ago' anywhere, so the note is not rewritten nightly")
        #expect(!today.contains("ago"))
        #expect(today.contains("- ⌛ 1 Aug — they asked: “old one?” — no reply in 45 days; no longer tracked (lapsed 15 Sep)"))
        #expect(today.contains("- ✅ you promised (12 Sep): answer Nitesh — done 14 Sep (you replied)"))
        #expect(today.contains("- ⌛ you promised (8 Jun): the old thing — no news in 90 days; no longer tracked (lapsed 13 Sep)"))
        #expect(today.contains("- ✅ 16 Sep — they asked: “beer?” — you replied 16 Sep 04:20\n"), "a judged reply carries no 'not checked'")
    }

    /// Each verdict has its own line — their word, the user's no, a promise still open, the judge's word from another channel.
    @Test func eachVerdictHasItsOwnLine() {
        var theirs = ask("t", askedAgo: 2 * day, q: "did you get the file?"); theirs.settle(.confirmedByThem, at: now.addingTimeInterval(-day), by: "rules")
        var no = ask("n", askedAgo: 2 * day, answeredAgo: day, q: "can you share the deck?"); no.settle(.declined, at: now.addingTimeInterval(-day), by: "rules")
        var promised = ask("p", askedAgo: 2 * day, answeredAgo: day, q: "estimates?"); promised.settle(.promised, at: now.addingTimeInterval(-day), by: "reader")
        var slack = ask("s", askedAgo: 2 * day, q: "postgres url?"); slack.settle(.answered, at: now, by: "judge", how: "on Slack"); slack.answeredAt = now
        var sorted = ask("a", askedAgo: 2 * day, answeredAgo: 1.5 * day, q: "the url?"); sorted.settle(.answered, at: now.addingTimeInterval(-day), by: "rules")
        var lapsedPromise = ask("l", askedAgo: 46 * day, answeredAgo: 45 * day, q: "the old deck?"); lapsedPromise.settle(.promised, at: now.addingTimeInterval(-45 * day), by: "rules"); lapsedPromise.lapsedAt = now.addingTimeInterval(-day)
        let b = StatusBlock.render(person: "Nitesh", asks: [theirs, no, promised, slack, sorted, lapsedPromise], loops: [], now: now, timeZone: utc)
        #expect(b.contains("- ✅ 14 Sep — they asked: “did you get the file?” — they said it's done, 15 Sep\n"))
        #expect(b.contains("- ✅ 14 Sep — they asked: “can you share the deck?” — you said no, 15 Sep\n"))
        #expect(b.contains("- ⏳ 14 Sep — they asked: “estimates?” — you said you would, 15 Sep; still open\n"))
        #expect(b.contains("- ✅ 14 Sep — they asked: “postgres url?” — answered on Slack, 16 Sep (the judge)\n"))
        #expect(b.contains("- ✅ 14 Sep — they asked: “the url?” — you replied 15 Sep 05:20\n"), "dated by the line that answered, not the first reply")
        #expect(b.contains("- ⌛ 1 Aug — they asked: “the old deck?” — you said you would, 2 Aug; no longer tracked (lapsed 15 Sep)\n"))
        #expect(b == StatusBlock.render(person: "Nitesh", asks: [theirs, no, promised, slack, sorted, lapsedPromise], loops: [], now: now.addingTimeInterval(3 * day), timeZone: utc), "the same bytes on another day")
        var judgeNoHow = slack; judgeNoHow.outcomeHow = nil
        #expect(StatusBlock.render(person: "Nitesh", asks: [judgeNoHow], loops: [], now: now, timeZone: utc).contains("— answered elsewhere, 16 Sep (the judge)"))
    }

    @Test func settledItemsLeaveAfterFourteenDaysAndRetiredLinesNameThem() {
        let asks = [ask("shown", askedAgo: 20 * day, answeredAgo: 13 * day, q: "still shown?", addressed: true), ask("gone", askedAgo: 20 * day, answeredAgo: 14.5 * day, q: "left today?", addressed: true),
                    ask("older", askedAgo: 40 * day, answeredAgo: 28 * day, q: "long gone?", addressed: true), ask("lapsed", askedAgo: 60 * day, q: "let go?", lapsedAgo: 14.1 * day),
                    ask("week", askedAgo: 30 * day, answeredAgo: 21 * day, q: "a week gone?", addressed: true)]
        let loops = [loop("O", what: "still open", openedAgo: 200 * day), loop("C", what: "closed lately", openedAgo: 20 * day, status: .closed, closedAgo: 13 * day, how: "done"),
                     loop("G", what: "closed a fortnight back", openedAgo: 20 * day, status: .closed, closedAgo: 14.1 * day, how: "done"), loop("N", what: "not a promise", openedAgo: day, status: .dismissed, closedAgo: 0)]
        let b = StatusBlock.render(person: "Nitesh", asks: asks, loops: loops, now: now, timeZone: utc)
        #expect(b.contains("still shown?") && b.contains("still open") && b.contains("closed lately"))
        #expect(!b.contains("left today?") && !b.contains("long gone?") && !b.contains("let go?") && !b.contains("closed a fortnight back"))
        #expect(!b.contains("not a promise"), "what the user said was never a loop is not on the note")
        let retired = StatusBlock.retiredLines(person: "Nitesh", asks: asks, loops: loops, now: now, timeZone: utc)
        #expect(retired == ["- ✅ 27 Aug — they asked: “left today?” — you replied 1 Sep 17:20",
                            "- ✅ 17 Aug — they asked: “a week gone?” — you replied 26 Aug 05:20",
                            "- ⌛ 18 Jul — they asked: “let go?” — no reply in 45 days; no longer tracked (lapsed 2 Sep)",
                            "- ✅ you promised (27 Aug): closed a fortnight back — done 2 Sep (done)"], "what left within the last fortnight, in the block's own words; what left before that was handed on or is gone")
        #expect(!b.contains("a week gone?"), "off the block a week ago, still offered to the gardener tonight")
        #expect(StatusBlock.retiredLines(person: "Kanika", asks: asks, loops: loops, now: now, timeZone: utc).isEmpty)
        let routed = StatusBlock.retiredLines(asks: asks.filter { $0.id == "gone" }, loops: [], now: now, timeZone: utc)
        #expect(routed == ["- ✅ 27 Aug — they asked: “left today?” — you replied 1 Sep 17:20"], "the routed form checks no name: whoever chose these lines for the note decided")
    }

    @Test func upsertInsertsAfterTheTitleReplacesInPlaceAndRemovesWhenEmpty() {
        let body = "# Nitesh\n\nRecurring contact.\n\n## Pending\n- stuff\n"
        let block = StatusBlock.open + "\n## Between you\n- one\n" + StatusBlock.close + "\n"
        let once = StatusBlock.upsert(into: body, block: block)
        #expect(once == "# Nitesh\n\n" + block + "\nRecurring contact.\n\n## Pending\n- stuff\n")
        #expect(StatusBlock.upsert(into: once, block: block) == once, "unchanged when the block is the same")
        let block2 = StatusBlock.open + "\n## Between you\n- two\n" + StatusBlock.close + "\n"
        let twice = StatusBlock.upsert(into: once, block: block2)
        #expect(twice.contains("- two") && !twice.contains("- one") && twice.components(separatedBy: "## Between you").count == 2)
        #expect(StatusBlock.upsert(into: twice, block: "") == "# Nitesh\n\nRecurring contact.\n\n## Pending\n- stuff\n", "an empty block takes the old one out")
        #expect(StatusBlock.upsert(into: "no title here", block: block) == block.trimmingCharacters(in: .newlines) + "\n\nno title here")
    }

    /// The brain writes many notes with no blank line under the title; the night's block must not turn that into the user's edit.
    @Test func upsertOnANoteWithNoBlankLineUnderTheTitleIsUndoneExactlyByStrip() {
        let body = "# Arif\nArif is a friend.\n"
        let block = StatusBlock.open + "\n## Between you\n- one\n" + StatusBlock.close + "\n"
        let once = StatusBlock.upsert(into: body, block: block)
        #expect(once == "# Arif\n\n" + block + "Arif is a friend.\n")
        #expect(NoteStatus.strip(once) == body && StatusBlock.upsert(into: once, block: "") == body, "what went in is exactly what comes out")
        #expect(NoteMeta.hash(once) == NoteMeta.hash(body) && !NoteMeta.fresh(path: "People/Arif.md", body: body, today: "2026-09-16").bodyDiffers(once), "so the note is still Brownie's")
        #expect(StatusBlock.upsert(into: once, block: block) == once && NoteStatus.strip(StatusBlock.upsert(into: once, block: block.replacingOccurrences(of: "one", with: "two"))) == body)
    }

    @Test func aNoteWithTheOldMarkersIsMigrated() {
        let old = "# Nitesh\n\n" + StatusBlock.legacyOpen + "\n## Between you\n_old_\n- ⏳ 16 Sep they asked: “beer?” — **no reply yet** (2 h ago)\n" + StatusBlock.legacyClose + "\n\nRecurring contact.\n"
        let block = StatusBlock.open + "\n## Between you\n- ⏳ 16 Sep — they asked: “beer?” — no reply yet\n" + StatusBlock.close + "\n"
        let migrated = StatusBlock.upsert(into: old, block: block)
        #expect(migrated == "# Nitesh\n\n" + block + "\nRecurring contact.\n")
        #expect(!migrated.contains("between-you") && migrated.components(separatedBy: "## Between you").count == 2, "one block, under the new markers")
        #expect(StatusBlock.upsert(into: old, block: "") == "# Nitesh\n\nRecurring contact.\n", "an empty block takes the old-style one out too")
    }
}
