import Testing
import Foundation
@testable import CloudSources
import LocalSources
import Domain

let teamsMe = #"{"id":"ME","displayName":"Vivek Upreti"}"#
let teamsChats = #"""
{"value":[
 {"id":"19:a","chatType":"oneOnOne","topic":null,"members":[{"userId":"ME","displayName":"Vivek Upreti"},{"userId":"U2","displayName":"Meera Nair"}]},
 {"id":"19:b","chatType":"group","topic":"Pricing v2","members":[{"userId":"ME","displayName":"Vivek Upreti"},{"userId":"U2","displayName":"Meera Nair"},{"userId":"U3","displayName":"Rohan"}]},
 {"id":"19:c","chatType":"group","topic":"","members":[{"userId":"ME","displayName":"Vivek Upreti"},{"userId":"U2","displayName":"Meera Nair"},{"userId":"U3","displayName":"Rohan"}]},
 {"id":"19:d","chatType":"meeting","topic":"","members":[]}]}
"""#
let teamsTeams = #"{"value":[{"id":"T1","displayName":"Founders"}]}"#
let teamsChannels = #"{"value":[{"id":"C1","displayName":"General","membershipType":"standard"},{"id":"C2","displayName":"Design","membershipType":"private"}]}"#
let teamsMessages = #"""
{"value":[
 {"id":"1757600000000","messageType":"message","createdDateTime":"2025-09-11T14:13:20.000Z","from":{"user":{"id":"U2","displayName":"Meera Nair"}},"body":{"contentType":"html","content":"<p>Did you send the pricing notes? <at id=\"0\">Vivek</at></p>"}},
 {"id":"1757599000000","messageType":"systemEventMessage","createdDateTime":"2025-09-11T13:56:40Z","body":{"contentType":"html","content":"<systemEventMessage/>"}},
 {"id":"1757590000000","messageType":"message","createdDateTime":"2025-09-11T11:26:40Z","from":{"user":{"id":"ME","displayName":"Vivek Upreti"}},"body":{"contentType":"text","content":"I'll send it by Thursday"}},
 {"id":"1757580000000","messageType":"message","createdDateTime":"2025-09-11T08:40:00Z","deletedDateTime":"2025-09-11T09:00:00Z","from":{"user":{"id":"ME","displayName":"Vivek"}},"body":{"contentType":"text","content":"oops"}},
 {"id":"1757570000000","messageType":"message","createdDateTime":"2025-09-11T05:53:20Z","from":{"user":{"id":"U2","displayName":"Meera Nair"}},"body":{"contentType":"html","content":""},"attachments":[{"name":"pricing.pdf"}]}]}
"""#
let teamsOldPage = #"{"value":[{"id":"1","messageType":"message","createdDateTime":"2025-05-01T00:00:00Z","from":{"user":{"id":"U2","displayName":"Meera Nair"}},"body":{"contentType":"text","content":"ancient"}}]}"#

@Suite struct TeamsParsingTests {
    @Test func chatsAreNamedForPeopleOrTopics() {
        let c = TeamsParsing.chats(json(teamsChats), me: "ME")
        #expect(c.map(\.name) == ["Meera Nair", "Pricing v2", "Group · Meera Nair, Rohan", "Meeting chat"])
        #expect(c.map(\.id.rawValue) == ["teams:chat:19:a", "teams:chat:19:b", "teams:chat:19:c", "teams:chat:19:d"])
        #expect(c[0].isGroup == false && c[0].detail == "Direct" && c[1].detail == "Group chat · 3 people")
    }

    @Test func channelsCarryTheTeamName() {
        let c = TeamsParsing.channels(json(teamsChannels), teamID: "T1", teamName: "Founders")
        #expect(c.map(\.name) == ["Founders · General", "Founders · Design"])
        #expect(c.map(\.id.rawValue) == ["teams:channel:T1/C1", "teams:channel:T1/C2"])
        #expect(c[1].detail == "Private channel in Founders")
    }

    @Test func messagesDropSystemEventsAndDeletionsAndFlattenHTML() {
        let m = TeamsParsing.messages(json(teamsMessages), me: "ME")
        #expect(m.map(\.text) == ["[attachment: pricing.pdf]", "I'll send it by Thursday", "Did you send the pricing notes? @Vivek"])
        #expect(m.map(\.isMe) == [false, true, false])
        #expect(m[2].date == Date(timeIntervalSince1970: 1757600000))
        #expect(m[1].rowID == 1757590000000)
    }

    @Test(arguments: [
        ("<p>Hi<br>there</p>", "Hi\nthere"), ("a &amp; b &lt;c&gt; &quot;d&quot; &#39;e&#39;&nbsp;f", "a & b <c> \"d\" 'e' f"),
        ("<div>one</div><div>two</div><div></div><div></div>three", "one\ntwo\n\nthree"), ("plain", "plain"),
    ]) func stripHTML(_ pair: (String, String)) { #expect(TeamsParsing.stripHTML(pair.0) == pair.1) }
}

@Suite struct TeamsSourceTests {
    func wired() -> FakeTransport {
        FakeTransport().on("/me/chats", teamsChats).on("/me/joinedTeams", teamsTeams).on("/teams/T1/channels/C1/messages", teamsMessages).on("/teams/T1/channels", teamsChannels)
            .on("/me/chats/19:a/messages", teamsMessages).on("/me/chats/19:b/messages", teamsOldPage).on("/me", teamsMe)
    }
    func source(_ t: FakeTransport, token: String? = "eyJ", now: Date = Date(timeIntervalSince1970: 1_757_700_000)) -> TeamsSource {
        TeamsSource(transport: t, token: { if let token { return token } else { throw MicrosoftAuth.Error.noRefreshToken } }, now: { now })
    }

    @Test func availability() async {
        #expect(await source(wired(), token: nil).availability() == .needsSignIn)
        #expect(await source(wired()).availability() == .available)
        #expect(await source(FakeTransport().on("/me", status: 403, #"{"error":{"message":"consent required"}}"#)).availability() == .unavailable("cannotRead(\"HTTP 403: consent required\")"))
    }

    @Test func discoverListsChatsThenChannels() async throws {
        let b = try await source(wired()).discoverBuckets()
        #expect(b.map(\.name) == ["Meera Nair", "Pricing v2", "Group · Meera Nair, Rohan", "Meeting chat", "Founders · General", "Founders · Design"])
        let t = wired(); _ = try await source(t).discoverBuckets()
        #expect(t.count("$expand=members") == 1 || t.count("%24expand=members") == 1, "chats come with their members in one call")
    }

    @Test func bucketsWindowTheChosenChat() async throws {
        let t = wired()
        let out = try await source(t).buckets(since: [:], enabled: [BucketID("teams:chat:19:a")])
        #expect(out.count == 1 && t.count("/messages") == 1)
        let c = try #require(out[0].items.first)
        #expect(c.kind == .directMessage && c.metadata["chat"] == "Meera Nair")
        #expect(c.itemDate == Date(timeIntervalSince1970: 1757600000))
        #expect(c.id == "teams:chat:19:a:1757600000000")
    }

    @Test func pagingStopsAtTheMarkAndKeepsOnlyNewer() async throws {
        let t = wired()
        let mark = ItemKey(order: 1757590000, tiebreak: "")   // "I'll send it by Thursday" was already read
        let out = try await source(t).buckets(since: [BucketID("teams:chat:19:a"): mark], enabled: [BucketID("teams:chat:19:a")])
        let text = try await source(t).load(out[0].items[0]).text ?? ""
        #expect(text.contains("Did you send the pricing notes?") && !text.contains("I'll send it by Thursday"))
        let old = try await source(t).buckets(since: [:], enabled: [BucketID("teams:chat:19:b")])
        #expect(old[0].items.isEmpty, "a page older than the policy's 90 days yields nothing at first read")
    }

    @Test func readFurtherBackReachesTheOlderPage() async throws {
        var p = FirstRead(); p.readFurtherBack("teams"); p.readFurtherBack("teams")
        let s = TeamsSource(transport: wired(), token: { "eyJ" }, now: { Date(timeIntervalSince1970: 1_757_700_000) }, policy: { p })
        let old = try await s.buckets(since: [:], enabled: [BucketID("teams:chat:19:b")])
        #expect(old[0].items.count == 1 && old[0].deferred == 0, "270 days back, May is inside the window")
    }

    @Test func aFirstReadKeepsTheNewestUpToTheCapAndCountsTheRest() async throws {
        var p = FirstRead(); p.groupChatMessages = 1
        let s = TeamsSource(transport: wired(), token: { "eyJ" }, now: { Date(timeIntervalSince1970: 1_757_700_000) }, policy: { p })
        let out = try await s.buckets(since: [:], enabled: [BucketID("teams:channel:T1/C1")])
        #expect(out[0].deferred == 2, "three messages in the window, one kept")
        #expect(out[0].items.count == 1 && out[0].items[0].itemDate == Date(timeIntervalSince1970: 1757600000))
    }

    @Test func aFirstReadStoppedByThePageCapIsReportedNotSwallowed() async throws {
        let endless = teamsMessages.replacingOccurrences(of: #"{"value":["#, with: #"{"@odata.nextLink":"https://graph.microsoft.com/v1.0/me/chats/19:a/messages?$top=50&$skiptoken=x","value":["#)
        let t = FakeTransport().on("/me/chats", teamsChats).on("/me/joinedTeams", teamsTeams).on("/teams/T1/channels", teamsChannels).on("/me/chats/19:a/messages", endless).on("/me", teamsMe)
        let out = try await source(t).buckets(since: [:], enabled: [BucketID("teams:chat:19:a")])
        #expect(t.count("/me/chats/19:a/messages") == TeamsSource.pageCap, "a first read stops at the cap")
        #expect(out[0].deferred == 1, "and the run is told there was more")
    }

    /// A chat that gathered more than the page cap's worth of messages since the last run: the read is bounded by the
    /// mark, so it pages all the way down to it instead of stopping short and letting the mark leap past what it never saw.
    @Test func aReadSinceTheMarkPagesDownToTheMarkPastThePageCap() async throws {
        let pages = TeamsSource.pageCap + 1
        func message(_ k: Int) -> String {
            #"{"id":"\#(k)","messageType":"message","createdDateTime":"2025-09-11T14:\#(String(format: "%02d", 30 - k)):00Z","from":{"user":{"id":"U2","displayName":"Meera Nair"}},"body":{"contentType":"text","content":"page \#(k)"}}"#
        }
        func page(_ k: Int) -> String {
            let next = k < pages ? #""@odata.nextLink":"https://graph.microsoft.com/v1.0/me/chats/19:a/messages?$top=50&$skiptoken=p\#(k + 1)","# : ""
            let older = k == pages ? "," + message(k).replacingOccurrences(of: "2025-09-11T14:15:00Z", with: "2025-09-01T09:00:00Z") : ""
            return "{" + next + #""value":["# + message(k) + older + "]}"
        }
        let t = FakeTransport().on("/me/chats", teamsChats).on("/me/joinedTeams", teamsTeams).on("/teams/T1/channels", teamsChannels).on("/me/chats/19:a/messages", page(1)).on("/me", teamsMe)
        for k in 2...pages { t.on("19:a/messages?$top=50&$skiptoken=p\(k)", page(k)) }
        let out = try await source(t).buckets(since: [BucketID("teams:chat:19:a"): ItemKey(order: 1_757_000_000, tiebreak: "")], enabled: [BucketID("teams:chat:19:a")])
        #expect(t.count("/me/chats/19:a/messages") == pages, "every page down to the one that holds the mark, one more than the cap")
        #expect(out[0].deferred == 0, "nothing was set aside")
        let oldest = out[0].items.compactMap { Double($0.metadata["firstDate"] ?? "") }.min()
        #expect(oldest == 1_757_600_100, "the message on the last page, just above the mark, is listed; the one below it is not")
    }

    @Test func loadRendersTheWindow() async throws {
        let s = source(wired())
        let c = try await s.buckets(since: [:], enabled: [BucketID("teams:channel:T1/C1")])[0].items[0]
        let text = try #require(try await s.load(c).text)
        #expect(text.hasPrefix("Chat: Founders · General · GROUP"))
        #expect(text.contains("Me: I'll send it by Thursday") && text.contains("Meera Nair: Did you send the pricing notes? @Vivek"))
    }
}
