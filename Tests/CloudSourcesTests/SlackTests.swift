import Testing
import Foundation
@testable import CloudSources
import LocalSources
import Domain

let slackUsers = #"{"ok":true,"members":[{"id":"U1","name":"vivek","real_name":"Vivek Upreti","profile":{"display_name":"vivek","real_name":"Vivek Upreti"}},{"id":"U2","name":"meera","profile":{"display_name":"","real_name":"Meera Nair"}},{"id":"U3","name":"rohan","real_name":"Rohan"}]}"#
let slackList = #"""
{"ok":true,"channels":[
 {"id":"C1","name":"design","is_channel":true,"num_members":12,"is_private":false},
 {"id":"C2","name":"secret","is_channel":true,"num_members":3,"is_private":true},
 {"id":"C9","name":"old","is_channel":true,"is_archived":true,"num_members":3},
 {"id":"D1","is_im":true,"user":"U2"},
 {"id":"G1","is_mpim":true,"name":"mpdm-vivek--meera--rohan-1"}],
 "response_metadata":{"next_cursor":""}}
"""#
let slackHistory = #"""
{"ok":true,"messages":[
 {"type":"message","user":"U2","text":"Did you send the pricing notes? <@U1>","ts":"1757600000.000200"},
 {"type":"message","subtype":"channel_join","user":"U3","text":"<@U3> has joined","ts":"1757599000.000100"},
 {"type":"message","user":"U1","text":"I'll send it by Thursday, see <https://docs.example.com/x|the doc> &amp; the deck in <#C1|design>","ts":"1757590000.000100"},
 {"type":"message","user":"U2","text":"","files":[{"name":"pricing.pdf"}],"ts":"1757580000.000100"}],
 "has_more":false,"response_metadata":{"next_cursor":""}}
"""#

@Suite struct SlackParsingTests {
    @Test func usersPreferDisplayThenRealName() {
        let n = SlackParsing.users(json(slackUsers))
        #expect(n == ["U1": "vivek", "U2": "Meera Nair", "U3": "Rohan"])
    }

    @Test func channelsDMsAndGroupDMsGetReadableNames() {
        let c = SlackParsing.channels(json(slackList), names: SlackParsing.users(json(slackUsers)))
        #expect(c.map(\.name) == ["#design", "#secret", "Meera Nair", "Group DM · vivek, meera, rohan"], "archived channels are gone")
        #expect(c[0].detail == "Channel · 12 members" && c[1].detail == "Private channel · 3 members" && c[2].detail == "Direct")
        #expect(c[2].isGroup == false && c[3].isGroup == true && c[3].members == 3)
    }

    @Test func messagesAreOldestFirstReadableAndMine() {
        let m = SlackParsing.messages(json(slackHistory), me: "U1", names: SlackParsing.users(json(slackUsers)))
        #expect(m.count == 3, "the join is dropped")
        #expect(m.map(\.text) == ["[file: pricing.pdf]", "I'll send it by Thursday, see the doc & the deck in #design", "Did you send the pricing notes? @vivek"])
        #expect(m.map(\.isMe) == [false, true, false])
        #expect(m[1].sender == "vivek" && m[0].sender == "Meera Nair")
        #expect(m[1].date == Date(timeIntervalSince1970: 1757590000.0001))
        #expect(m[1].rowID == 1757590000000100)
    }

    @Test(arguments: [
        ("<@U2> ping", "@Meera Nair ping"), ("<@U7|guest> hi", "@guest hi"), ("<#C1|design>", "#design"), ("<!channel> all", "@channel all"),
        ("see <https://a.b/c>", "see https://a.b/c"), ("a &lt; b &amp; c &gt; d", "a < b & c > d"), ("plain", "plain"), ("<unterminated", "<unterminated"),
    ]) func unescape(_ pair: (String, String)) {
        #expect(SlackParsing.unescape(pair.0, names: ["U2": "Meera Nair"]) == pair.1)
    }
}

@Suite struct SlackSourceTests {
    func source(_ t: FakeTransport, token: String? = "xoxp-1", now: Date = Date(timeIntervalSince1970: 1_757_700_000)) -> SlackSource {
        SlackSource(transport: t, token: { token }, now: { now })
    }
    func wired() -> FakeTransport {
        FakeTransport().on("auth.test", #"{"ok":true,"user_id":"U1","user":"vivek"}"#).on("users.list", slackUsers).on("conversations.list", slackList).on("conversations.history", slackHistory)
    }

    @Test func availability() async {
        #expect(await source(wired(), token: nil).availability() == .needsSignIn)
        #expect(await source(wired()).availability() == .available)
        #expect(await source(FakeTransport().on("auth.test", #"{"ok":false,"error":"invalid_auth"}"#)).availability() == .needsSignIn)
        #expect(await source(FakeTransport().on("auth.test", #"{"ok":false,"error":"ratelimited"}"#)).availability() == .unavailable("ratelimited"))
    }

    @Test func discoverListsConversationsWithBucketIDs() async throws {
        let b = try await source(wired()).discoverBuckets()
        #expect(b.map(\.id.rawValue) == ["slack:C1", "slack:C2", "slack:D1", "slack:G1"])
        #expect(b[2].name == "Meera Nair" && b[2].isGroup == false)
    }

    @Test func bucketsReadOnlyChosenChatsAndWindowThem() async throws {
        let t = wired()
        let s = source(t)
        let out = try await s.buckets(since: [:], enabled: [BucketID("slack:D1")])
        #expect(out.count == 1 && out[0].id == BucketID("slack:D1"))
        #expect(t.count("conversations.history") == 1, "only the chosen DM is read")
        let hist = t.calls.first { $0.absoluteString.contains("conversations.history") }!.absoluteString
        #expect(hist.contains("channel=D1") && hist.contains("oldest=1749924000.000000"), "first read: the policy's 90 days")
        let c = try #require(out[0].items.first)
        #expect(c.kind == .directMessage && c.metadata["chat"] == "Meera Nair" && c.isGroup == false)
        #expect(c.itemDate == Date(timeIntervalSince1970: 1757600000.0002))
        #expect(Double(c.metadata["firstDate"]!)! == 1757580000.0001)
        #expect(try await s.buckets(since: [:], enabled: []).isEmpty, "nothing chosen → nothing read")
    }

    @Test func incrementalReadStartsAtTheMark() async throws {
        let t = wired()
        let out = try await source(t).buckets(since: [BucketID("slack:C1"): ItemKey(order: 1757590000.0001, tiebreak: "x")], enabled: [BucketID("slack:C1")])
        let hist = t.calls.first { $0.absoluteString.contains("conversations.history") }!.absoluteString
        #expect(hist.contains("oldest=1757590000.000100"))
        #expect(out[0].deferred == 0, "nothing is capped once a channel has been read to the bottom")
    }

    @Test func readFurtherBackMovesTheWindow() async throws {
        let t = wired()
        var p = FirstRead(); p.readFurtherBack("slack")
        _ = try await SlackSource(transport: t, token: { "xoxp-1" }, now: { Date(timeIntervalSince1970: 1_757_700_000) }, policy: { p }).buckets(since: [:], enabled: [BucketID("slack:D1")])
        let hist = t.calls.first { $0.absoluteString.contains("conversations.history") }!.absoluteString
        #expect(hist.contains("oldest=1742148000.000000"), "180 days back")
    }

    @Test func aFirstReadKeepsTheNewestUpToTheCapAndCountsTheRest() async throws {
        let t = wired()
        var p = FirstRead(); p.directChatMessages = 2
        let s = SlackSource(transport: t, token: { "xoxp-1" }, now: { Date(timeIntervalSince1970: 1_757_700_000) }, policy: { p })
        let out = try await s.buckets(since: [:], enabled: [BucketID("slack:D1")])
        #expect(out[0].deferred == 1, "three messages in the window, two kept")
        let c = try #require(out[0].items.first)
        #expect(Double(c.metadata["firstDate"]!)! == 1757590000.0001, "the oldest message fell off; the window starts at the second")
    }

    @Test func aFirstReadStoppedByThePageCapIsReportedNotSwallowed() async throws {
        let endless = slackHistory.replacingOccurrences(of: #""next_cursor":""}"#, with: #""next_cursor":"more"}"#)
        let t = FakeTransport().on("auth.test", #"{"ok":true,"user_id":"U1","user":"vivek"}"#).on("users.list", slackUsers).on("conversations.list", slackList).on("conversations.history", endless)
        let out = try await source(t).buckets(since: [:], enabled: [BucketID("slack:C1")])
        #expect(t.count("conversations.history") == SlackSource.pageCap, "a first read stops at the cap")
        #expect(out[0].deferred == 1, "and the run is told there was more")
    }

    /// A channel that gathered more than the page cap's worth of messages since the last run: the read is bounded by the
    /// mark, so it pages all the way down to it instead of stopping short and letting the mark leap past what it never saw.
    @Test func aReadSinceTheMarkPagesDownToTheMarkPastThePageCap() async throws {
        let pages = SlackSource.pageCap + 1
        func page(_ k: Int) -> String {
            let ts = 1_757_600_000 - k * 1_000
            let next = k < pages ? "p\(k + 1)" : ""
            return #"{"ok":true,"messages":[{"type":"message","user":"U2","text":"page \#(k)","ts":"\#(ts).000100"}],"response_metadata":{"next_cursor":"\#(next)"}}"#
        }
        let t = FakeTransport().on("auth.test", #"{"ok":true,"user_id":"U1","user":"vivek"}"#).on("users.list", slackUsers).on("conversations.list", slackList).on("conversations.history", page(1))
        for k in 2...pages { t.on("history?channel=C1&cursor=p\(k)", page(k)) }
        let out = try await source(t).buckets(since: [BucketID("slack:C1"): ItemKey(order: 1_757_000_000, tiebreak: "x")], enabled: [BucketID("slack:C1")])
        #expect(t.count("conversations.history") == pages, "every page down to the mark, one more than the cap")
        #expect(out[0].deferred == 0, "nothing was set aside")
        let oldest = out[0].items.compactMap { Double($0.metadata["firstDate"] ?? "") }.min()
        #expect(pages == 6 && oldest == 1_757_594_000.0001, "the message on the last page is listed")
    }

    @Test func loadRefetchesTheWindowAndRendersIt() async throws {
        let t = wired()
        let s = source(t)
        let c = try await s.buckets(since: [:], enabled: [BucketID("slack:C1")])[0].items[0]
        let a = try await s.load(c)
        let text = try #require(a.text)
        #expect(text.hasPrefix("Chat: #design · GROUP (12 members) · 3 messages, 1 of them sent by Me (the user)."))
        #expect(text.contains("Me: I'll send it by Thursday"))
        #expect(text.contains("Meera Nair: Did you send the pricing notes? @vivek"))
        let hist = t.calls.last { $0.absoluteString.contains("conversations.history") }!.absoluteString
        #expect(hist.contains("latest=1757600000.001200") && hist.contains("inclusive=true"))
    }

    @Test func slackErrorsAreReported() async throws {
        let t = FakeTransport().on("auth.test", #"{"ok":true,"user_id":"U1"}"#).on("users.list", slackUsers).on("conversations.list", #"{"ok":false,"error":"missing_scope"}"#)
        await #expect(throws: SourceError.cannotRead("Slack: missing_scope")) { try await source(t).discoverBuckets() }
        let t2 = FakeTransport().on("auth.test", status: 401, "{}")
        #expect(await source(t2).availability() != .available)
    }
}
