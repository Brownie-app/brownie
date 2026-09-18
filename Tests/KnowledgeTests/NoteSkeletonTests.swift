import Testing
import Foundation
import Domain
@testable import Knowledge

/// The fixed shape of a People note: order, what folds where, how dates are read, the caps, that nothing the user
/// wrote is lost on the way, and that a second pass changes nothing.
@Suite struct NoteSkeletonTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let now = Date(timeIntervalSince1970: 1_789_560_000)   // 2026-09-16 11:20 UTC
    static let block = "<!-- brownie:status -->\n## Between you\n_Kept by Brownie._\n- ⏳ 2 Sep — they asked: “dinner?” — no reply yet\n<!-- /brownie:status -->"
    func norm(_ body: String, kind: NoteMeta.Kind = .person) -> (body: String, changes: [String]) { NoteSkeleton.normalize(body: body, kind: kind, now: Self.now, timeZone: Self.utc) }
    /// The lines of one rendered section, up to the next heading.
    func section(_ h: String, of body: String) -> [String] {
        let lines = body.components(separatedBy: "\n")
        guard let i = lines.firstIndex(of: h) else { return [] }
        return Array(lines[(i + 1)...].prefix { !$0.hasPrefix("## ") }).filter { !$0.isEmpty }
    }

    @Test func sectionsComeOutInOrderWithTheBlockUnderTheTitle() {
        let body = "# Arjun Mehta\n\nOld friend from college. Works at Loadmill.\n\n## Earlier\n- 2026-06 — met for coffee\n\n## Context\n- Moved to Pune (2026-08-20)\n\n" + Self.block + "\n\n## Now\n- Asked about the flat (2026-09-10)\n"
        let out = norm(body)
        #expect(out.body == "# Arjun Mehta\n\n" + Self.block + "\n\n## About\n- Old friend from college. Works at Loadmill.\n\n## Now\n- Asked about the flat (2026-09-10)\n\n## Context\n- Moved to Pune (2026-08-20)\n\n## Earlier\n- 2026-06 — met for coffee\n")
        #expect(NoteStatus.extract(from: out.body) == Self.block, "the block is byte-identical")
        #expect(!out.changes.isEmpty)
    }

    @Test func pendingAndUnknownHeadingsFoldWhereTheyBelong() {
        let body = "# Priya\n\n## Who she is\nSister-in-law. Lives in Delhi.\n\n## Pending and commitments\n- She asked for the Goa photos (2026-09-05)\n- You promised to send the recipe (2026-09-08)\n\n## Bakery\nRuns a bakery since 2024.\n- Opened a second shop (2026-07-30)\n- Her partner is Meera\n\n## Open items\n- Waiting on her flight dates (2026-09-12)\n"
        let out = norm(body)
        #expect(out.body == "# Priya\n\n## About\n- Sister-in-law. Lives in Delhi.\n- Runs a bakery since 2024.\n- Her partner is Meera\n\n## Now\n- Waiting on her flight dates (2026-09-12)\n- You promised to send the recipe (2026-09-08)\n- She asked for the Goa photos (2026-09-05)\n\n## Context\n- Opened a second shop (2026-07-30)\n",
                "under an unknown heading only a bullet that carries a date is news; an undated one is a standing fact")
        #expect(out.changes.first == "folded ‘Who she is’, ‘Pending and commitments’, ‘Bakery’, ‘Open items’")
        #expect(!out.changes.contains { $0.contains("date unclear") }, "a bullet sent to About is not marked")
    }

    @Test func theThreeDateStylesBecomeISO() {
        let body = "# A\n\n## Now\n- One (16 Sep 2026)\n- Two (2026-06-29–2026-09-09)\n- Three (2026-09-14)\n- Four (since 1 Sep 2026)\n- Five (Sep 12, 2026)\n"
        let out = norm(body)
        #expect(out.body == "# A\n\n## Now\n- One (2026-09-16)\n- Three (2026-09-14)\n- Five (2026-09-12)\n- Two (2026-09-09)\n- Four (since 2026-09-01)\n",
                "a range keeps its end; newest first; a since sorts by its date like any other")
        #expect(out.changes.contains("4 bullets dated"), "the one already in ISO is not a change")
    }

    @Test func onlyADateAtTheEndOfABulletCounts() {
        let out = norm("# A\n\n## Context\n- No date here\n- Met on 2026-09-10 in Pune\n- Keeps a dog (Loadmill)\n- Coffee at Blue Tokai — 12 Sep 2026\n- Back from leave · since 2026-09-01\n")
        #expect(out.body == "# A\n\n## Context\n- Coffee at Blue Tokai (2026-09-12)\n- Back from leave (since 2026-09-01)\n- No date here (date unclear)\n- Met on 2026-09-10 in Pune (date unclear)\n- Keeps a dog (Loadmill) (date unclear)\n",
                "a date after a spaced dash or dot is the bullet's; one in the middle of a sentence is words and stays; a parenthesis that is not a date is text")
        #expect(out.changes.contains("3 bullets marked date unclear") && out.changes.contains("2 bullets dated"))
    }

    @Test func aDateOpeningABulletMovesToItsEnd() {
        let body = "# A\n\n## Now\n- **16 Sep 2026:** Kanika shared the deck with the team\n- 16 Sep 2026 — Kanika called\n- 2026-09-16: Priya wrote\n- **12 Sep 2026**: colon outside the bold\n- **10 Sep 2026** — a dash after the bold\n- Sep 15, 2026: month first\n- 11 September 2026 — the month written out\n- 2026-09-16: Kanika (Loadmill)\n"
        let out = norm(body)
        #expect(section("## Now", of: out.body) == ["- Kanika shared the deck with the team (2026-09-16)", "- Kanika called (2026-09-16)", "- Priya wrote (2026-09-16)", "- Kanika (Loadmill) (2026-09-16)", "- month first (2026-09-15)", "- colon outside the bold (2026-09-12)"],
                "bold or not, colon or dash, the date comes off the head and goes to the end, the words as they were; six stay under Now")
        #expect(section("## Context", of: out.body) == ["- the month written out (2026-09-11)", "- a dash after the bold (2026-09-10)"])
        #expect(out.changes.contains("8 bullets dated") && !out.body.contains("date unclear"))
        #expect(norm(out.body).changes.isEmpty, "idempotent")
    }

    @Test func aBareDayAndMonthTakeTheMostRecentYearNotInTheFuture() {
        let out = norm("# A\n\n## Now\n- 14 Sep: lunch with Priya at Blue Tokai\n- Sep 20: ahead of today, so last year\n- 16 Sep — today itself\n")
        #expect(out.body == "# A\n\n## Now\n- today itself (2026-09-16)\n- lunch with Priya at Blue Tokai (2026-09-14)\n\n## Earlier\n- 2025-09 — ahead of today, so last year\n")
        #expect(norm(out.body).changes.isEmpty)
    }

    @Test func aBulletWithBothDatesKeepsTheOneAtTheEndAndWordsWithAColonAreWords() {
        let out = norm("# A\n\n## Now\n- 2026-09-01: both dates (2026-09-05)\n- **1 Sep 2026:** marked unclear by an older pass (date unclear)\n- Kanika: said hi (2026-09-10)\n- **Kanika:** a bold name\n- Score 3-2: fine\n- 2026-09-16 14:00: a time is not a date\n")
        #expect(section("## Now", of: out.body) == ["- Kanika: said hi (2026-09-10)", "- both dates (2026-09-05)", "- marked unclear by an older pass (2026-09-01)", "- **Kanika:** a bold name (date unclear)", "- Score 3-2: fine (date unclear)", "- 2026-09-16 14:00: a time is not a date (date unclear)"],
                "the end's date wins and the head's comes off; a head that is not a date stays as words")
        #expect(norm(out.body).changes.isEmpty)
        let slip = norm("# A\n\n## Now\n- **16 Sep 2026:** born (1926-09-16)\n")
        #expect(slip.body == "# A\n\n## Now\n- born (1926-09-16) (2026-09-16)\n" && slip.changes.contains("1 impossible date marked unclear"), "an impossible date at the end is a slip kept as words; the head then dates the bullet")
        #expect(norm(slip.body).changes.isEmpty)
    }

    @Test func anImpossibleYearIsUnclearAndTheSlipStaysAsWords() {
        let out = norm("# A\n\n## Now\n- Born (1926-09-16)\n- Wedding (2040-01-01)\n- Fine (2026-09-01)\n")
        #expect(out.body == "# A\n\n## Now\n- Fine (2026-09-01)\n- Born (1926-09-16) (date unclear)\n- Wedding (2040-01-01) (date unclear)\n")
        #expect(out.changes.contains("2 impossible dates marked unclear"))
        #expect(norm(out.body).changes.isEmpty)
    }

    @Test func normalisingTwiceIsNormalisingOnce() {
        let messy = "Some preamble.\n# Kanika\n" + Self.block + "\n## Background\n- Colleague at Loadmill.\n  - knows Arjun\n\n## Pending\n1. Send the deck (2 Sep 2026)\n2. Review her PR\n\n## Recent\n- Lunch (2026-09-11)\n\n## Earlier\n- July 2026: joined the team\n- 2025-12 — first met; coffee\n- 2024-01 — long ago\n"
        let once = norm(messy), twice = norm(once.body)
        #expect(twice.body == once.body)
        #expect(twice.changes.isEmpty, "nothing to report the second time")
        #expect(once.body.hasPrefix("# Kanika\n\n" + Self.block + "\n\n## About\n- Some preamble.\n- Colleague at Loadmill.\n  - knows Arjun\n"), "a nested bullet stays under its parent; the preamble is About")
        #expect(once.body.contains("## Now\n- Send the deck (2026-09-02)\n- Review her PR (date unclear)\n"))
        #expect(once.body.contains("## Earlier\n- 2026-07 — joined the team\n- 2025-12 — first met; coffee\n"), "a month named in words is a month line; a month past a year is let go")
        #expect(!once.body.contains("2024-01"))
    }

    @Test func capsHoldAndOverflowGoesDownNotAway() {
        let about = (1...33).map { "- fact \($0)" }.joined(separator: "\n")
        let now = (1...9).map { "- item \($0) (2026-09-\(String(format: "%02d", $0)))" }.joined(separator: "\n")
        let context = (1...15).map { "- ctx \($0) (2026-08-\(String(format: "%02d", $0)))" }.joined(separator: "\n")
        let out = norm("# A\n\n## About\n\(about)\n\n## Now\n\(now)\n\n## Context\n\(context)\n")
        #expect(section("## About", of: out.body).count == 30 && section("## About", of: out.body).last == "- fact 30", "About keeps its first thirty")
        #expect(section("## Now", of: out.body) == (4...9).reversed().map { "- item \($0) (2026-09-\(String(format: "%02d", $0)))" }, "the six newest stay")
        let ctx = section("## Context", of: out.body)
        #expect(ctx.prefix(3) == ["- item 3 (2026-09-03)", "- item 2 (2026-09-02)", "- item 1 (2026-09-01)"], "Now's overflow lands in Context, newest first")
        #expect(ctx.count == 15 && ctx[11] == "- ctx 7 (2026-08-07)" && ctx.suffix(3) == ["- fact 31 (date unclear)", "- fact 32 (date unclear)", "- fact 33 (date unclear)"],
                "Context keeps twelve dated bullets; About's overflow sits under them, undated, and is not counted")
        #expect(section("## Earlier", of: out.body) == ["- 2026-08 — ctx 1; ctx 2; ctx 3; ctx 4; ctx 5; ctx 6"], "Context's dated overflow is a clause on its month, oldest first")
        #expect(out.changes == ["3 bullets marked date unclear", "6 bullets moved to Earlier", "3 bullets moved to Context", "3 About bullets past the cap moved to Context"])
        for i in 1...33 { #expect(out.body.contains("fact \(i)")) }
        for i in 1...15 { #expect(out.body.contains("ctx \(i)")) }
        #expect(norm(out.body).changes.isEmpty)
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

    // MARK: nothing the user wrote is lost

    @Test func commentsAreCarriedThroughWhereTheySat() {
        let body = "# A\n\n" + Self.block + "\n\n## About\n- friend\n<!-- ask about the loan next time -->\n- lives in Pune\n\n## Now\n- Asked for photos (2026-09-05)\n<!--\nremind me:\nthe photos\n-->\n"
        let out = norm(body)
        #expect(out.body == body, "a comment is an item of its section; a multi-line one is one item; a note with comments in shape is in shape")
        #expect(out.changes.isEmpty)
        #expect(NoteStatus.extract(from: out.body) == Self.block, "only the status block is Brownie's")
        let moved = norm("# A\n\n## Now\n<!-- keep short -->\n- Old (2026-09-01)\n- New (2026-09-10)\n")
        #expect(moved.body == "# A\n\n## Now\n- New (2026-09-10)\n- Old (2026-09-01)\n<!-- keep short -->\n", "among sorted bullets a comment follows them")
    }

    @Test func aSubHeadingStaysInsideItsSectionWithItsBullets() {
        let context = (1...12).reversed().map { "- c\($0) (2026-08-\(String(format: "%02d", $0)))" }.joined(separator: "\n")
        let out = norm("# Rohan\n\n## About\n- Works at Acme\n\n### Family\n- Wife: Priya\n- Two kids, Aarav and Mira\n\n## Context\n\(context)\n")
        #expect(out.body.hasPrefix("# Rohan\n\n## About\n- Works at Acme\n\n### Family\n- Wife: Priya\n- Two kids, Aarav and Mira\n\n## Context\n"), "the ### heading and its bullets are About, in place")
        #expect(section("## Context", of: out.body).count == 12 && !out.body.contains("date unclear"))
        #expect(out.changes.isEmpty)
        #expect(NoteSkeleton.classify("Family") == .about && NoteSkeleton.classify("Kids") == .about && NoteSkeleton.classify("Home") == .about && NoteSkeleton.classify("Work") == .about)
        let two = norm("# Rohan\n\n## Family\n- Wife: Priya (2026-09-01)\n- Two kids\n")
        #expect(two.body == "# Rohan\n\n## About\n- Wife: Priya (2026-09-01)\n- Two kids\n", "a family heading is About even when a bullet carries a date")
    }

    @Test func oldShapeEarlierBulletsKeepTheirWordsWhole() {
        let out = norm("# A\n\n## Earlier\n- 2026-07-15 — met at the wedding\n- 2026-07-20: coffee in Pune\n- Met in July 2026 at the wedding\n- Since March 2026 she runs the bakery\n- Aug 2026 — went hiking\n- 2026-06 — already a month line\n")
        #expect(out.body == "# A\n\n## Earlier\n- 2026-08 — went hiking\n- 2026-07 — 2026-07-15 — met at the wedding; 2026-07-20: coffee in Pune; Met in July 2026 at the wedding\n- 2026-06 — already a month line\n- 2026-03 — Since March 2026 she runs the bakery\n",
                "a full date is not a month line; a month mid-sentence is words; only a month opening the line comes off")
        #expect(norm(out.body).body == out.body)
    }

    @Test func headingsMatchWholeWordsLongestFirst() {
        #expect(NoteSkeleton.classify("Outstanding") == .now && NoteSkeleton.classify("Outstanding asks") == .now, "'outstanding' is not 'standing'")
        #expect(NoteSkeleton.classify("Standing facts") == .about && NoteSkeleton.classify("Long-standing") == .about)
        #expect(NoteSkeleton.classify("Work updates") == .context, "the longer word decides")
        #expect(NoteSkeleton.classify("Opened") == .unknown && NoteSkeleton.classify("Tasks") == .unknown, "no substring matches")
        let out = norm("# Priya\n\n## Outstanding\n- She asked for the Goa photos (2026-09-05)\n")
        #expect(out.body == "# Priya\n\n## Now\n- She asked for the Goa photos (2026-09-05)\n")
    }

    @Test func indentedSiblingsAreSeparateBulletsAndNestedOnesStayUnderTheirParent() {
        let out = norm("# A\n\n## Now\n  - Asked for photos (2026-09-05)\n  - Promised the recipe (2026-09-08)\n  - Flight dates (2026-09-12)\n\n## About\n- Colleague at Loadmill\n\t- knows Arjun\n    - and Priya\n  wrapped words\n- Next fact\n")
        #expect(section("## Now", of: out.body) == ["- Flight dates (2026-09-12)", "- Promised the recipe (2026-09-08)", "- Asked for photos (2026-09-05)"], "a uniformly indented list is three bullets")
        #expect(section("## About", of: out.body) == ["- Colleague at Loadmill", "    - knows Arjun", "    - and Priya", "  wrapped words", "- Next fact"], "what is nested under a bullet rides with it, indentation kept")
        let dated = norm("# A\n\n## Now\n- Asked for the flat (2026-09-10)\n  - the one in Pune (2026-01-01)\n  - two bedrooms\n")
        #expect(dated.body == "# A\n\n## Now\n- Asked for the flat (2026-09-10)\n  - the one in Pune (2026-01-01)\n  - two bedrooms\n", "the date rule reads the parent only")
        #expect(norm(dated.body).changes.isEmpty && norm(out.body).changes.isEmpty)
    }

    @Test func tablesFencesAndQuotesAreVerbatimAndAHashInAFenceIsNotAHeading() {
        let body = "# A\n\n## About\n- friend\n| Name | Role |\n|---|---|\n| Priya | sister |\n| Arjun | cousin |\n```sh\n# install brew first\nbrew install x\n## not a heading either\n```\n> she said: keep this\n> for later\n- lives in Pune\n"
        let out = norm(body)
        #expect(out.body == "# A\n\n## About\n- friend\n\n| Name | Role |\n|---|---|\n| Priya | sister |\n| Arjun | cousin |\n\n```sh\n# install brew first\nbrew install x\n## not a heading either\n```\n\n> she said: keep this\n> for later\n\n- lives in Pune\n",
                "each block is one item, byte for byte, with a blank line either side")
        #expect(out.changes == ["put in shape"])
        #expect(norm(out.body).changes.isEmpty)
        let unclosed = norm("# A\n\n## Now\n- x (2026-09-01)\n```\n## Context\n- y (2026-08-01)\n")
        #expect(unclosed.body == "# A\n\n## Now\n- x (2026-09-01)\n\n```\n## Context\n- y (2026-08-01)\n", "an unclosed fence runs to the end and is never split")
    }

    @Test func thePromptsAgreeWithTheShapeOnWhatHappensToOldBullets() throws {
        func prompt(_ name: String) throws -> String { try String(contentsOf: Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Prompts")!, encoding: .utf8) }
        let update = try prompt("update"), build = try prompt("build")
        #expect(!update.contains("30 days") && !update.contains("records what's pending") && !update.contains("fold it into one short"), "the old retention rule is gone")
        #expect(update.contains("as dated bullets under Now") && update.contains("never fold or drop them yourself"), "one rule: Brownie moves bullets on by clock")
        #expect(update.contains("When the user's own reply settles a request, say it is answered, with the date"), "every other sentence stays")
        #expect(!build.contains("what's pending between them") && build.contains("what is live between them under Now"))
        for p in [update, build] { #expect(p.contains("Brownie ages bullets out of Now into Earlier after 45 days")) }
    }

    @Test func theTrickiestNoteIsStableAndLosesNothing() {
        let messy = "# Kanika\n" + Self.block + "\n<!-- template: person -->\n\n## About\n- Colleague at Loadmill\n  - knows Arjun\n  - and [[Priya]]\n\n### Family\n- Husband: Dev\n\n| Name | Role |\n|---|---|\n| Dev | husband |\n\n```\n# not a heading\n```\n\n## Pending\n- Send the deck (2 Sep 2026)\n  - the Q3 one\n- Review her PR\n<!-- she is on leave until Oct -->\n\n## Outstanding\n- Waiting on her flight dates — 12 Sep 2026\n\n## Recent\n> quoted from mail\n- Lunch (2026-09-11)\n- On leave (since 2026-06-01)\n\n## Earlier\n- 2026-07-15 — met at the wedding\n- July 2026: joined the team\n- Met in June 2026 at the offsite\n- 2025-12 — first met; coffee\n- 2024-01 — long ago\n"
        let once = norm(messy), twice = norm(once.body)
        #expect(twice.body == once.body && twice.changes.isEmpty)
        let expected = "# Kanika\n\n" + Self.block + "\n\n## About\n<!-- template: person -->\n- Colleague at Loadmill\n  - knows Arjun\n  - and [[Priya]]\n\n### Family\n- Husband: Dev\n\n| Name | Role |\n|---|---|\n| Dev | husband |\n\n```\n# not a heading\n```\n\n## Now\n- Waiting on her flight dates (2026-09-12)\n- Send the deck (2026-09-02)\n  - the Q3 one\n- Review her PR (date unclear)\n<!-- she is on leave until Oct -->\n\n## Context\n- Lunch (2026-09-11)\n- On leave (since 2026-06-01)\n\n> quoted from mail\n\n## Earlier\n- 2026-07 — 2026-07-15 — met at the wedding; joined the team\n- 2026-06 — Met in June 2026 at the offsite\n- 2025-12 — first met; coffee\n"
        #expect(once.body == expected)
        for words in ["knows Arjun", "[[Priya]]", "Husband: Dev", "| Dev | husband |", "# not a heading", "the Q3 one", "on leave until Oct", "quoted from mail", "met at the wedding", "at the offsite"] { #expect(once.body.contains(words)) }
        #expect(once.changes.contains("1 Earlier line let go") && !once.changes.contains { $0.contains("dropped") })
    }
}
