import Testing
import Foundation
@testable import Domain

/// The user's word on a note: one per note per day, ninety days of them, two hundred at most, kept as a plain JSON array.
@Suite struct NoteFeedbackTests {
    // 2026-09-18 12:00 UTC, a Friday.
    static let now = Date(timeIntervalSince1970: 1_789_732_800)
    static let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    static func at(daysAgo: Double, hours: Double = 0) -> Date { now.addingTimeInterval(-daysAgo * 86400 + hours * 3600) }
    func fb(_ v: NoteFeedback.Verdict = .notRight, path: String = "People/Meera.md", reason: String? = "too much hedging", daysAgo: Double = 0, hours: Double = 0) -> NoteFeedback {
        NoteFeedback(path: path, title: String(path.split(separator: "/").last!.dropLast(3)), contentHash: "h", verdict: v, reason: reason, at: Self.at(daysAgo: daysAgo, hours: hours))
    }
    func list(_ entries: [NoteFeedback]) -> NoteFeedbackList { var l = NoteFeedbackList(); for e in entries { l.add(e, now: Self.now, calendar: Self.utc) }; return l }

    @Test func aReasonIsTrimmedAndNothingTypedIsNoReason() {
        #expect(fb(reason: "  too much hedging \n").reason == "too much hedging")
        #expect(fb(reason: "   ").reason == nil && fb(reason: "").reason == nil && fb(.good, reason: nil).reason == nil)
    }

    @Test func oneWordPerNotePerDayTheNewestWins() {
        let morning = fb(.good, reason: nil, hours: -4), afternoon = fb(.notRight, reason: "wrong person", hours: -1)
        let l = list([morning, afternoon])
        #expect(l.entries == [afternoon], "the afternoon's word replaces the morning's")
        #expect(l.latest(for: "People/Meera.md") == afternoon && l.latest(for: "People/Karan.md") == nil)
        let yesterday = fb(.good, reason: nil, daysAgo: 1)
        #expect(list([yesterday, afternoon]).entries == [yesterday, afternoon], "a word on another day stands beside it, oldest first")
        let other = fb(.good, path: "People/Karan.md", reason: nil, hours: -2)
        #expect(list([other, afternoon]).entries == [other, afternoon], "another note the same day is its own entry")
    }

    @Test func theDayIsTheCalendarsNotTwentyFourHours() {
        // 23:30 and 00:30 UTC are eighteen hours apart on the clock but two days on the calendar.
        let late = fb(.good, reason: nil, daysAgo: 0, hours: -12.5), early = fb(.notRight, hours: -11.5)
        #expect(Self.utc.isDate(late.at, inSameDayAs: early.at) == false)
        #expect(list([late, early]).entries.count == 2)
        var ist = Calendar(identifier: .gregorian); ist.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        var l = NoteFeedbackList(); l.add(late, now: Self.now, calendar: ist); l.add(early, now: Self.now, calendar: ist)
        #expect(l.entries == [early], "in Kolkata both fall on the same day, so the later replaces the earlier")
    }

    @Test func ninetyDaysIsTheHorizonAndTwoHundredTheCap() {
        let old = fb(path: "People/Old.md", daysAgo: 90), kept = fb(path: "People/Kept.md", daysAgo: 89.9), new = fb()
        #expect(list([old, kept, new]).entries == [kept, new], "ninety days on the dot is gone; a hair less stays")
        var l = NoteFeedbackList()
        for i in 0..<210 { l.add(fb(path: "People/P\(i).md", daysAgo: Double(210 - i) / 10), now: Self.now, calendar: Self.utc) }
        #expect(l.entries.count == NoteFeedbackList.cap && l.entries.first?.path == "People/P10.md" && l.entries.last?.path == "People/P209.md", "the oldest ten fell off the front")
    }

    @Test func recentIsNewestFirstWithinTheWindow() {
        let l = list([fb(path: "People/A.md", daysAgo: 31), fb(path: "People/B.md", daysAgo: 29), fb(path: "People/C.md", daysAgo: 1)])
        #expect(l.recent(within: 30 * 86400, now: Self.now).map(\.path) == ["People/C.md", "People/B.md"])
    }

    @Test func theJSONIsAPlainArrayAndReadsBackWhatWasWrittenOrNothing() throws {
        let l = list([fb(.good, reason: nil, daysAgo: 1), fb(reason: "this promise is not real")])
        #expect(l.json.hasPrefix("["), "a plain array under the key, like the card feedback")
        #expect(NoteFeedbackList.decode(l.json) == l)
        #expect(NoteFeedbackList.decode(nil).entries.isEmpty && NoteFeedbackList.decode("not json").entries.isEmpty && NoteFeedbackList.decode("").entries.isEmpty)
        // A row written without a reason (a Good) decodes with none; a row this build cannot read is a list it cannot read — nothing, never a crash.
        let row = #"[{"path":"People/Meera.md","title":"Meera","contentHash":"h","verdict":"good","at":812000000}]"#
        #expect(NoteFeedbackList.decode(row).entries.first?.reason == nil && NoteFeedbackList.decode(row).entries.first?.verdict == .good)
        #expect(NoteFeedbackList.decode(#"[{"path":"p","title":"t","contentHash":"h","verdict":"meh","at":1}]"#).entries.isEmpty)
    }

    @Test func aListMadeFromEntriesIsOldestFirst() {
        let a = fb(path: "People/A.md", daysAgo: 2), b = fb(path: "People/B.md", daysAgo: 1)
        #expect(NoteFeedbackList([b, a]).entries == [a, b])
        #expect(NoteFeedback.Verdict.good.label == "good" && NoteFeedback.Verdict.notRight.label == "not right")
    }
}
