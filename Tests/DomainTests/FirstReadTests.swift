import Testing
import Foundation
@testable import Domain

/// One first-read policy for every source: its window per source, what "Read further back" adds, and that it survives the store.
@Suite struct FirstReadTests {
    let now = Date(timeIntervalSince1970: 1_789_500_000)
    func daysBack(_ d: Date) -> Double { (now.timeIntervalSince(d) / 86_400).rounded() }

    @Test func theDefaultsAreTheSpec() {
        let p = FirstRead()
        #expect(p.chatDays == 90 && p.directChatMessages == 600 && p.groupChatMessages == 300)
        #expect(p.mailDays == 30 && p.mailThreads == 300 && p.mailNewestMessages == 6)
        #expect(p.fileDays == 180 && p.noteDays == 365 && p.voiceDays == 90)
        #expect(p.extraDays.isEmpty && FirstRead.stepDays == 90)
    }

    @Test func eachSourceGetsItsShapesWindow() {
        let p = FirstRead()
        for chat in ["whatsapp", "imessage", "telegram", "slack", "teams"] as [SourceID] { #expect(daysBack(p.window(for: chat, now: now)) == 90, "\(chat)") }
        #expect(daysBack(p.window(for: "gmail", now: now)) == 30)
        #expect(daysBack(p.window(for: "files", now: now)) == 180)
        #expect(daysBack(p.window(for: "notes", now: now)) == 365)
        #expect(daysBack(p.window(for: "voicememos", now: now)) == 90 && daysBack(p.window(for: "recordings", now: now)) == 90)
        #expect(p.chatCap(isGroup: false) == 600 && p.chatCap(isGroup: true) == 300)
    }

    @Test func readFurtherBackWidensOneSourceByAStepEachPress() {
        var p = FirstRead()
        p.readFurtherBack("whatsapp")
        #expect(p.extraDays == ["whatsapp": 90])
        #expect(daysBack(p.window(for: "whatsapp", now: now)) == 180, "one press: 90 more days")
        #expect(daysBack(p.window(for: "imessage", now: now)) == 90, "the other chats are untouched")
        p.readFurtherBack("whatsapp"); p.readFurtherBack("files")
        #expect(p.days(for: "whatsapp") == 270 && p.days(for: "files") == 270 && p.days(for: "notes") == 365)
    }

    @Test func theSettingsLineSaysWhatAFirstReadCovers() {
        var p = FirstRead()
        #expect(p.describe(for: "whatsapp") == "first read: last 90 days, up to 600 messages per direct chat and 300 per group")
        #expect(p.describe(for: "gmail") == "first read: last 30 days, up to 300 threads, the newest 6 messages of each")
        #expect(p.describe(for: "files") == "first read: files added in the last 180 days")
        #expect(p.describe(for: "notes") == "first read: notes created in the last 365 days")
        #expect(p.describe(for: "recordings") == "first read: recordings from the last 90 days")
        #expect(p.describe(for: "calendar") == nil, "the calendar has its own window; nothing to say")
        p.readFurtherBack("gmail")
        #expect(p.describe(for: "gmail")?.hasPrefix("first read: last 120 days") == true)
    }

    @Test func jsonRoundTripKeepsEveryNumberAndTheExtras() throws {
        var p = FirstRead()
        p.chatDays = 45; p.mailNewestMessages = 3; p.readFurtherBack("slack"); p.readFurtherBack("slack")
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(FirstRead.self, from: data)
        #expect(back == p)
        #expect(back.days(for: "slack") == 225)
    }

    @Test func anOlderStoredPolicyFallsBackToDefaultsForWhatItLacks() throws {
        let partial = Data(#"{"chatDays": 30, "extraDays": {"files": 90}}"#.utf8)
        let p = try JSONDecoder().decode(FirstRead.self, from: partial)
        #expect(p.chatDays == 30 && p.directChatMessages == 600 && p.noteDays == 365)
        #expect(p.days(for: "files") == 270)
        #expect(try JSONDecoder().decode(FirstRead.self, from: Data("{}".utf8)) == FirstRead())
    }
}
