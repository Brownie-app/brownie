import Testing
import Foundation
@testable import Proactive

@Suite struct EventTimesTests {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Kolkata")!; return c }
    func date(_ s: String) -> Date { let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"; return f.date(from: s)! }

    @Test func agreedTimesAreUsed() {
        let (s, e) = RecipeExecutor.eventTimes(startISO: "2026-09-21T10:00:00+05:30", endISO: "2026-09-21T10:30:00+05:30", now: date("2026-09-15 09:00"), calendar: cal)
        #expect(s == date("2026-09-21 10:00") && e == date("2026-09-21 10:30"))
    }
    @Test func localTimesWithoutZoneAndMissingEnd() {
        let (s, e) = RecipeExecutor.eventTimes(startISO: "2026-09-21T15:00", endISO: "", now: date("2026-09-15 09:00"), calendar: cal)
        #expect(s == date("2026-09-21 15:00") && e == date("2026-09-21 16:00"), "an hour when no end is given")
    }
    @Test func endBeforeStartIsIgnored() {
        let (s, e) = RecipeExecutor.eventTimes(startISO: "2026-09-21T15:00", endISO: "2026-09-21T14:00", now: date("2026-09-15 09:00"), calendar: cal)
        #expect(e == s.addingTimeInterval(3600))
    }
    @Test func noTimeProposesTheNextWeekdayAtTen() {
        // Tuesday 15 Sep 2026 → Wednesday 16 Sep 10:00
        let (s, e) = RecipeExecutor.eventTimes(startISO: "", endISO: "", now: date("2026-09-15 09:00"), calendar: cal)
        #expect(s == date("2026-09-16 10:00") && e == date("2026-09-16 11:00"))
        // Friday 18 Sep → Monday 21 Sep
        #expect(RecipeExecutor.eventTimes(startISO: "tbd", endISO: "", now: date("2026-09-18 17:00"), calendar: cal).0 == date("2026-09-21 10:00"))
    }
}
