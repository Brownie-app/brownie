import Testing
import Foundation
@testable import Proactive
import Domain

/// Where an ask stands is read from the exchange after it — both sides — and a verdict, not a yes or no.
@Suite struct AskAnsweringTests {
    let t0 = Date(timeIntervalSince1970: 1_758_000_000)
    func you(_ s: String, mins: Double = 10) -> AskLine { AskLine(at: t0.addingTimeInterval(mins * 60), mine: true, text: s) }
    func them(_ s: String, mins: Double = 20) -> AskLine { AskLine(at: t0.addingTimeInterval(mins * 60), mine: false, text: s) }
    func verdict(_ q: String, _ w: [AskLine]) -> AskOutcome? { AskAnswering.rules(question: q, window: w)?.outcome }

    @Test func sharedWordsMeanAnswered() {
        #expect(verdict("Dude postgres ka url kaise milega ye bata do", [you("Hi Nitesh, I'm still checking how to obtain the PostgreSQL URL needed for the first test.")]) == .answered)
        #expect(verdict("Can you send the estimates for the three tasks?", [you("here are the estimates for the three tasks")]) == .answered)
    }
    @Test func acknowledgementsAreAnswers() {
        for r in ["ok", "Done.", "sure", "haan", "ho gaya", "👍", "ok done", "sent"] { #expect(verdict("can you send the file?", [you(r)]) == .answered, Comment(rawValue: r)) }
    }
    @Test func aRealMessageAboutSomethingElseLeavesItOpen() {
        #expect(verdict("Brownie would you like to have a beer", [you("Hi Nitesh, I'm still checking how to obtain the PostgreSQL URL needed for the first test. I'll share the exact steps once confirmed.")]) == .promised, "a promise in it is read as one, whatever it is about")
        #expect(verdict("can you list down all the tasks that you have in pipeline", [you("Also I think the approach wont work as their network is secure, so the feature you sent is out")]) == .open)
        #expect(verdict("beer tonight?", []) == nil, "nothing after it: nothing to judge")
        #expect(verdict("beer tonight?", [them("hello?")]) == .open, "nothing from the user and no receipt: open, no reader needed")
    }
    @Test func theirReceiptOrThanksCloses() {
        for r in ["thanks", "thank you", "got it", "received", "works now", "done", "perfect", "great", "mil gaya", "ho gaya", "thik hai", "shukriya", "ok done", "sorted", "resolved", "thanks, works now", "Thanks a lot bhai!"] {
            #expect(verdict("can you send the url?", [you("https://db.example.internal/5432"), them(r)]) == .confirmedByThem, Comment(rawValue: r))
        }
        #expect(verdict("can you send the url?", [you("let me see"), them("thanks, works now")]) == .confirmedByThem, "Nitesh: thanks, works now — the strongest word there is")
        #expect(verdict("did you get my file?", [them("oh got it, found it in spam")]) == .confirmedByThem, "a receipt needs no line from the user: they found it themselves")
        #expect(verdict("can you send the url?", [them("thanks")]) == .open, "thanks with nothing from the user is politeness, not a receipt")
        #expect(verdict("can you send the url?", [you("will do tomorrow"), them("thanks!")]) == .promised, "thanks for a promise close nothing")
        #expect(verdict("can you send the url?", [you("no, can't share that"), them("ok thik hai")]) == .declined, "and neither do thanks for a no")
        #expect(verdict("can you send the url?", [you("sure"), them("not received yet")]) == .answered, "a receipt turned around is no receipt")
        #expect(verdict("can you send the url?", [you("sure"), them("let me know when done")]) == .answered, "nor a wait")
        #expect(verdict("can you send the url?", [you("hmm"), them("thanks, and the other one?")]) == nil, "a question of theirs is a new ask, and 'hmm' is for the reader")
    }
    @Test func theUserSayingLaterIsAPromise() {
        for r in ["will do", "tomorrow", "kal bhejta hu", "later", "give me an hour", "by evening", "next week", "I'll send it tonight", "ok, will share by eod"] {
            #expect(verdict("can you send the deck?", [you(r)]) == .promised, Comment(rawValue: r))
        }
        #expect(verdict("can you send the deck?", [you("will do tomorrow"), you("sent", mins: 1500)]) == .answered, "kept: the ask closes")
        #expect(verdict("can you send the deck?", [you("sent"), you("will send the rest tomorrow", mins: 11)]) == .answered, "a promise after an answer does not reopen it")
        #expect(verdict("can you send the deck?", [you("can't today"), you("will do tomorrow", mins: 11)]) == .promised, "a no followed by a later is a later")
        #expect(verdict("kalam ka number hai?", [you("kalam se pooch lo")]) == .answered, "'kal' inside a word is not 'kal'")
    }
    @Test func theUserRefusingDeclines() {
        for r in ["no", "nope", "can't", "sorry, can't", "not possible", "nahi ho payega", "No way, that's confidential", "unable to share this"] {
            #expect(verdict("can you send the deck?", [you(r)]) == .declined, Comment(rawValue: r))
        }
        #expect(verdict("can you send the deck?", [you("no problem, sending now")]) == .answered, "a 'no' that refuses nothing")
        #expect(verdict("can you send the deck?", [you("no idea, will check")]) == .promised)
    }
    @Test func anAnswerAmongUnrelatedMessagesIsStillAnAnswer() {
        let chatter = ["see you at the ground", "traffic is mad today", "did you watch the match", "lunch at 1", "running late"]
        let w = chatter.enumerated().map { you($0.element, mins: Double($0.offset)) }
        #expect(verdict("can you send the estimates?", w + [you("sorted", mins: 30)]) == .answered, "unrelated first, then 'sorted'")
        #expect(verdict("can you send the estimates?", w + [you("here are the estimates, sorry for the wait", mins: 30)]) == .answered)
        #expect(verdict("can you send the estimates?", w) == .open, "five messages that together share nothing with the question: open, by the rules")
        #expect(verdict("can you send the estimates?", [you("let's see")]) == nil && verdict("???", [you("hmm")]) == nil, "too little to tell is left to the reader")
        #expect(AskAnswering.rules(question: "can you send the estimates?", window: w + [you("sorted", mins: 30)])?.at == t0.addingTimeInterval(1800), "dated by the line that decided it")
    }

    struct OneWordReader: LocalModel {
        let answer: String
        let seen: Seen
        final class Seen: @unchecked Sendable { var prompts: [String] = [] }
        var isLoaded: Bool { true }
        func load() async throws {}
        func generate(_ r: GenerateRequest) async throws -> GenerateResult { seen.prompts.append(r.prompt); return GenerateResult(text: answer, duration: 0) }
        func reload() async throws {}
        func unload() async {}
    }
    func ask(_ id: String, q: String, window: [AskLine]) -> Ask {
        Ask(id: id, person: "Nitesh", bucket: BucketID("w:1"), askedAt: t0, question: q, answeredAt: window.first(where: \.mine)?.at, reply: window.first(where: \.mine)?.text, window: window)
    }
    @Test func theReaderSeesTheExchangeAndAnswersOneWord() async {
        let seen = OneWordReader.Seen()
        let unsure = ask("a", q: "beer tonight?", window: [you("let's see"), them("cmon"), you("hmm", mins: 30)])
        let clear = ask("b", q: "send the deck?", window: [you("done")])
        let open = ask("c", q: "x?", window: [])
        let judged = await AskAnswering.judge([unsure, clear, open], reader: OneWordReader(answer: "Promised.", seen: seen))
        #expect(judged[0].outcome == .promised && judged[0].addressed == true && judged[0].isOpen && judged[0].outcomeBy == "reader" && judged[0].outcomeAt == t0.addingTimeInterval(1800), "the reader's word, dated by the user's newest line")
        #expect(judged[1].outcome == .answered && judged[1].outcomeBy == "rules" && judged[1].isAnswered)
        #expect(judged[2].outcome == nil && judged[2].addressed == nil)
        #expect(seen.prompts.count == 1, "the reader is asked only what the rules cannot tell")
        let p = seen.prompts[0]
        #expect(p.contains("Them (the question): \"beer tonight?\"") && p.contains("\nYou: let's see\nThem: cmon\nYou: hmm\n"), "the exchange as a small transcript, both sides")
        #expect(p.contains("answered, confirmed, declined, promised or open") && p.hasSuffix("One word (answered, confirmed, declined, promised or open):"))
        let none = await AskAnswering.judge([unsure], reader: nil)
        #expect(none[0].outcome == nil && none[0].isAnswered, "unjudged replies are given the benefit of the doubt in the note, but stay eligible for judging later")
    }
    @Test func theReadersWordIsReadLeniently() {
        #expect(AskAnswering.parse("answered") == .answered && AskAnswering.parse("Confirmed.") == .confirmedByThem && AskAnswering.parse("declined\n") == .declined)
        #expect(AskAnswering.parse("**promised**") == .promised && AskAnswering.parse("open — nothing settles it") == .open)
        #expect(AskAnswering.parse("Yes") == .answered && AskAnswering.parse("no") == .open, "an older prompt's words still count")
        #expect(AskAnswering.parse("I cannot tell") == nil)
    }
    @Test func theReaderDatesAConfirmationByTheirLine() async {
        let a = ask("a", q: "beer tonight?", window: [you("hmm"), them("cool, see you", mins: 40)])
        let judged = await AskAnswering.judge([a], reader: OneWordReader(answer: "confirmed", seen: .init()))
        #expect(judged[0].outcome == .confirmedByThem && judged[0].outcomeAt == t0.addingTimeInterval(2400) && judged[0].isAnswered)
    }
    @Test func anAskFromBeforeThereWereWindowsIsJudgedFromItsReply() async {
        var old = Ask(id: "a", person: "N", bucket: BucketID("w:1"), askedAt: t0, question: "can you send the estimates?", answeredAt: t0.addingTimeInterval(600), reply: "lol\nhere are the estimates")
        #expect(old.window == nil && old.legacyWindow.count == 2 && old.legacyWindow.allSatisfy(\.mine))
        let judged = await AskAnswering.judge([old], reader: nil)
        #expect(judged[0].outcome == .answered && judged[0].addressed == true)
        old.addressed = true
        #expect(await AskAnswering.judge([old], reader: nil)[0].outcome == nil, "one already judged addressed before there were verdicts is settled, and left alone")
        old.addressed = false; old.lapsedAt = t0.addingTimeInterval(50 * 86400)
        #expect(await AskAnswering.judge([old], reader: nil)[0].outcome == nil, "and one let go is not read again")
    }

    @Test func aSettledAskIsNeverReopenedByALaterRead() {
        let closed = ["answered", "confirmedByThem", "declined"].map { o -> Ask in var a = ask("a-\(o)", q: "send the deck?", window: [you("sent")]); a.settle(AskOutcome(rawValue: o)!, at: t0.addingTimeInterval(600), by: "rules"); return a }
        // the next read brings a longer window in which the user, taken at face value, says no — and a different first reply
        let rescanned = closed.map { a -> Ask in var f = ask(a.id, q: "send the deck?", window: [you("sent"), them("wrong file", mins: 20), you("no", mins: 30)]); f.answeredAt = t0.addingTimeInterval(1800); f.reply = "no"; return f }
        let merged = AskLedger.merge(existing: closed, found: rescanned, now: t0.addingTimeInterval(86400))
        for m in merged {
            let was = closed.first { $0.id == m.id }!
            #expect(m.outcome == was.outcome && m.outcomeAt == was.outcomeAt && m.addressed == true && m.isAnswered && !m.isOpen, Comment(rawValue: m.id))
            #expect(m.answeredAt == was.answeredAt && m.reply == was.reply, "the reply the verdict rests on is kept")
            #expect(m.window?.count == 3, "but the window is the newest")
        }
        var legacy = Ask(id: "L", person: "Nitesh", bucket: BucketID("w:1"), askedAt: t0, question: "q?", answeredAt: t0.addingTimeInterval(60), reply: "r"); legacy.addressed = true
        let again = AskLedger.merge(existing: [legacy], found: [ask("L", q: "q?", window: [you("r"), you("something else", mins: 50)])], now: t0.addingTimeInterval(86400))[0]
        #expect(again.addressed == true && again.outcome == nil && again.isAnswered && again.window?.count == 2, "settled before there were verdicts: settled still")
    }
    @Test func anOpenAskIsJudgedAgainOnlyWhenThereIsMoreToRead() async {
        var promised = ask("p", q: "send the deck?", window: [you("will do tomorrow")]); promised.settle(.promised, at: t0.addingTimeInterval(600), by: "reader")
        let same = AskLedger.merge(existing: [promised], found: [ask("p", q: "send the deck?", window: [you("will do tomorrow")])], now: t0.addingTimeInterval(3600))[0]
        #expect(same.outcome == .promised && same.outcomeBy == "reader" && same.isOpen, "the same exchange: the reader's verdict stands, not asked again")
        let more = AskLedger.merge(existing: [promised], found: [ask("p", q: "send the deck?", window: [you("will do tomorrow"), you("sent", mins: 1500)])], now: t0.addingTimeInterval(3600))[0]
        #expect(more.outcome == nil && more.addressed == nil, "a longer window is judged afresh")
        let judged = await AskAnswering.judge([more], reader: nil)[0]
        #expect(judged.outcome == .answered && judged.isAnswered && judged.outcomeAt == t0.addingTimeInterval(1500 * 60))
        var off = ask("o", q: "q?", window: [you("lol")]); off.settle(.open, at: t0.addingTimeInterval(600), by: "reader")
        #expect(AskLedger.scan(existing: [off], now: t0.addingTimeInterval(3600)).judgedReplies == ["o": off.answeredAt!], "a reply judged off-topic is the one the next scan moves past")
        #expect(AskLedger.scan(existing: [promised], now: t0.addingTimeInterval(3600)).judgedReplies.isEmpty, "a promise is about the question")
    }
    @Test func theBlockSaysWhenYouWroteButNotAboutIt() {
        let now = Date(timeIntervalSince1970: 1_758_000_000)
        var a = Ask(id: "a", person: "Nitesh", bucket: BucketID("w:1"), askedAt: now.addingTimeInterval(-600), question: "beer?", answeredAt: now.addingTimeInterval(-300), reply: "about postgres"); a.addressed = false
        let b = StatusBlock.render(person: "Nitesh", asks: [a], loops: [], now: now)
        #expect(b.contains("⏳") && b.contains("but not about this; still open"))
        #expect(AskLedger.judgeLines([a], now: now).contains("but NOT about it — still unanswered"))
        #expect(AskLedger.closures(loops: [Loop(id: "L", direction: .mine, person: "Nitesh", what: "answer Nitesh", quote: "", sourceLabel: "s", due: nil, openedAt: now.addingTimeInterval(-500))], asks: [a], now: now)[0].status == .open, "an off-topic reply closes nothing")
    }
    @Test func oldLedgersDecodeAndBehaveAsBefore() throws {
        let json = #"[{"id":"a","person":"Nitesh","bucket":{"rawValue":"whatsapp:1"},"askedAt":1758000000,"question":"beer?","answeredAt":1758000600,"reply":"sure","addressed":true},{"id":"b","person":"Nitesh","bucket":{"rawValue":"whatsapp:1"},"askedAt":1758000000,"question":"x?"}]"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        let asks = try d.decode([Ask].self, from: Data(json.utf8))
        #expect(asks[0].window == nil && asks[0].outcome == nil && asks[0].isAnswered && asks[0].isSettled && !asks[0].isOpen)
        #expect(asks[1].isOpen && !asks[1].isSettled && asks[1].window == nil)
        let round = try d.decode([Ask].self, from: try { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return try e.encode(asks) }())
        #expect(round == asks)
    }
}
