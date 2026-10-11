import Testing
import Foundation
@testable import CloudSources
import Domain
import LocalSources

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

/// Mail read as a conversation. Until this existed the ask ledger could not reach mail at all: nobody's request
/// arrived by mail, so nobody's reply could close one.
@Suite struct GmailAskTests {
    static let thread = #"""
{"id":"t9","messages":[
 {"id":"m1","internalDate":"1757232000000","payload":{"headers":[
   {"name":"From","value":"Rhea Chhabra <rhea@chhabra-co.test>"},
   {"name":"To","value":"Ishan Shirke <ishan@usebrownie.com>"},
   {"name":"Subject","value":"FY25 audited accounts"}],
   "mimeType":"text/plain","body":{"data":"SGVsbG8sCgpDb3VsZCB5b3Ugc2VuZCBhY3Jvc3MgdGhlIGF1ZGl0ZWQgYWNjb3VudHMgZm9yIEZZMjUgYmVmb3JlIHRoZSBib2FyZCBjYWxsPwoKVGhhbmtzLApSaGVh"}}},
 {"id":"m2","internalDate":"1757404800000","payload":{"headers":[
   {"name":"From","value":"Ishan Shirke <ishan@usebrownie.com>"},
   {"name":"To","value":"Rhea Chhabra <rhea@chhabra-co.test>"},
   {"name":"Subject","value":"Re: FY25 audited accounts"}],
   "mimeType":"text/plain","body":{"data":"QXR0YWNoaW5nIHRoZSBhdWRpdGVkIGFjY291bnRzIGZvciBGWTI1LgoKU2VudCBmcm9tIG15IGlQaG9uZQoKT24gTW9uLCA3IFNlcCAyMDI2IGF0IDEwOjAwLCBSaGVhIENoaGFicmEgPHJoZWFAY2hoYWJyYS1jby50ZXN0PiB3cm90ZToKPiBDb3VsZCB5b3Ugc2VuZCBhY3Jvc3MgdGhlIGF1ZGl0ZWQgYWNjb3VudHMgZm9yIEZZMjUgYmVmb3JlIHRoZSBib2FyZCBjYWxsPw"}}}]}
"""#
    func wired(_ threadJSON: String = GmailAskTests.thread) -> FakeTransport {
        FakeTransport().on("users/me/profile", #"{"emailAddress":"ishan@usebrownie.com"}"#)
            .on("users/me/threads?q=", #"{"threads":[{"id":"t9","historyId":"9"}]}"#)
            .on("users/me/threads/t9", threadJSON)
    }
    func source(_ t: FakeTransport) -> GmailSource { GmailSource(transport: t, token: { "ya29" }, policy: { FirstRead() }) }
    let scan = AskScan(since: Date(timeIntervalSince1970: 1_757_000_000), selfNames: ["Ishan Shirke", "Ishan"])

    @Test func mailCarriesAsksLikeAnyOtherChannel() async throws {
        let asks = try await source(wired()).recentAsks(enabled: [BucketID("gmail:inbox")], scan: scan)
        let a = try #require(asks.first)
        #expect(asks.count == 1, "one request in the thread, not one per message")
        #expect(a.person == "Rhea Chhabra" && a.handle == "email:rhea@chhabra-co.test")
        #expect(a.bucket == BucketID("gmail:t9"), "each thread is its own chat, so one late reply does not re-read the inbox")
        #expect(a.question.contains("audited accounts for FY25"))
        #expect(a.answeredAt != nil && a.reply?.contains("Attaching the audited accounts") == true, "the user's own reply, paired")
        #expect(a.reply?.contains("wrote:") == false && a.reply?.contains(">") == false, "and without the mail it quotes")
    }

    @Test func nothingIsReadFromAnInboxTheUserHasNotChosen() async throws {
        #expect(try await source(wired()).recentAsks(enabled: [], scan: scan).isEmpty)
        #expect(try await source(wired()).recentAsks(enabled: nil, scan: scan).isEmpty)
    }

    @Test func aThreadIsAChatWithTheOtherPersonsNameOnIt() async throws {
        let chats = try await source(wired()).chats()
        #expect(chats.map(\.name) == ["Rhea Chhabra"])
        #expect(chats[0].isGroup == false && chats[0].handle == "email:rhea@chhabra-co.test" && chats[0].detail == "FY25 audited accounts")
        let msgs = try await source(wired()).messages(in: BucketID("gmail:t9"), from: .distantPast, to: .distantFuture)
        #expect(msgs.map(\.isMe) == [false, true])
        #expect(msgs[0].text.hasPrefix("FY25 audited accounts"), "the subject rides on the opening message only")
        #expect(msgs[1].text.contains("FY25 audited accounts") == false, "and not on the reply")
    }

    @Test func addressesAreReadWithOrWithoutADisplayName() {
        #expect(GmailSource.parse("Rhea Chhabra <rhea@chhabra-co.test>")?.name == "Rhea Chhabra")
        #expect(GmailSource.parse("\"Chhabra, Rhea\" <D@x.io>")?.name == "Chhabra, Rhea")
        #expect(GmailSource.parse("rhea@chhabra-co.test")?.address == "rhea@chhabra-co.test")
        #expect(GmailSource.parse("rhea@chhabra-co.test")?.name == "rhea")
        #expect(GmailSource.parse("<D@X.IO>")?.address == "d@x.io", "addresses compare lowercased")
        #expect(GmailSource.parse("not an address") == nil && GmailSource.parse("  ") == nil)
    }

    @Test func aReplyIsReadWithoutTheMailItQuotes() {
        let s = "Attaching them.\n\nOn Mon, 7 Sep 2026 at 10:00, Rhea <d@x.io> wrote:\n> Could you send the accounts?"
        #expect(GmailSource.unquote(s) == "Attaching them.")
        #expect(GmailSource.unquote("Done.\n-----Original Message-----\nFrom: x") == "Done.")
        #expect(GmailSource.unquote("Sure thing.\n--\nIshan\nBrownie") == "Sure thing.", "a signature is not a line anyone said")
    }
}
