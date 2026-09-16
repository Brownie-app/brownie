import Testing
import Foundation
@testable import Proactive
import Domain

/// A reply counts only when it is about the question.
@Suite struct AskAnsweringTests {
    @Test func sharedWordsMeanAnswered() {
        #expect(AskAnswering.quick(question: "Dude postgres ka url kaise milega ye bata do", reply: "Hi Nitesh, I'm still checking how to obtain the PostgreSQL URL needed for the first test.") == true)
        #expect(AskAnswering.quick(question: "Can you send the estimates for the three tasks?", reply: "I haven't finalized the estimates for the three tasks yet, will share once ready") == true)
    }
    @Test func acknowledgementsAreAnswers() {
        for r in ["ok", "Done.", "sure", "haan", "ho gaya", "👍"] { #expect(AskAnswering.quick(question: "can you send the file?", reply: r) == true, Comment(rawValue: r)) }
    }
    @Test func aRealMessageAboutSomethingElseIsNot() {
        #expect(AskAnswering.quick(question: "Brownie would you like to have a beer", reply: "Hi Nitesh, I'm still checking how to obtain the PostgreSQL URL needed for the first test. I'll share the exact steps once confirmed.") == false)
        #expect(AskAnswering.quick(question: "can you list down all the tasks that you have in pipeline", reply: "Also I think the approach wont work as their network is secure, I will implement the feature you sent") == false)
    }
    @Test func anAnswerAmongSeveralMessagesIsStillAnAnswer() {
        // the detector hands the judge the user's last few messages at once, newest last: the answer at the end is found, and six unrelated ones are a no
        let chatter = ["ha", "see you at the ground", "traffic is mad today", "did you watch the match", "lunch at 1", "running late"]
        #expect(AskAnswering.quick(question: "can you send the estimates?", reply: (chatter.dropFirst() + ["here are the estimates, sorry for the wait"]).joined(separator: "\n")) == true)
        #expect(AskAnswering.quick(question: "can you send the estimates?", reply: chatter.joined(separator: "\n")) == false)
        #expect(AskLedger.scan(existing: [Ask(id: "a", person: "N", bucket: BucketID("w:1"), askedAt: Date(timeIntervalSince1970: 1_758_000_000), question: "q?", answeredAt: Date(timeIntervalSince1970: 1_758_003_600), reply: "ha\nlunch at 1", addressed: false)], now: Date(timeIntervalSince1970: 1_758_010_000)).judgedReplies == ["a": Date(timeIntervalSince1970: 1_758_003_600)], "the newest of them is the reply the next scan moves past")
    }

    @Test func shortUnrelatedRepliesAreLeftToTheReader() {
        #expect(AskAnswering.quick(question: "beer tonight?", reply: "let's see") == nil)
        #expect(AskAnswering.quick(question: "???", reply: "hmm") == nil)
    }

    struct YesNoReader: LocalModel {
        let answer: String
        var isLoaded: Bool { true }
        func load() async throws {}
        func generate(_ r: GenerateRequest) async throws -> GenerateResult { GenerateResult(text: answer, duration: 0) }
        func reload() async throws {}
        func unload() async {}
    }
    @Test func theReaderDecidesWhatTheRulesCannot() async {
        let now = Date()
        let unsure = Ask(id: "a", person: "N", bucket: BucketID("w:1"), askedAt: now, question: "beer tonight?", answeredAt: now, reply: "let's see")
        let clear = Ask(id: "b", person: "N", bucket: BucketID("w:1"), askedAt: now, question: "send the deck?", answeredAt: now, reply: "done")
        let open = Ask(id: "c", person: "N", bucket: BucketID("w:1"), askedAt: now, question: "x?")
        let judged = await AskAnswering.judge([unsure, clear, open], reader: YesNoReader(answer: "No"))
        #expect(judged[0].addressed == false && judged[1].addressed == true && judged[2].addressed == nil)
        #expect(judged[0].isOpen && !judged[0].isAnswered && judged[1].isAnswered)
        let none = await AskAnswering.judge([unsure], reader: nil)
        #expect(none[0].addressed == nil && none[0].isAnswered, "unjudged replies are given the benefit of the doubt in the note, but stay eligible for judging later")
    }
    @Test func mergeKeepsAJudgementForTheSameReply() {
        let now = Date()
        var old = Ask(id: "a", person: "N", bucket: BucketID("w:1"), askedAt: now, question: "q?", answeredAt: now, reply: "r"); old.addressed = false
        let rescanned = Ask(id: "a", person: "N", bucket: BucketID("w:1"), askedAt: now, question: "q?", answeredAt: now, reply: "r")
        #expect(AskLedger.merge(existing: [old], found: [rescanned], now: now)[0].addressed == false)
        let laterReply = Ask(id: "a", person: "N", bucket: BucketID("w:1"), askedAt: now, question: "q?", answeredAt: now.addingTimeInterval(60), reply: "r2")
        #expect(AskLedger.merge(existing: [old], found: [laterReply], now: now)[0].addressed == nil, "a different reply is judged afresh")
    }
    @Test func theBlockSaysWhenYouWroteButNotAboutIt() {
        let now = Date(timeIntervalSince1970: 1_758_000_000)
        var a = Ask(id: "a", person: "Nitesh", bucket: BucketID("w:1"), askedAt: now.addingTimeInterval(-600), question: "beer?", answeredAt: now.addingTimeInterval(-300), reply: "about postgres"); a.addressed = false
        let b = StatusBlock.render(person: "Nitesh", asks: [a], loops: [], now: now)
        #expect(b.contains("⏳") && b.contains("but not about this; still open"))
        #expect(AskLedger.judgeLines([a], now: now).contains("but NOT about it — still unanswered"))
        #expect(AskLedger.closures(loops: [Loop(id: "L", direction: .mine, person: "Nitesh", what: "answer Nitesh", quote: "", sourceLabel: "s", due: nil, openedAt: now.addingTimeInterval(-500))], asks: [a], now: now)[0].status == .open, "an off-topic reply closes nothing")
    }
}
