import Testing
import Foundation
@testable import Proactive
import Domain
import Support

/// The judge's free-text due date, the executor's event start and a recording's own date all pass the same gate.
@Suite struct ProactiveDateGateTests {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Kolkata")!; return c }
    func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 9) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))! }

    @Test func aDueDateInTwentyThirtyThreeIsNoDueDate() {
        let clock = FixedClock(day(2026, 9, 21))
        #expect(Judge.date("2033-01-14", clock: clock) == nil)
        #expect(Judge.date("2024-01-14", clock: clock) == nil, "more than a year overdue is not a deadline the brain can know")
        #expect(Judge.date("2026-09-23", clock: clock) == day(2026, 9, 23), "next Wednesday still is")
        #expect(Judge.date("2028-06-01", clock: clock) == day(2028, 6, 1), "two years out is the far edge and still believed")
    }

    @Test func anEventStartYearsAwayFallsBackToTheProposal() {
        let now = day(2026, 9, 15)   // Tuesday
        let (s, e) = RecipeExecutor.eventTimes(startISO: "2033-01-14T10:00", endISO: "2033-01-14T11:00", now: now, calendar: cal)
        #expect(s == day(2026, 9, 16, hour: 10) && e == day(2026, 9, 16, hour: 11), "the next weekday at ten, as if no time was agreed")
        #expect(RecipeExecutor.eventTimes(startISO: "2026-09-21T15:00", endISO: "", now: now, calendar: cal).0 == day(2026, 9, 21, hour: 15))
    }

    @Test func aRecordingDatedInTheFutureOpensItsPromisesToday() {
        let now = Date(timeIntervalSince1970: 1_789_500_000), future = Date(timeIntervalSince1970: 2_001_513_725), past = Date(timeIntervalSince1970: 1_789_400_000)
        let summary = #"At [03:12] the user says "I'll send it by Thursday" to Meera."#
        #expect(TranscriptPromises.parse(summary: summary, recording: "Meera call", date: future, now: now).first?.loop.openedAt == now)
        #expect(TranscriptPromises.parse(summary: summary, recording: "Meera call", date: past, now: now).first?.loop.openedAt == past)
    }
}
