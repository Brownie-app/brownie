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

    @Test func aDirectChatKeepsTheWindowThenTheNewestSixHundred() {
        let cut = ChatWindowing.firstReadSlice(messages(1_000), isGroup: false, policy: FirstRead(), source: "whatsapp", now: now)
        #expect(cut.messages.count == 91, "90 days back, today included")
        #expect(cut.messages.first?.text == "day 90" && cut.messages.last?.text == "day 0")
        #expect(cut.deferred == 0, "the window, not the cap, was the limit")
        #expect(cut.messages.map(\.rowID) == cut.messages.map(\.rowID).sorted(), "still ascending")
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
