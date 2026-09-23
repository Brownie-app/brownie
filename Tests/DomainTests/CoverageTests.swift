import Testing
import Foundation
@testable import Domain

@Suite struct CoverageStatusTests {
    let tz = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_789_000_000)   // 2026-09-08 09:06 UTC
    func c(_ source: String, items: Int, notRead: Int = 0, newest: Date? = nil, lastRun: Date? = nil) -> SourceCoverage {
        SourceCoverage(source: SourceID(source), oldestRead: nil, newestRead: newest, itemsRead: items, notRead: notRead, lastRun: lastRun ?? now, buckets: 1)
    }
    @Test func aQuietSourceSaysSoRatherThanLookingBroken() {
        #expect(CoverageLine.status(c("gmail", items: 0), now: now, timeZone: tz) == "nothing read yet · last looked just now")
        #expect(CoverageLine.status(c("gmail", items: 2, newest: now.addingTimeInterval(-3 * 86400)), now: now, timeZone: tz).hasPrefix("2 emails read · newest 7 Sep"))
        #expect(CoverageLine.status(c("whatsapp", items: 16, notRead: 3, lastRun: now.addingTimeInterval(-7200)), now: now, timeZone: tz).contains("3 older not read · last looked 2 hours ago"))
    }
    @Test func whenItLastLookedIsSaidTheWayAPersonWouldSayIt() {
        #expect(CoverageLine.ago(now.addingTimeInterval(-30), now: now, timeZone: tz) == "just now")
        #expect(CoverageLine.ago(now.addingTimeInterval(-600), now: now, timeZone: tz) == "10 minutes ago")
        #expect(CoverageLine.ago(now.addingTimeInterval(-3600), now: now, timeZone: tz) == "an hour ago")
        #expect(CoverageLine.ago(now.addingTimeInterval(-86400), now: now, timeZone: tz) == "yesterday", "a day back is yesterday, not a date")
        #expect(CoverageLine.ago(now.addingTimeInterval(-5 * 86400), now: now, timeZone: tz) == "on 5 Sep 2026")
    }
}
