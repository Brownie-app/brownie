import Testing
import Foundation
@testable import CloudSources
import Domain

/// What one Gmail listing asks for: the policy's window and thread cap at first read, a week after that.
@Suite struct GmailListingTests {
    @Test func aFirstReadCoversThePolicysWindowAndThreadCap() {
        let l = GmailSource.listing(firstRead: true, policy: FirstRead())
        #expect(l.query == "newer_than:30d -category:promotions" && l.maxThreads == 300)
    }

    @Test func readFurtherBackWidensTheQuery() {
        var p = FirstRead(); p.readFurtherBack("gmail")
        #expect(GmailSource.listing(firstRead: true, policy: p).query == "newer_than:120d -category:promotions")
    }

    @Test func onceReadToTheBottomAWeekIsEnoughBetweenRuns() {
        var p = FirstRead(); p.readFurtherBack("gmail")
        let l = GmailSource.listing(firstRead: false, policy: p)
        #expect(l.query == "newer_than:7d -category:promotions" && l.maxThreads == 100, "the widened window is a first-read matter; the mark does the rest")
    }
}
