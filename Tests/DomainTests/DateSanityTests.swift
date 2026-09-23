import Testing
import Foundation
@testable import Domain

/// One gate for every date: what happened is believed a day ahead and fifteen years back; what is due,
/// a year back and two years ahead; a bare year from 1990 to two years out.
@Suite struct DateSanityTests {
    let now = Date(timeIntervalSince1970: 1_789_500_000)   // 16 Sep 2026 (UTC)
    func days(_ n: Double) -> Date { now.addingTimeInterval(n * 86400) }

    @Test func itemDatesFromTheFutureOrTheDistantPastAreRefused() {
        #expect(DateSanity.item(now, now: now) == now)
        #expect(DateSanity.item(days(0.9), now: now) == days(0.9), "an hour or a few of clock skew is fine")
        #expect(DateSanity.item(days(2), now: now) == nil, "two days ahead is not")
        #expect(DateSanity.item(Date(timeIntervalSince1970: 2_001_513_725), now: now) == nil, "2033 is not")
        #expect(DateSanity.item(days(-14 * 365), now: now) != nil)
        #expect(DateSanity.item(days(-16 * 365), now: now) == nil, "sixteen years back is not a message anyone still needs")
        #expect(DateSanity.item(nil, now: now) == nil)
    }

    @Test func dueDatesLiveWithinAYearBackAndTwoAhead() {
        #expect(DateSanity.due(days(7), now: now) == days(7))
        #expect(DateSanity.due(days(-300), now: now) != nil, "an overdue promise is still a promise")
        #expect(DateSanity.due(days(-400), now: now) == nil)
        #expect(DateSanity.due(days(700), now: now) != nil)
        #expect(DateSanity.due(days(800), now: now) == nil)
        #expect(DateSanity.due(Date(timeIntervalSince1970: 2_001_513_725), now: now) == nil, "nothing is due in 2033")
        #expect(DateSanity.due(nil, now: now) == nil)
    }

    @Test func yearsRunFromNineteenNinetyToTwoYearsOut() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        #expect(DateSanity.year(1990, now: now, calendar: cal))
        #expect(!DateSanity.year(1989, now: now, calendar: cal))
        #expect(DateSanity.year(2028, now: now, calendar: cal))
        #expect(!DateSanity.year(2029, now: now, calendar: cal))
        #expect(!DateSanity.year(2033, now: now, calendar: cal))
    }
}

/// The coverage record and the sentence it becomes.
@Suite struct CoverageLineTests {
    let utc = TimeZone(identifier: "UTC")!
    let june = Date(timeIntervalSince1970: 1_781_395_200)   // 14 Jun 2026 00:00 UTC
    let sept = Date(timeIntervalSince1970: 1_789_500_000)

    @Test func theSentenceReadsLikeAPersonWroteIt() {
        let c = SourceCoverage(source: "whatsapp", oldestRead: june, newestRead: sept, itemsRead: 1240, notRead: 3, lastRun: sept, buckets: 6)
        #expect(CoverageLine.render([c], timeZone: utc) == "WhatsApp: 6 chats · read back to 14 Jun 2026 · 1,240 messages · older not read")
        let done = SourceCoverage(source: "files", oldestRead: june, newestRead: sept, itemsRead: 12, notRead: 0, lastRun: sept, buckets: 2)
        #expect(CoverageLine.render([done], timeZone: utc) == "Files: 2 folders · read back to 14 Jun 2026 · 12 files · everything read")
        let bare = SourceCoverage(source: "notes", oldestRead: nil, newestRead: nil, itemsRead: 0, notRead: 0, lastRun: sept)
        #expect(CoverageLine.render([bare], timeZone: utc) == "Apple Notes: 0 notes · everything read")
        #expect(CoverageLine.render([]) == "Nothing read yet.")
        #expect(CoverageLine.render([c, done], timeZone: utc).split(separator: "\n").count == 2, "one line per source")
    }

    @Test func mergingWidensTheRangeAndAccumulatesTheCount() {
        let first = SourceCoverage(source: "whatsapp", oldestRead: june, newestRead: june.addingTimeInterval(86400), itemsRead: 100, notRead: 40, lastRun: june, buckets: 3)
        let second = SourceCoverage(source: "whatsapp", oldestRead: june.addingTimeInterval(86400), newestRead: sept, itemsRead: 40, notRead: 0, lastRun: sept, buckets: 0)
        let m = SourceCoverage.merge(first, with: second)
        #expect(m.oldestRead == june && m.newestRead == sept && m.itemsRead == 140 && m.notRead == 0 && m.lastRun == sept && m.buckets == 3)
        let other = SourceCoverage(source: "imessage", oldestRead: nil, newestRead: nil, itemsRead: 5, notRead: 0, lastRun: sept)
        let all = SourceCoverage.merge(SourceCoverage.merge([first], with: other), with: second)
        #expect(all.map(\.source) == ["whatsapp", "imessage"] && all[0].itemsRead == 140 && all[1].itemsRead == 5)
        #expect(SourceCoverage.decode(SourceCoverage.encode(all)) == all, "round-trips through the settings JSON")
        #expect(SourceCoverage.decode(nil).isEmpty && SourceCoverage.decode("junk").isEmpty)
    }
}
