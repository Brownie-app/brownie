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

    @Test func settledItemsLeaveAfterFourteenDaysAndRetiredLinesNameThem() {
        let asks = [ask("shown", askedAgo: 20 * day, answeredAgo: 13 * day, q: "still shown?", addressed: true), ask("gone", askedAgo: 20 * day, answeredAgo: 14.5 * day, q: "left today?", addressed: true),
                    ask("older", askedAgo: 30 * day, answeredAgo: 20 * day, q: "long gone?", addressed: true), ask("lapsed", askedAgo: 60 * day, q: "let go?", lapsedAgo: 14.1 * day)]
        let loops = [loop("O", what: "still open", openedAgo: 200 * day), loop("C", what: "closed lately", openedAgo: 20 * day, status: .closed, closedAgo: 13 * day, how: "done"),
                     loop("G", what: "closed a fortnight back", openedAgo: 20 * day, status: .closed, closedAgo: 14.1 * day, how: "done"), loop("N", what: "not a promise", openedAgo: day, status: .dismissed, closedAgo: 0)]
        let b = StatusBlock.render(person: "Nitesh", asks: asks, loops: loops, now: now, timeZone: utc)
        #expect(b.contains("still shown?") && b.contains("still open") && b.contains("closed lately"))
        #expect(!b.contains("left today?") && !b.contains("long gone?") && !b.contains("let go?") && !b.contains("closed a fortnight back"))
        #expect(!b.contains("not a promise"), "what the user said was never a loop is not on the note")
        let retired = StatusBlock.retiredLines(person: "Nitesh", asks: asks, loops: loops, now: now, timeZone: utc)
        #expect(retired == ["- ✅ 27 Aug — they asked: “left today?” — you replied 1 Sep 17:20",
                            "- ⌛ 18 Jul — they asked: “let go?” — no reply in 45 days; no longer tracked (lapsed 2 Sep)",
                            "- ✅ you promised (27 Aug): closed a fortnight back — done 2 Sep (done)"], "what left since yesterday, in the block's own words; what left earlier was handed on already")
        #expect(StatusBlock.retiredLines(person: "Kanika", asks: asks, loops: loops, now: now, timeZone: utc).isEmpty)
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
