import Testing
import Foundation
@testable import LocalSources
import Domain

/// A question in a direct chat, and the reply that answers it.
@Suite struct AskDetectorTests {
    let t0 = Date(timeIntervalSince1970: 1_758_000_000)
    func m(_ i: Int, _ text: String, me: Bool = false, mins: Double) -> ChatMessage { ChatMessage(rowID: Int64(i), date: t0.addingTimeInterval(mins * 60), sender: me ? "Me" : "Nitesh", isMe: me, text: text) }

    @Test(arguments: ["dude postgres ka url kaise milega ye bata do?", "Can you send the estimates by Friday", "any update on the deck", "Please share the doc", "kab aa rahe ho", "What's the plan for Sunday?", "have you paid the deposit"]) func asks(_ s: String) { #expect(AskDetector.isAsk(s)) }
    @Test(arguments: ["ok", "thanks a lot", "sent it just now", "I'll share the steps once confirmed", "great, see you Sunday", "hi"]) func notAsks(_ s: String) { #expect(!AskDetector.isAsk(s)) }

    @Test func aReplyAfterTheQuestionAnswersIt() {
        let msgs = [m(1, "hi", mins: 0), m(2, "postgres ka url kaise milega ye bata do", mins: 5), m(3, "first wala test kar lunga mai", mins: 6), m(4, "Hi Nitesh, I'm still checking how to obtain the URL", me: true, mins: 10), m(5, "brownie would you like a beer?", mins: 11)]
        let asks = AskDetector.detect(msgs, person: "Nitesh", bucket: BucketID("whatsapp:507"), since: t0.addingTimeInterval(-3600))
        #expect(asks.count == 2)
        #expect(asks[0].question.hasPrefix("postgres ka url") && asks[0].answeredAt == t0.addingTimeInterval(600), "answered by the user's first message after it")
        #expect(asks[1].question.hasPrefix("brownie would") && asks[1].isOpen, "the newest question has no reply yet")
        #expect(asks[0].id.hasPrefix("ask-") && asks[0].id != asks[1].id)
        #expect(AskDetector.detect(msgs, person: "Nitesh", bucket: BucketID("whatsapp:507"), since: t0.addingTimeInterval(-3600)) == asks, "ids are stable across scans")
    }

    @Test func theUsersOwnQuestionsAndOldMessagesAreNotAsks() {
        let msgs = [m(1, "can you review this?", me: true, mins: 0), m(2, "kab milna hai?", mins: -5000)]
        #expect(AskDetector.detect(msgs, person: "N", bucket: BucketID("whatsapp:1"), since: t0.addingTimeInterval(-3600)).isEmpty)
    }
}
