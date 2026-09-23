import Testing
import Foundation
@testable import LocalSources
import Domain

/// The first read of a chat or a dated folder: inside the policy's window, the newest up to the cap, the rest counted.
@Suite struct FirstReadSliceTests {
    let now = Date(timeIntervalSince1970: 1_789_500_000)
    /// `count` messages one day apart, the newest today, ascending like every chat source hands them in.
    func messages(_ count: Int) -> [ChatMessage] {
        (0..<count).reversed().map { i in ChatMessage(rowID: Int64(count - i), date: now.addingTimeInterval(-Double(i) * 86_400), sender: "Amma", isMe: false, text: "day \(i)") }
    }

    /// `count` messages inside the last 90 days, evenly spaced, the newest now, ascending.
    func dense(_ count: Int, sender: String = "Rohan") -> [ChatMessage] {
        (0..<count).reversed().map { i in ChatMessage(rowID: Int64(count - i), date: now.addingTimeInterval(-Double(i) * (89 * 86_400 / Double(count))), sender: sender, isMe: false, text: "m\(i)") }
    }

    @Test func aDirectChatKeepsOnlyTheWindowWhenItHoldsFewerThanTheCap() {
        let cut = ChatWindowing.firstReadSlice(messages(1_000), isGroup: false, policy: FirstRead(), source: "whatsapp", now: now)
        #expect(cut.messages.count == 91, "90 days back, today included")
        #expect(cut.messages.first?.text == "day 90" && cut.messages.last?.text == "day 0")
        #expect(cut.deferred == 0, "the window, not the cap, was the limit")
        #expect(cut.messages.map(\.rowID) == cut.messages.map(\.rowID).sorted(), "still ascending")
    }

    @Test func aDenseDirectChatIsCappedAtTheNewestSixHundred() {
        let cut = ChatWindowing.firstReadSlice(dense(700, sender: "Amma"), isGroup: false, policy: FirstRead(), source: "whatsapp", now: now)
        #expect(cut.messages.count == 600 && cut.deferred == 100)
        #expect(cut.messages.last?.text == "m0" && cut.messages.first?.text == "m599", "the newest 600: the first kept is the 600th-newest")
        #expect(cut.messages.map(\.rowID) == cut.messages.map(\.rowID).sorted(), "still ascending")
    }

    @Test func aFutureDatedRowNeverTakesACapSlot() {
        // A row stamped three years ahead sorts last in a date-ordered query; it must not stand in for a real message under the cap.
        let bogus = ChatMessage(rowID: 9_999, date: now.addingTimeInterval(3 * 365 * 86_400), sender: "Amma", isMe: false, text: "from the future")
        let cut = ChatWindowing.firstReadSlice(dense(700, sender: "Amma") + [bogus], isGroup: false, policy: FirstRead(), source: "whatsapp", now: now)
        #expect(cut.messages.count == 600 && cut.deferred == 100, "counted as if the bogus row were not there")
        #expect(!cut.messages.contains { $0.rowID == 9_999 } && cut.messages.first?.text == "m599")
    }

    @Test func readFurtherBackGrowsTheCapSoItReachesOlderMessages() {
        // 1,500 messages inside 180 days: 90 days alone hold ~750, so the cap of 600 was the limit the first time.
        let all = (0..<1_500).reversed().map { i in ChatMessage(rowID: Int64(1_500 - i), date: now.addingTimeInterval(-Double(i) * (179 * 86_400 / 1_500)), sender: "Amma", isMe: false, text: "m\(i)") }
        let first = ChatWindowing.firstReadSlice(all, isGroup: false, policy: FirstRead(), source: "whatsapp", now: now)
        #expect(first.messages.count == 600 && first.messages.first?.text == "m599")
        var p = FirstRead(); p.readFurtherBack("whatsapp")
        let wider = ChatWindowing.firstReadSlice(all, isGroup: false, policy: p, source: "whatsapp", now: now)
        #expect(wider.messages.count == 1_200 && wider.deferred == 300, "twice the cap with twice the days")
        #expect(wider.messages.first?.text == "m1199", "600 messages older than anything the first read kept")
        #expect(ChatWindowing.firstReadSlice(all, isGroup: false, policy: p, source: "imessage", now: now).messages.count == 600, "only the source that was widened")
    }

    @Test func aBusyGroupIsCappedAtTheNewestThreeHundredAndCountsTheRest() {
        // Ten messages a day for 90 days: 900 inside the window.
        let dense = (0..<900).reversed().map { i in ChatMessage(rowID: Int64(900 - i), date: now.addingTimeInterval(-Double(i) * 8_640), sender: "Rohan", isMe: false, text: "m\(i)") }
        let cut = ChatWindowing.firstReadSlice(dense, isGroup: true, policy: FirstRead(), source: "telegram", now: now)
        #expect(cut.messages.count == 300 && cut.deferred == 600)
        #expect(cut.messages.last?.text == "m0" && cut.messages.first?.text == "m299", "the newest 300")
        let direct = ChatWindowing.firstReadSlice(dense, isGroup: false, policy: FirstRead(), source: "telegram", now: now)
        #expect(direct.messages.count == 600 && direct.deferred == 300)
    }

    @Test func readFurtherBackWidensTheSlice() {
        var p = FirstRead(); p.readFurtherBack("imessage")
        let cut = ChatWindowing.firstReadSlice(messages(1_000), isGroup: false, policy: p, source: "imessage", now: now)
        #expect(cut.messages.count == 181)
        let other = ChatWindowing.firstReadSlice(messages(1_000), isGroup: false, policy: p, source: "whatsapp", now: now)
        #expect(other.messages.count == 91, "only the source that was widened")
    }

    @Test func datedItemsKeepOnlyTheWindowAndAnUndatedItemIsKept() {
        func item(_ daysAgo: Double?, _ id: String) -> Candidate {
            Candidate(source: "files", bucket: BucketID("files:/x"), key: ItemKey(order: daysAgo ?? 0, tiebreak: id), kind: .document, id: id, itemDate: daysAgo.map { now.addingTimeInterval(-$0 * 86_400) })
        }
        let items = [item(1, "new"), item(179, "edge"), item(181, "old"), item(900, "ancient"), item(nil, "undated")]
        #expect(FirstReadFilter.inWindow(items, policy: FirstRead(), source: "files", now: now).map(\.id) == ["new", "edge", "undated"])
        #expect(FirstReadFilter.inWindow(items, policy: FirstRead(), source: "notes", now: now).map(\.id) == ["new", "edge", "old", "undated"], "notes look back a year")
        #expect(FirstReadFilter.inWindow(items, policy: FirstRead(), source: "recordings", now: now).map(\.id) == ["new", "undated"], "recordings 90 days")
    }
}
