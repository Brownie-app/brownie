import Testing
import Foundation
@testable import Proactive
import Domain
import Support

/// A due said in words becomes a date against the run's clock — every spelling the judge has used — and words
/// that are no date leave the loop with its words and no date.
@Suite struct DueWordsTests {
    static let tz = TimeZone(identifier: "Asia/Kolkata")!
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = Self.tz; return c }
    /// Friday 18 September 2026, 3 AM — the night's run.
    var now: Date { cal.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 3))! }
    func day(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 9))! }
    func parse(_ words: String?) -> Date? { DueWords.date(words, now: now, timeZone: Self.tz) }

    @Test func everySpellingOfAMonthAndADay() {
        for words in ["September6", "Sept 6", "Sep 6", "sep 6th", "6th Sept", "6 September", "6th of September", "September 6, 2026", "6 Sep 2026", "by September 6", "on Sept. 6"] {
            #expect(parse(words) == day(2026, 9, 6), "“\(words)” is the 6th of September — twelve days ago, still a real deadline")
        }
        #expect(parse("Oct 30") == day(2026, 10, 30))
        #expect(parse("January 5") == day(2027, 1, 5), "a month long gone means next year")
        #expect(parse("14 Feb 2027") == day(2027, 2, 14), "a year said is a year kept")
    }
    @Test func theDayOfTheMonth() {
        #expect(parse("by the 30th") == day(2026, 9, 30))
        #expect(parse("the 18th") == day(2026, 9, 18), "today counts")
        #expect(parse("by the 5th") == day(2026, 10, 5), "a day already past this month is next month's")
        #expect(parse("22nd") == day(2026, 9, 22))
    }
    @Test func weekdaysAndRelativeDays() {
        #expect(parse("Tuesday") == day(2026, 9, 22), "the coming Tuesday")
        #expect(parse("by Friday") == day(2026, 9, 18), "Friday said on a Friday is today")
        #expect(parse("next Friday") == day(2026, 9, 25), "next Friday is a week off")
        #expect(parse("Mon evening") == day(2026, 9, 21))
        #expect(parse("today") == day(2026, 9, 18) && parse("tonight") == day(2026, 9, 18) && parse("EOD") == day(2026, 9, 18))
        #expect(parse("tomorrow") == day(2026, 9, 19))
        #expect(parse("in 3 days") == day(2026, 9, 21) && parse("in a week") == day(2026, 9, 25) && parse("within two weeks") == day(2026, 10, 2))
    }
    @Test func weeksAndMonths() {
        #expect(parse("this week") == day(2026, 9, 20), "the week ends on Sunday")
        #expect(parse("end of week") == day(2026, 9, 20) && parse("this weekend") == day(2026, 9, 20))
        #expect(parse("next week") == day(2026, 9, 27), "next week ends the Sunday after")
        #expect(parse("end of month") == day(2026, 9, 30) && parse("end of the month") == day(2026, 9, 30) && parse("EOM") == day(2026, 9, 30))
        #expect(parse("end of next month") == day(2026, 10, 31))
    }
    @Test func whatIsNoDateStaysWords() {
        for words in ["once uploaded", "soon", "when the design is ready", "after the call", "sometime", "September", "Q4", "6/9", ""] {
            #expect(parse(words) == nil, "“\(words)” is not a date")
        }
        #expect(parse(nil) == nil)
        #expect(parse("2019-01-01") == nil, "a date years back is not a due")
    }
    @Test func theJudgeFallsBackToTheWordsWhenItGaveNoISODate() {
        let clock = FixedClock(now, timeZone: Self.tz)
        #expect(Judge.date("2026-09-06", clock: clock) == day(2026, 9, 6))
        #expect(Judge.date(nil, clock: clock) == nil)
        // as wired in Judge.judge: the ISO day first, then the words
        #expect((Judge.date(nil, clock: clock) ?? DueWords.date("September6", now: clock.now(), timeZone: clock.timeZone)) == day(2026, 9, 6))
    }
}
