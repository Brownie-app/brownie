import Testing
import Foundation
@testable import LocalSources
import Domain

/// The labels the brain writes on evidence, read back into something the app can open.
@Suite struct EvidenceRefTests {
    @Test(arguments: [
        ("#1 · WhatsApp · nayan bsb (+919034935256)", EvidenceRef.chat(app: "whatsapp", name: "nayan bsb")),
        ("WhatsApp summary #1 · Kanika Pandey Loadmill", .chat(app: "whatsapp", name: "Kanika Pandey Loadmill")),
        ("WhatsApp with Nayan", .chat(app: "whatsapp", name: "Nayan")),
        ("iMessage · Amma · Fri", .chat(app: "imessage", name: "Amma")),
        ("Messages · Rohan", .chat(app: "imessage", name: "Rohan")),
        ("Slack · #design · Wed", .chat(app: "slack", name: "#design")),
        ("Teams · Founders · General", .chat(app: "teams", name: "Founders")),
        ("Telegram summary #3 · Goa 2026", .chat(app: "telegram", name: "Goa 2026")),
        ("People/Kanika Pandey.md", .note(path: "People/Kanika Pandey.md")),
        ("README.md", .note(path: "README.md")),
        ("Projects/Micro‑Apps (2026).md", .note(path: "Projects/Micro‑Apps (2026).md")),
        ("Loops ledger", .loops),
        ("Recording · Meera call · 03:12", .recording(name: "Meera call", seconds: 192)),
        ("Voice Memo · Standup · 1:02:05", .recording(name: "Standup", seconds: 3725)),
        ("Recording · Board call", .recording(name: "Board call", seconds: nil)),
        ("Summary #4 · Gmail Inbox", .mail(label: "Summary #4 · Gmail Inbox")),
        ("Summary #8 · Desktop", .file(label: "Desktop")),
        ("Calendar", .unknown("Calendar")),
    ]) func parses(_ c: (String, EvidenceRef)) {
        #expect(EvidenceRef.parse(source: c.0) == c.1)
    }

    @Test func datesInWhenLabels() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        func d(_ y: Int, _ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: day))! }
        #expect(EvidenceRef.date(when: "13 Sep 2026", calendar: cal) == d(2026, 9, 13))
        #expect(EvidenceRef.date(when: "13 Sep 2026 (#1)", calendar: cal) == d(2026, 9, 13))
        #expect(EvidenceRef.date(when: "2026-09-02–2026-09-13", calendar: cal) == d(2026, 9, 13), "a range → its later day")
        #expect(EvidenceRef.date(when: "undated", calendar: cal) == nil)
        #expect(EvidenceRef.date(when: "Opened; due tomorrow", calendar: cal) == nil)
        #expect(EvidenceRef.date(when: "Wed", calendar: cal) == nil)
    }

    @Test func stamps() {
        #expect(EvidenceRef.stamp("03:12") == 192); #expect(EvidenceRef.stamp("1:02:05") == 3725); #expect(EvidenceRef.stamp("Fri") == nil); #expect(EvidenceRef.stamp("12") == nil)
    }
}

@Suite struct EvidenceMatchTests {
    func m(_ i: Int64, _ t: String, me: Bool = false) -> ChatMessage { ChatMessage(rowID: i, date: Date(timeIntervalSince1970: Double(i)), sender: me ? "Me" : "Kanika", isMe: me, text: t) }
    @Test func picksTheLineTheSummaryCameFrom() {
        let msgs = [m(1, "hi, how was Goa?"), m(2, "Arif asked for perpetual pricing, can you send an update tomorrow?"), m(3, "sure, will send tomorrow after we speak", me: true), m(4, "thanks")]
        #expect(EvidenceMatch.best(msgs, text: "Kanika said Arif asked for perpetual and that the user agreed to send an update tomorrow") == 1)
        #expect(EvidenceMatch.best(msgs, text: "The user agreed to send an update tomorrow after speaking") == 2)
        #expect(EvidenceMatch.best(msgs, text: "the villa deposit for December") == nil, "nothing overlaps enough")
        #expect(EvidenceMatch.best([], text: "x") == nil)
    }
}

/// A reader over canned chats, so the resolver's rules are tested without a database.
struct FakeReader: ChatReader {
    let chatsList: [BucketInfo]; let msgs: [BucketID: [ChatMessage]]
    var asked: (BucketID, Date, Date)? { calls.value }
    let calls = Box<(BucketID, Date, Date)?>(nil)
    func chats() async throws -> [BucketInfo] { chatsList }
    func messages(in bucket: BucketID, from: Date, to: Date) async throws -> [ChatMessage] { calls.value = (bucket, from, to); return (msgs[bucket] ?? []).filter { $0.date >= from && $0.date <= to } }
}
final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

@Suite struct EvidenceResolverTests {
    let kanika = BucketInfo(id: BucketID("whatsapp:7"), name: "Kanika Pandey Loadmill", detail: "Direct", isGroup: false, count: 100)
    let nayan = BucketInfo(id: BucketID("whatsapp:9"), name: "Nayan BSB", detail: "Direct · +919034935256", isGroup: false, count: 50)
    let goa = BucketInfo(id: BucketID("whatsapp:3"), name: "Goa 2026", detail: "Group · 6 people", isGroup: true, count: 900)

    @Test func chatMatchingIsForgiving() {
        let all = [kanika, nayan, goa]
        #expect(EvidenceResolver.chat(named: "nayan bsb (+919034935256)", in: all)?.id == nayan.id)
        #expect(EvidenceResolver.chat(named: "Kanika Pandey", in: all)?.id == kanika.id, "a shorter name still finds the chat")
        #expect(EvidenceResolver.chat(named: "goa", in: all)?.id == goa.id)
        #expect(EvidenceResolver.chat(named: "Rohan", in: all) == nil)
        #expect(EvidenceResolver.chat(named: "", in: all) == nil)
    }

    @Test func resolvesAWindowAroundTheDayAndHighlightsTheLine() async throws {
        let day = EvidenceRef.date(when: "12 Sep 2026")!
        let msgs = [ChatMessage(rowID: 1, date: day.addingTimeInterval(-5 * 86400), sender: "Kanika", isMe: false, text: "old"),
                    ChatMessage(rowID: 2, date: day.addingTimeInterval(3600), sender: "Kanika", isMe: false, text: "Arif asked for perpetual, send an update tomorrow?"),
                    ChatMessage(rowID: 3, date: day.addingTimeInterval(7200), sender: "Me", isMe: true, text: "will do after we speak")]
        let r = FakeReader(chatsList: [kanika, nayan], msgs: [kanika.id: msgs])
        let w = try await EvidenceResolver.resolve(.chat(app: "whatsapp", name: "Kanika Pandey Loadmill"), when: "12 Sep 2026", text: "Kanika said Arif asked for perpetual and an update tomorrow", reader: r)
        #expect(w?.chat.id == kanika.id)
        #expect(w?.messages.map(\.rowID) == [2, 3], "the message from five days before is outside the window")
        #expect(w?.highlight == 0)
        let (b, from, to) = r.asked!
        #expect(b == kanika.id && from == day.addingTimeInterval(-2 * 86400) && to == day.addingTimeInterval(3 * 86400))
    }

    @Test func unknownDayMeansTheLastWeek() async throws {
        let now = Date(timeIntervalSince1970: 1_758_000_000)
        let r = FakeReader(chatsList: [goa], msgs: [:])
        _ = try await EvidenceResolver.resolve(.chat(app: "whatsapp", name: "Goa 2026"), when: "Fri", text: "x", reader: r, now: now)
        #expect(r.asked!.1 == now.addingTimeInterval(-7 * 86400) && r.asked!.2 == now)
    }

    @Test func nonChatsAndMissingChatsResolveToNothing() async throws {
        let r = FakeReader(chatsList: [goa], msgs: [:])
        #expect(try await EvidenceResolver.resolve(.note(path: "x.md"), when: "", text: "", reader: r) == nil)
        #expect(try await EvidenceResolver.resolve(.chat(app: "whatsapp", name: "Nobody"), when: "", text: "", reader: r) == nil)
    }
}
