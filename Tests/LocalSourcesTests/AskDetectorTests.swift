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

    @Test func aReplyOnDayFourIsFoundWhenTheScanReachesBackToTheAsk() {
        // asked four days ago, answered this morning: a three-day window sees the reply with no question in it and finds nothing
        let day = 1440.0
        let msgs = [m(1, "can you send the estimates?", mins: -4 * day), m(2, "sent them just now", me: true, mins: -30)]
        let threeDays = AskDetector.detect(msgs, person: "Nitesh", bucket: BucketID("whatsapp:507"), since: t0.addingTimeInterval(-3 * 86400))
        #expect(threeDays.isEmpty, "the question is outside the window, so the reply pairs with nothing")
        // the scan window reaches back to the open ask (an hour before it), and the reply is paired
        let widened = AskDetector.detect(msgs, person: "Nitesh", bucket: BucketID("whatsapp:507"), since: t0.addingTimeInterval(-4 * 86400 - 3600))
        #expect(widened.count == 1 && widened[0].isAnswered && widened[0].answeredAt == t0.addingTimeInterval(-1800))
        let earlier = AskDetector.detect([msgs[0]], person: "Nitesh", bucket: BucketID("whatsapp:507"), since: t0.addingTimeInterval(-5 * 86400))
        #expect(earlier[0].id == widened[0].id && earlier[0].isOpen, "the same ask, by id, that the earlier scan left open")
    }

    @Test func theUsersOwnQuestionsAndOldMessagesAreNotAsks() {
        let msgs = [m(1, "can you review this?", me: true, mins: 0), m(2, "kab milna hai?", mins: -5000)]
        #expect(AskDetector.detect(msgs, person: "N", bucket: BucketID("whatsapp:1"), since: t0.addingTimeInterval(-3600)).isEmpty)
    }

    @Test func aReplyJudgedOffTopicGivesWayToTheUsersNextMessage() {
        // day 0 the question, day 1 "lol" about something else, day 3 the answer
        let day = 1440.0, since = t0.addingTimeInterval(-4 * 86400), b = BucketID("whatsapp:507")
        let ask = m(1, "can you send the estimates?", mins: -3 * day), lol = m(2, "lol", me: true, mins: -2 * day), sent = m(3, "here are the estimates", me: true, mins: -30)
        let first = AskDetector.detect([ask, lol], person: "Nitesh", bucket: b, since: since)
        #expect(first.count == 1 && first[0].reply == "lol", "the first message after the question is offered first")
        let judged = [first[0].id: first[0].answeredAt!]
        #expect(AskDetector.detect([ask, lol], person: "Nitesh", bucket: b, since: since, judged: judged) == first, "nothing after it yet: the judged reply stands, so the ask still says the user wrote but not about it")
        let later = AskDetector.detect([ask, lol, sent], person: "Nitesh", bucket: b, since: since, judged: judged)
        #expect(later.count == 1 && later[0].id == first[0].id && later[0].answeredAt == sent.date && later[0].reply == "lol\nhere are the estimates", "the user's next message after the judged one is the reply now, with the judged one before it for the judge to read")
        #expect(AskDetector.detect([ask, lol, sent], person: "Nitesh", bucket: b, since: since)[0].reply == "lol", "unjudged, the first reply is still the one offered")
    }

    @Test func oneNightMovesPastEveryMessageAfterTheJudgedReply() {
        // Monday the question, "ha" judged off-topic; six unrelated messages over two days; Wednesday the answer
        let day = 1440.0, since = t0.addingTimeInterval(-4 * 86400), b = BucketID("whatsapp:507")
        let ask = m(1, "can you send the estimates?", mins: -3 * day), ha = m(2, "ha", me: true, mins: -3 * day + 30)
        let chatter = ["see you at the ground", "traffic is mad today", "did you watch the match", "lunch at 1", "running late", "call you after"].enumerated().map { m(10 + $0.offset, $0.element, me: true, mins: -2 * day + Double($0.offset) * 60) }
        let sent = m(30, "here are the estimates, sorry for the wait", me: true, mins: -30)
        let judged = [AskDetector.detect([ask, ha], person: "Nitesh", bucket: b, since: since)[0].id: ha.date]
        let night = AskDetector.detect([ask, ha] + chatter + [sent], person: "Nitesh", bucket: b, since: since, judged: judged)
        #expect(night.count == 1 && night[0].answeredAt == sent.date, "paired with the newest message, not the first after the judged one")
        let lines = night[0].reply!.split(separator: "\n").map(String.init)
        #expect(lines.count == 6 && lines.last == "here are the estimates, sorry for the wait" && lines.first == "traffic is mad today", "the judge reads the last six, newest last")
        #expect(night[0].reply!.count <= 400, "within the judge's prompt")
        // nothing new the night after: the same message is paired with the same text, so the judgement about it is kept
        let again = AskDetector.detect([ask, ha] + chatter + [sent], person: "Nitesh", bucket: b, since: since, judged: [night[0].id: sent.date])
        #expect(again[0].answeredAt == sent.date && again[0].reply == night[0].reply)
        // the same six unrelated messages with no answer yet: paired with the newest, all six shown, and the one before them left behind
        let quiet = AskDetector.detect([ask, ha] + chatter, person: "Nitesh", bucket: b, since: since, judged: judged)
        #expect(quiet[0].answeredAt == chatter.last!.date && quiet[0].reply == chatter.map(\.text).joined(separator: "\n"))
        // a long message keeps its share of the room, so the newest is never cut away by the ones before it
        let long = m(40, String(repeating: "estimates ", count: 60), me: true, mins: -20)
        let cut = AskDetector.detect([ask, ha] + chatter + [long], person: "Nitesh", bucket: b, since: since, judged: judged)[0].reply!
        #expect(cut.split(separator: "\n").count == 6 && cut.split(separator: "\n").last!.count == 65 && cut.split(separator: "\n").last!.hasPrefix("estimates estimates"))
    }

    @Test func theWindowIsTheExchangeAfterTheAskFromBothSides() {
        let b = BucketID("whatsapp:507"), since = t0.addingTimeInterval(-3600)
        let msgs = [m(1, "hi", mins: 0), m(2, "can you send the url?", mins: 5), m(3, "need it for the test", mins: 6), m(4, "let me check", me: true, mins: 10), m(5, "thanks,\nworks now", mins: 12), m(6, "", me: true, mins: 13)]
        let asks = AskDetector.detect(msgs, person: "Nitesh", bucket: b, since: since)
        #expect(asks.count == 1)
        #expect(asks[0].window == [AskLine(at: msgs[2].date, mine: false, text: "need it for the test"), AskLine(at: msgs[3].date, mine: true, text: "let me check"), AskLine(at: msgs[4].date, mine: false, text: "thanks, works now")],
                "both sides, oldest first, one line each; a blank line is left out")
        #expect(asks[0].reply == "let me check" && asks[0].answeredAt == msgs[3].date, "the reply is still the user's first message, as before")
        #expect(AskDetector.detect([msgs[0], msgs[1]], person: "Nitesh", bucket: b, since: since)[0].window == [], "nothing after it yet: an empty window")
        // a later read brings a longer window under the same id
        let later = AskDetector.detect(msgs + [m(7, "welcome", me: true, mins: 20)], person: "Nitesh", bucket: b, since: since)[0]
        #expect(later.id == asks[0].id && later.window?.count == 4 && later.window?.last?.text == "welcome")
    }

    @Test func theWindowKeepsTheNewestTwelveLinesAndFitsTheRoom() {
        let b = BucketID("whatsapp:507"), since = t0.addingTimeInterval(-3600)
        let chatter = (0..<20).map { m(10 + $0, "line \($0)", me: $0 % 2 == 0, mins: 10 + Double($0)) }
        let w = AskDetector.detect([m(1, "can you send the url?", mins: 5)] + chatter, person: "Nitesh", bucket: b, since: since)[0].window!
        #expect(w.count == 12 && w.first?.text == "line 8" && w.last?.text == "line 19", "the newest twelve, oldest first")
        #expect(w.map(\.mine) == (8..<20).map { $0 % 2 == 0 })
        // one long line and eleven short ones: the short ones keep every word, the long one takes what is left of the room
        let long = m(40, String(repeating: "estimates ", count: 200), me: true, mins: 40)
        let cut = AskDetector.detect([m(1, "can you send the url?", mins: 5)] + chatter + [long], person: "Nitesh", bucket: b, since: since)[0].window!
        #expect(cut.count == 12 && cut.dropLast().allSatisfy { $0.text.hasPrefix("line ") } && cut.last!.text.count == 900 - cut.dropLast().reduce(0) { $0 + $1.text.count })
        #expect(cut.reduce(0) { $0 + $1.text.count } == 900)
        // twelve long lines share the room evenly
        let longs = (0..<12).map { m(50 + $0, String(repeating: "x", count: 500), me: false, mins: 50 + Double($0)) }
        let even = AskDetector.detect([m(1, "can you send the url?", mins: 5)] + longs, person: "Nitesh", bucket: b, since: since)[0].window!
        #expect(even.allSatisfy { $0.text.count == 75 })
        #expect(AskDetector.fit([], room: 900) == [] && AskDetector.fit(["ab", "cd"], room: 900) == ["ab", "cd"])
    }

    /// A source of two direct chats that remembers how far back each was read.
    final class TwoChats: ChatReader, Source, @unchecked Sendable {
        static let descriptor = SourceDescriptor(id: "fake", name: "Fake", detail: "", door: .localDatabase, supportsPerBucketOptIn: true)
        let msgs: [BucketID: [ChatMessage]]
        private let lock = NSLock()
        private var reads: [BucketID: Date] = [:]
        var readFrom: [BucketID: Date] { lock.withLock { reads } }
        init(_ msgs: [BucketID: [ChatMessage]]) { self.msgs = msgs }
        func availability() async -> Availability { .available }
        func buckets(since marks: [BucketID: ItemKey], enabled: Set<BucketID>?) async throws -> [Bucket] { [] }
        func load(_ c: Candidate) async throws -> Artifact { Artifact(candidate: c, text: "") }
        func chats() async throws -> [BucketInfo] { msgs.keys.sorted { $0.rawValue < $1.rawValue }.map { BucketInfo(id: $0, name: "Chat \($0.rawValue)", detail: "", isGroup: false, count: 1) } }
        func messages(in bucket: BucketID, from: Date, to: Date) async throws -> [ChatMessage] {
            lock.withLock { reads[bucket] = from }
            return (msgs[bucket] ?? []).filter { $0.date >= from && $0.date <= to }
        }
    }

    @Test func eachChatIsReadBackOnlyAsFarAsItsOwnAsks() async throws {
        let day = 86400.0, a = BucketID("fake:a"), b = BucketID("fake:b")
        let src = TwoChats([a: [m(1, "can you send the estimates?", mins: -40 * 1440), m(2, "sent", me: true, mins: -10)], b: [m(3, "beer tonight?", mins: -60)]])
        let scan = AskScan(since: t0.addingTimeInterval(-3 * day), sinceByBucket: [a: t0.addingTimeInterval(-40 * day - 3600)])
        let asks = try await src.scanAsks(enabled: [a, b], scan: scan, now: t0)
        #expect(src.readFrom == [a: t0.addingTimeInterval(-40 * day - 3600), b: t0.addingTimeInterval(-3 * day)], "the chat with the old ask is read back to it; the other stays at three days")
        #expect(asks.count == 2 && asks.first { $0.bucket == a }?.isAnswered == true && asks.first { $0.bucket == b }?.isOpen == true)
    }
}
