import Testing
import Foundation
@testable import LocalSources
import Domain

/// Windowing itself keeps the future out and says the year when it matters, so every chat source gets both.
@Suite struct WindowDateTests {
    let chat = ChatInfo(id: "c", name: "Nitesh", isGroup: false, memberCount: 2)
    let now = Date(timeIntervalSince1970: 1_789_500_000)   // 16 Sep 2026
    func m(_ t: Double, _ text: String = "hi") -> ChatMessage { ChatMessage(rowID: Int64(t), date: Date(timeIntervalSince1970: t), sender: "Nitesh", isMe: false, text: text) }

    @Test func futureMessagesNeverReachAWindow() {
        let msgs = [m(1_789_400_000), m(1_789_499_000), m(1_789_500_000 + 3600), m(2_001_513_725, "a 2033 row")]
        let w = ChatWindowing.windows(msgs, chat: chat, now: now)
        #expect(w.count == 1 && w[0].messageCount == 3 && w[0].lastRowID == 1_789_503_600, "an hour ahead is clock skew; 2033 is not")
        #expect(!w[0].text.contains("2033 row"))
        #expect(ChatWindowing.windows([m(2_001_513_725)], chat: chat, now: now).isEmpty, "a chat holding only a future row yields nothing")
    }

    @Test func linesCarryTheYearWhenTheWindowIsNotFromThisYear() {
        let thisYear = ChatWindowing.windows([m(1_789_400_000)], chat: chat, now: now)[0].text
        let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"
        #expect(thisYear.contains("[\(f.string(from: Date(timeIntervalSince1970: 1_789_400_000)))] Nitesh: hi"))
        #expect(!thisYear.contains("2026"), "this year's lines stay short")
        let old = ChatWindowing.windows([m(1_694_000_000, "plan for the trip")], chat: chat, now: now)[0].text   // Sep 2023
        #expect(old.contains(" 2023 "), "a 2023 plan says so on every line")
        let straddling = ChatWindowing.windows([m(1_766_000_000), m(1_789_400_000)], chat: chat, now: now)[0].text   // Dec 2025 → Sep 2026
        #expect(straddling.contains(" 2025 ") && straddling.contains(" 2026 "), "a window crossing the new year dates both sides")
    }
}
