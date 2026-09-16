import Testing
import Foundation
@testable import LocalSources
import Domain

/// An ask carries the chat's stable handle, so the registry can tie it to a person whatever the chat is called tonight.
@Suite struct AskHandleTests {
    let now = Date(timeIntervalSince1970: 1_758_000_000)
    func msg(_ id: Int64, _ text: String, me: Bool = false, ago: TimeInterval) -> ChatMessage { ChatMessage(rowID: id, date: now.addingTimeInterval(-ago), sender: me ? "Me" : "Nitesh", isMe: me, text: text) }

    @Test func detectCopiesTheHandleOntoEveryAsk() {
        let msgs = [msg(1, "postgres ka url kaise milega?", ago: 7200), msg(2, "here you go", me: true, ago: 3600), msg(3, "beer tonight?", ago: 600)]
        let asks = AskDetector.detect(msgs, person: "Nitesh (+919540752593)", bucket: BucketID("whatsapp:507"), since: now.addingTimeInterval(-86400), handle: PersonHandle.whatsapp(phoneDigits: "919540752593"))
        #expect(asks.count == 2 && asks.allSatisfy { $0.handle == "whatsapp:+919540752593" })
        #expect(asks[0].answeredAt != nil && asks[1].answeredAt == nil)
        #expect(AskDetector.detect(msgs, person: "Nitesh", bucket: BucketID("whatsapp:507"), since: now.addingTimeInterval(-86400)).allSatisfy { $0.handle == nil }, "no handle known, none invented")
    }

    @Test func anAskWithoutAHandleStillDecodes() throws {
        let old = #"[{"id":"a","person":"Nitesh","bucket":{"rawValue":"whatsapp:1"},"askedAt":1758000000,"question":"beer?"}]"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        let asks = try dec.decode([Ask].self, from: Data(old.utf8))
        #expect(asks.count == 1 && asks[0].handle == nil && asks[0].isOpen)
        let back = try JSONDecoder().decode([Ask].self, from: try JSONEncoder().encode([Ask(id: "b", person: "N", bucket: BucketID("w:1"), askedAt: now, question: "q", handle: "imessage:+1")]))
        #expect(back[0].handle == "imessage:+1")
    }

    @Test func aBucketWithoutAHandleIsStillABucket() {
        let b = BucketInfo(id: BucketID("whatsapp:7"), name: "Kanika Pandey Loadmill", detail: "Direct", isGroup: false, count: 100)
        #expect(b.handle == nil)
        let c = BucketInfo(id: BucketID("whatsapp:7"), name: "Kanika Pandey Loadmill", detail: "Direct", isGroup: false, count: 100, handle: "whatsapp:+919")
        #expect(c.handle == "whatsapp:+919" && b != c)
    }
}
