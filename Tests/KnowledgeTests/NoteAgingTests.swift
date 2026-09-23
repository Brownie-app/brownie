import Testing
import Foundation
import Domain
@testable import Knowledge

/// The clock rules against a fixed clock: 2026-09-16, so 45 days back is 2026-08-02 and a year back is 2025-09-16.
@Suite struct NoteAgingTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let now = Date(timeIntervalSince1970: 1_789_560_000)   // 2026-09-16 11:20 UTC
    func age(_ body: String, retired: [String] = []) -> (body: String, changes: [String]) { NoteAging.age(body: body, kind: .person, now: Self.now, retired: retired, timeZone: Self.utc) }
    func section(_ h: String, of body: String) -> [String] {
        let lines = body.components(separatedBy: "\n")
        guard let i = lines.firstIndex(of: h) else { return [] }
        return Array(lines[(i + 1)...].prefix { !$0.hasPrefix("## ") }).filter { !$0.isEmpty }
    }

    @Test func fortySixDaysMovesAndFortyFourStays() {
        let out = age("# A\n\n## Now\n- Old news (2026-08-01)\n- On the edge (2026-08-02)\n- Fresh (2026-08-03)\n")
        #expect(out.body == "# A\n\n## Now\n- Fresh (2026-08-03)\n- On the edge (2026-08-02)\n\n## Earlier\n- 2026-08 — Old news\n")
        #expect(out.changes == ["1 bullet moved to Earlier"])
    }

    @Test func aSinceIsAStandingStateAndGoesToContext() {
        let out = age("# A\n\n## Now\n- On leave (since 2026-06-01)\n")
        #expect(out.body == "# A\n\n## Context\n- On leave (since 2026-06-01)\n")
    }

    @Test func aSincePastTheContextCapIsAStandingFactUnderAbout() {
        let ctx = (1...12).map { "- c\($0) (2026-08-\(String(format: "%02d", $0)))" }.joined(separator: "\n")
        let out = age("# A\n\n## About\n- friend\n\n## Now\n- Works at Loadmill (since 2024-03-01)\n\n## Context\n\(ctx)\n")
        #expect(section("## About", of: out.body) == ["- friend", "- Works at Loadmill (since 2024-03-01)"], "the fact and its date are kept, under About")
        #expect(section("## Context", of: out.body).count == 12 && !section("## Context", of: out.body).contains { $0.contains("Loadmill") })
        #expect(out.changes == ["1 bullet moved to Context", "1 standing fact past the cap kept under About"])
        let again = age(out.body)
        #expect(again.body == out.body && again.changes.isEmpty)
    }

    @Test func movedBulletsMergeIntoTheirMonthLineOldestFirst() {
        let out = age("# A\n\n## Now\n- Second in July (2026-07-20)\n- First in July (2026-07-02)\n- August thing (2026-08-01)\n\n## Earlier\n- 2026-07 — already there\n")
        #expect(out.body.hasSuffix("## Earlier\n- 2026-08 — August thing\n- 2026-07 — already there; First in July; Second in July\n"), "newest month first; clauses within a month in date order after what was there")
    }

    @Test func aNestedBulletTravelsWithItsParentToEarlier() {
        let out = age("# A\n\n## Now\n- Asked about the flat (2026-07-01)\n  - the one in Pune\n  - two bedrooms\n")
        #expect(out.body == "# A\n\n## Earlier\n- 2026-07 — Asked about the flat (the one in Pune, two bedrooms)\n")
    }

    @Test func aMonthLineStaysUnder240CharactersDroppingTheOldestClauses() {
        let clauses = (1...8).map { "clause number \($0) with enough words to take up room on the line" }
        let out = age("# A\n\n## Earlier\n- 2026-07 — \(clauses.joined(separator: "; "))\n")
        let line = out.body.components(separatedBy: "\n").first { $0.hasPrefix("- 2026-07") }!
        #expect(line.count <= 240 && line.hasSuffix(clauses.last!) && !line.contains(clauses.first!))
        #expect(out.changes == ["5 Earlier clauses let go"], "what Earlier lets go is said")
        let lone = age("# A\n\n## Earlier\n- 2026-07 — \(String(repeating: "x", count: 300))\n")
        let loneLine = lone.body.components(separatedBy: "\n").first { $0.hasPrefix("- 2026-07") }!
        #expect(loneLine.count == 240 && loneLine.hasSuffix("…"))
        #expect(lone.changes == ["1 Earlier clause let go"])
    }

    @Test func earlierKeepsTwelveMonthsAndNothingPastAYear() {
        let months = ["2026-09", "2026-08", "2026-07", "2026-06", "2026-05", "2026-04", "2026-03", "2026-02", "2026-01", "2025-12", "2025-11", "2025-10", "2025-09", "2025-08"]
        let out = age("# A\n\n## Earlier\n" + months.map { "- \($0) — thing" }.joined(separator: "\n") + "\n")
        let kept = out.body.components(separatedBy: "\n").filter { $0.hasPrefix("- 20") }.map { String($0.prefix(9)) }
        #expect(kept == months.prefix(12).map { "- " + $0 }, "2025-09 is still within the year but the thirteenth line; 2025-08 is past it")
        #expect(out.changes == ["2 Earlier lines let go"])
    }

    @Test func contextKeepsItsTwelveNewestAndTheRestGoDownNotAway() {
        let ctx = (1...14).map { "- c\($0) (2026-08-\(String(format: "%02d", $0)))" }
        let out = age("# A\n\n## Context\n" + ctx.joined(separator: "\n") + "\n- undated (date unclear)\n")
        let lines = section("## Context", of: out.body)
        #expect(lines.count == 13 && lines.first == "- c14 (2026-08-14)" && lines[11] == "- c3 (2026-08-03)" && lines.last == "- undated (date unclear)",
                "twelve dated bullets stay; an unclear one has no month to go to and stays under them, uncounted")
        #expect(section("## Earlier", of: out.body) == ["- 2026-08 — c1; c2"], "the two oldest are clauses on their month, not gone")
        #expect(out.changes == ["2 bullets moved to Earlier"])
        #expect(age(out.body).changes.isEmpty)
    }

    @Test func aboutPastTheCapMovesToContextSoTheNewestFactIsNotLost() {
        let facts = (1...30).map { "- fact \($0)" } + ["- Just moved to Bengaluru for a new job at Razorpay"]
        let out = age("# A\n\n## About\n" + facts.joined(separator: "\n") + "\n")
        #expect(section("## About", of: out.body).count == 30 && out.body.contains("## Context\n- Just moved to Bengaluru for a new job at Razorpay (date unclear)\n"))
        #expect(out.changes == ["1 bullet marked date unclear", "1 About bullet past the cap moved to Context"])
        let again = age(out.body)
        #expect(again.body == out.body && again.changes.isEmpty, "the moved fact is not moved again")
        let withComment = age("# A\n\n## About\n<!-- kept -->\n" + facts.dropLast().joined(separator: "\n") + "\n")
        #expect(!withComment.body.contains("## Context") && withComment.body.contains("<!-- kept -->"), "a comment neither counts toward the cap nor moves")
    }

    @Test func retiredLinesLandInTheMonthTheySettled() {
        let retired = ["- ✅ 20 Aug — they asked: “dinner?” — you replied 2 Sep 14:00 _(not checked)_",
                       "- ✅ you promised (1 Aug): the book — done 28 Aug (you replied)",
                       "- ⌛ 1 Jul — they asked: “ride?” — no reply in 45 days; no longer tracked (lapsed 15 Aug)"]
        let out = age("# A\n\n## Earlier\n- 2026-08 — met for coffee\n", retired: retired)
        #expect(out.body == "# A\n\n## Earlier\n- 2026-09 — they asked: “dinner?” — you replied 2 Sep 14:00\n- 2026-08 — met for coffee; you promised (1 Aug): the book — done 28 Aug (you replied); they asked: “ride?” — no reply in 45 days; no longer tracked (lapsed 15 Aug)\n")
        #expect(out.changes == ["3 retired lines kept under Earlier"])
        let again = age(out.body, retired: retired)
        #expect(again.body == out.body && again.changes.isEmpty, "the same lines handed in twice leave one trace")
    }

    @Test func aDateAheadOfTodayReadsAsLastYear() {
        let out = age("# A\n", retired: ["- ✅ 20 Dec — they asked: “x” — you replied 22 Dec 10:00"])
        #expect(out.body == "# A\n\n## Earlier\n- 2025-12 — they asked: “x” — you replied 22 Dec 10:00\n")
    }

    @Test func agingIsIdempotentForTheSameNow() {
        let body = "# A\n\n## About\n- friend\n\n## Now\n- old (2026-05-05)\n- fresh (2026-09-10)\n- no date\n\n## Context\n- ctx (2026-08-08)\n\n## Earlier\n- 2026-03 — something\n"
        let once = age(body), twice = age(once.body)
        #expect(twice.body == once.body && twice.changes.isEmpty)
        #expect(once.body == "# A\n\n## About\n- friend\n\n## Now\n- fresh (2026-09-10)\n- no date (date unclear)\n\n## Context\n- ctx (2026-08-08)\n\n## Earlier\n- 2026-05 — old\n- 2026-03 — something\n")
    }

    @Test func agingTwiceOnTheTrickiestNoteChangesNothingAndLosesNothing() {
        let about = (1...30).map { "- fact \($0)" }.joined(separator: "\n")
        let body = "# Kanika\n\n## About\n<!-- template -->\n\n### Family\n- Husband: Dev\n  - met him once\n\n| Name | Role |\n|---|---|\n| Dev | husband |\n\n```\n# not a heading\n```\n\n\(about)\n\n## Now\n- Stale ask (2026-06-01)\n  - with a nested line\n- On leave (since 2026-05-01)\n- Fresh (2026-09-10)\n<!-- note to self -->\n\n## Context\n" + (1...12).map { "- c\($0) (2026-08-\(String(format: "%02d", $0)))" }.joined(separator: "\n") + "\n\n## Earlier\n- 2026-07-15 — met at the wedding\n- 2025-12 — first met; coffee\n- 2024-01 — long ago\n> an old quote\n"
        let once = age(body), twice = age(once.body)
        #expect(twice.body == once.body && twice.changes.isEmpty)
        for words in ["<!-- template -->", "fact 30", "### Family", "met him once", "| Dev | husband |", "# not a heading", "Stale ask (with a nested line)", "On leave (since 2026-05-01)", "Fresh (2026-09-10)", "<!-- note to self -->", "c1 (2026-08-01)", "2026-07-15 — met at the wedding", "first met; coffee", "> an old quote"] {
            #expect(once.body.contains(words), Comment(rawValue: words))
        }
        #expect(!once.body.contains("2024-01") && once.changes.contains("1 Earlier line let go"))
        #expect(section("## About", of: once.body).suffix(2) == ["- fact 29", "- On leave (since 2026-05-01)"], "the since that Context could not hold is a standing fact at the end of About")
        #expect(section("## Context", of: once.body).contains("- fact 30 (date unclear)"), "the thirty-first fact went down to Context")
    }
}
