import Testing
import Foundation
@testable import Proactive
import Domain

/// The user's word on the notes becomes the lines the note builder reads before it writes; the Sunday letter owns them.
@Suite struct NoteFeedbackDigestTests {
    // 2026-09-18 12:00 UTC, a Friday.
    let now = Date(timeIntervalSince1970: 1_789_732_800)
    func fb(_ v: NoteFeedback.Verdict = .notRight, title: String = "Meera Iyer", reason: String? = "too much hedging", daysAgo: Double = 1) -> NoteFeedback {
        NoteFeedback(path: "People/\(title).md", title: title, contentHash: "h", verdict: v, reason: reason, at: now.addingTimeInterval(-daysAgo * 86400))
    }
    func day(_ daysAgo: Double) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "d MMM"; return f.string(from: now.addingTimeInterval(-daysAgo * 86400)) }

    @Test func nothingSaysNothing() { #expect(NoteFeedbackDigest.instructions([], now: now) == "") }

    @Test func correctionsAreStandingInstructionsNewestFirstUnderTheHeader() {
        let s = NoteFeedbackDigest.instructions([fb(reason: "this promise is not real", daysAgo: 3), fb(title: "Karan", reason: "wrong person", daysAgo: 1)], now: now)
        #expect(s == """
        WHAT YOU CORRECTED IN THE NOTES (standing instructions, newest first):
        - wrong person (about Karan, \(day(1)))
        - this promise is not real (about Meera Iyer, \(day(3)))
        """)
    }

    @Test func theSameWordingTwiceIsOneLineTheNewest() {
        let s = NoteFeedbackDigest.instructions([fb(title: "Karan", reason: "Too much hedging.", daysAgo: 5), fb(title: "Priya", reason: " too  much hedging ", daysAgo: 2), fb(title: "Arif", reason: "Wrong person", daysAgo: 1)], now: now)
        let lines = s.split(separator: "\n").dropFirst()
        #expect(lines.count == 2)
        #expect(lines.first == "- Wrong person (about Arif, \(day(1)))")
        #expect(lines.last == "- too  much hedging (about Priya, \(day(2)))", "case, spacing and a trailing stop make it the same lesson; the newest says it, in its own words")
    }

    @Test func aNotRightWithNothingTypedTeachesNoLine() {
        #expect(NoteFeedbackDigest.instructions([fb(reason: nil)], now: now) == "", "nothing to instruct")
        let s = NoteFeedbackDigest.instructions([fb(reason: nil, daysAgo: 1), fb(title: "Karan", reason: "wrong person", daysAgo: 2)], now: now)
        #expect(s.split(separator: "\n").count == 2 && s.contains("- wrong person (about Karan"))
    }

    @Test func notesCalledRightAreNamedOnceAtTheEndByTheirLatestWord() {
        let s = NoteFeedbackDigest.instructions([fb(.good, title: "Priya", reason: nil, daysAgo: 4), fb(title: "Karan", reason: "wrong person", daysAgo: 2), fb(.good, title: "Building Chat", reason: nil, daysAgo: 1)], now: now)
        #expect(s.hasSuffix("\nNotes you called right: Building Chat, Priya — keep that style."), "newest first, after the corrections")
        #expect(NoteFeedbackDigest.instructions([fb(.good, title: "Priya", reason: nil)], now: now) == "Notes you called right: Priya — keep that style.", "with no correction there is no header, only the praise")
        // Called right on Monday, not right on Thursday: the latest word is what counts, and the correction still teaches.
        let turned = NoteFeedbackDigest.instructions([fb(.good, title: "Priya", reason: nil, daysAgo: 4), fb(title: "Priya", reason: "too much hedging", daysAgo: 1)], now: now)
        #expect(!turned.contains("called right") && turned.contains("- too much hedging (about Priya"))
        // Not right on Monday, right on Thursday: the lesson stays, and the note is praised.
        let mended = NoteFeedbackDigest.instructions([fb(title: "Priya", reason: "too much hedging", daysAgo: 4), fb(.good, title: "Priya", reason: nil, daysAgo: 1)], now: now)
        #expect(mended.contains("- too much hedging (about Priya") && mended.hasSuffix("Notes you called right: Priya — keep that style."))
    }

    @Test func praiseNamesAtMostEightAndLessonsFillAtMostTwentyFourLines() {
        let goods = (0..<12).map { fb(.good, title: "Note \($0)", reason: nil, daysAgo: Double($0) / 10) }
        let praise = NoteFeedbackDigest.instructions(goods, now: now)
        #expect(praise == "Notes you called right: " + (0..<8).map { "Note \($0)" }.joined(separator: ", ") + " — keep that style.")
        let many = (0..<40).map { fb(title: "Note \($0)", reason: "lesson \($0)", daysAgo: Double($0) / 10) }
        let lines = NoteFeedbackDigest.instructions(many, now: now).split(separator: "\n")
        #expect(lines.count == NoteFeedbackDigest.maxLines + 1, "the header and twenty-four lessons")
        #expect(lines[1].hasPrefix("- lesson 0 ") && lines.last!.hasPrefix("- lesson 23 "), "newest first")
    }

    @Test func oldLessonsFade() {
        #expect(NoteFeedbackDigest.instructions([fb(daysAgo: 90)], now: now) == "", "ninety-day horizon")
        #expect(NoteFeedbackDigest.instructions([fb(.good, reason: nil, daysAgo: 90)], now: now) == "")
        #expect(NoteFeedbackDigest.instructions([fb(daysAgo: 89.9)], now: now).contains("too much hedging"))
    }

    @Test func weekLineOwnsTheCorrectionsAndThePraise() {
        let since = now.addingTimeInterval(-6 * 86400)
        #expect(NoteFeedbackDigest.weekLine([], since: since) == "")
        #expect(NoteFeedbackDigest.weekLine([fb(daysAgo: 10)], since: since) == "", "only this week")
        let line = NoteFeedbackDigest.weekLine([fb(reason: "too much hedging", daysAgo: 3), fb(title: "Karan", reason: "this promise is not real", daysAgo: 2), fb(title: "Arif", reason: nil, daysAgo: 1), fb(.good, title: "Priya", reason: nil, daysAgo: 1)], since: since)
        #expect(line == "You corrected 3 notes this week: Arif (no reason given) · this promise is not real (Karan) · too much hedging (Meera Iyer). Those lessons are now in Brownie's standing instructions for the notes. You called 1 note right: Priya.")
        #expect(NoteFeedbackDigest.weekLine([fb(title: "Karan", reason: "wrong person", daysAgo: 1)], since: since) == "You corrected 1 note this week: wrong person (Karan). Those lessons are now in Brownie's standing instructions for the notes.")
        #expect(NoteFeedbackDigest.weekLine([fb(.good, title: "Priya", reason: nil), fb(.good, title: "Karan", reason: nil, daysAgo: 2)], since: since) == "You called 2 notes right: Priya, Karan.")
        // Corrected on Tuesday, called right on Thursday: one note, and this week it ended up right.
        #expect(NoteFeedbackDigest.weekLine([fb(title: "Priya", reason: "x", daysAgo: 4), fb(.good, title: "Priya", reason: nil, daysAgo: 1)], since: since) == "You called 1 note right: Priya.")
    }

    @Test func roundTripsThroughJSON() throws {
        let f = fb(reason: "hi")
        #expect(try JSONDecoder().decode(NoteFeedback.self, from: JSONEncoder().encode(f)) == f)
    }
}
