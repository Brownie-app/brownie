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

/// What a Gmail listing hands the core: the threads under the cap, and a count of what the cap set aside.
@Suite struct GmailBucketsTests {
    func source(_ t: FakeTransport, _ p: FirstRead = FirstRead()) -> GmailSource { GmailSource(transport: t, token: { "ya29" }, policy: { p }) }
    func threads(_ ids: [Int], next: String? = nil) -> String {
        let list = ids.map { #"{"id":"t\#($0)","historyId":"\#($0)"}"# }.joined(separator: ",")
        return #"{"threads":[\#(list)]"# + (next.map { #","nextPageToken":"\#($0)""# } ?? "") + "}"
    }

    @Test func aFirstReadPastTheThreadCapCountsWhatItSetAside() async throws {
        var p = FirstRead(); p.mailThreads = 2
        // Gmail hands back one more than asked for and says there is another page: both are counted, neither is lost quietly.
        let t = FakeTransport().on("users/me/threads?q=", threads([300, 200, 100], next: "p2"))
        let out = try await source(t, p).buckets(since: [:], enabled: nil)
        #expect(out[0].items.map(\.id) == ["t300", "t200"], "the cap holds")
        #expect(out[0].deferred == 2, "one thread past the cap on this page, and a page never asked for")
        #expect(t.count("users/me/threads?q=") == 1, "the second page is not fetched once the cap is full")
    }

    @Test func aListingThatEndsInsideTheCapSetsNothingAside() async throws {
        var p = FirstRead(); p.mailThreads = 2
        let t = FakeTransport().on("users/me/threads?q=", threads([300], next: "p2")).on("maxResults=1&pageToken=p2", threads([200]))
        let out = try await source(t, p).buckets(since: [:], enabled: nil)
        #expect(out[0].items.map(\.id) == ["t300", "t200"] && out[0].deferred == 0)
        #expect(t.count("users/me/threads?q=") == 2, "both pages, the second asked for only what the cap still allows")
    }

    @Test func aWeekWithMoreThanAHundredThreadsIsReportedBetweenRuns() async throws {
        let t = FakeTransport().on("users/me/threads?q=", threads(Array((1...100).reversed()), next: "p2"))
        let out = try await source(t).buckets(since: [GmailSource.bucket: ItemKey(order: 1, tiebreak: "t1")], enabled: nil)
        #expect(out[0].items.count == 100 && out[0].deferred == 1, "the page never asked for counts as one")
    }
}
