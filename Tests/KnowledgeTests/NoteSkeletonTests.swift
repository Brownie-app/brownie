import Testing
import Foundation
import Domain
@testable import Knowledge

/// The fixed shape of a People note: order, what folds where, how dates are read, the caps, and that a second pass changes nothing.
@Suite struct NoteSkeletonTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let now = Date(timeIntervalSince1970: 1_789_560_000)   // 2026-09-16 11:20 UTC
    static let block = "<!-- brownie:status -->\n## Between you\n_Kept by Brownie._\n- ⏳ 2 Sep — they asked: “dinner?” — no reply yet\n<!-- /brownie:status -->"
    func norm(_ body: String, kind: NoteMeta.Kind = .person) -> (body: String, changes: [String]) { NoteSkeleton.normalize(body: body, kind: kind, now: Self.now, timeZone: Self.utc) }

    @Test func sectionsComeOutInOrderWithTheBlockUnderTheTitle() {
        let body = "# Arjun Mehta\n\nOld friend from college. Works at Loadmill.\n\n## Earlier\n- 2026-06 — met for coffee\n\n## Context\n- Moved to Pune (2026-08-20)\n\n" + Self.block + "\n\n## Now\n- Asked about the flat (2026-09-10)\n"
        let out = norm(body)
        #expect(out.body == "# Arjun Mehta\n\n" + Self.block + "\n\n## About\n- Old friend from college. Works at Loadmill.\n\n## Now\n- Asked about the flat (2026-09-10)\n\n## Context\n- Moved to Pune (2026-08-20)\n\n## Earlier\n- 2026-06 — met for coffee\n")
        #expect(NoteStatus.extract(from: out.body) == Self.block, "the block is byte-identical")
        #expect(!out.changes.isEmpty)
    }

    @Test func pendingAndUnknownHeadingsFoldWhereTheyBelong() {
        let body = "# Priya\n\n## Who she is\nSister-in-law. Lives in Delhi.\n\n## Pending and commitments\n- She asked for the Goa photos (2026-09-05)\n- You promised to send the recipe (2026-09-08)\n\n## Work\nRuns a bakery since 2024.\n- Opened a second shop (2026-07-30)\n\n## Open items\n- Waiting on her flight dates (2026-09-12)\n"
        let out = norm(body)
        #expect(out.body == "# Priya\n\n## About\n- Sister-in-law. Lives in Delhi.\n- Runs a bakery since 2024.\n\n## Now\n- Waiting on her flight dates (2026-09-12)\n- You promised to send the recipe (2026-09-08)\n- She asked for the Goa photos (2026-09-05)\n\n## Context\n- Opened a second shop (2026-07-30)\n")
        #expect(out.changes.first == "folded ‘Who she is’, ‘Pending and commitments’, ‘Work’, ‘Open items’")
    }

    @Test func theThreeDateStylesBecomeISO() {
        let body = "# A\n\n## Now\n- One (16 Sep 2026)\n- Two (2026-06-29–2026-09-09)\n- Three (2026-09-14)\n- Four (since 1 Sep 2026)\n- Five (Sep 12, 2026)\n"
        let out = norm(body)
        #expect(out.body == "# A\n\n## Now\n- One (2026-09-16)\n- Three (2026-09-14)\n- Five (2026-09-12)\n- Two (2026-09-09)\n- Four (since 2026-09-01)\n",
                "a range keeps its end; newest first; a since sorts by its date like any other")
        #expect(out.changes.contains("4 bullets dated"), "the one already in ISO is not a change")
    }

    @Test func undatedBulletsAreMarkedAndADateInTheTextCounts() {
        let out = norm("# A\n\n## Context\n- No date here\n- Met on 2026-09-10 in Pune\n- Keeps a dog (Loadmill)\n")
        #expect(out.body == "# A\n\n## Context\n- Met on 2026-09-10 in Pune (2026-09-10)\n- No date here (date unclear)\n- Keeps a dog (Loadmill) (date unclear)\n", "a parenthesis that is not a date is text")
        #expect(out.changes.contains("2 bullets marked date unclear") && out.changes.contains("1 bullet dated"))
    }

    @Test func anImpossibleYearIsUnclear() {
        let out = norm("# A\n\n## Now\n- Born (1926-09-16)\n- Wedding (2040-01-01)\n- Fine (2026-09-01)\n")
        #expect(out.body == "# A\n\n## Now\n- Fine (2026-09-01)\n- Born (date unclear)\n- Wedding (date unclear)\n")
        #expect(out.changes.contains("2 impossible dates marked unclear"))
    }

    @Test func normalisingTwiceIsNormalisingOnce() {
        let messy = "Some preamble.\n# Kanika\n" + Self.block + "\n## Background\n- Colleague at Loadmill.\n  - knows Arjun\n\n## Pending\n1. Send the deck (2 Sep 2026)\n2. Review her PR\n\n## Recent\n- Lunch on 2026-09-11\n\n## Earlier\n- July 2026: joined the team\n- 2025-12 — first met; coffee\n- 2024-01 — long ago\n"
        let once = norm(messy), twice = norm(once.body)
        #expect(twice.body == once.body)
        #expect(twice.changes.isEmpty, "nothing to report the second time")
        #expect(once.body.hasPrefix("# Kanika\n\n" + Self.block + "\n\n## About\n- Some preamble.\n- Colleague at Loadmill.; knows Arjun\n"), "a nested bullet rides with its parent; the preamble is About")
        #expect(once.body.contains("## Now\n- Send the deck (2026-09-02)\n- Review her PR (date unclear)\n"))
        #expect(once.body.contains("## Earlier\n- 2026-07 — joined the team\n- 2025-12 — first met; coffee\n"), "a month named in words is a month line; a month past a year is let go")
        #expect(!once.body.contains("2024-01"))
    }

    @Test func capsHoldAndOverflowGoesDownNotAway() {
        let about = (1...25).map { "- fact \($0)" }.joined(separator: "\n")
        let now = (1...9).map { "- item \($0) (2026-09-\(String(format: "%02d", $0)))" }.joined(separator: "\n")
        let context = (1...15).map { "- ctx \($0) (2026-08-\(String(format: "%02d", $0)))" }.joined(separator: "\n")
        let out = norm("# A\n\n## About\n\(about)\n\n## Now\n\(now)\n\n## Context\n\(context)\n")
        let lines = out.body.components(separatedBy: "\n")
        func section(_ h: String) -> [String] { let i = lines.firstIndex(of: h)!; return Array(lines[(i + 1)...].prefix { $0.hasPrefix("- ") }) }
        #expect(section("## About").count == 20 && section("## About").last == "- fact 20")
        #expect(section("## Now") == (4...9).reversed().map { "- item \($0) (2026-09-\(String(format: "%02d", $0)))" }, "the six newest stay")
        #expect(section("## Context").count == 12 && section("## Context").prefix(3) == ["- item 3 (2026-09-03)", "- item 2 (2026-09-02)", "- item 1 (2026-09-01)"], "Now's overflow lands in Context, newest first, and Context keeps twelve")
        #expect(out.changes.contains("5 About bullets past the cap dropped") && out.changes.contains("3 bullets moved to Context") && out.changes.contains("6 Context bullets past the cap dropped"))
    }

    @Test func otherKindsAndUnresolvedConflictsAreLeftAlone() {
        let topic = "# Trip\n\nprose\n\n## Pending\n- x\n"
        #expect(norm(topic, kind: .topic).body == topic && norm(topic, kind: .portrait).body == topic)
        let conflict = "# A\n\n## Now\n- x (2026-09-01)\n\n## Brownie's version (16 Sep 11:20 — you edited this note on your phone at the same time; pick what you want to keep)\n\n- y\n"
        #expect(norm(conflict).body == conflict && norm(conflict).changes.isEmpty)
    }

    @Test func aGroupNoteTakesTheSameShape() {
        let out = norm("# MPL Days\n\nThe college group.\n\n## What's being planned\n- Goa in October (2026-09-14)\n", kind: .group)
        #expect(out.body == "# MPL Days\n\n## About\n- The college group.\n\n## Context\n- Goa in October (2026-09-14)\n")
    }
}
