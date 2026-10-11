import Testing
import Foundation
import Domain
import LocalSources
import Proactive

/// Scenarios 1–8: one question, one chat, and the days it takes to settle — the shape most of Brownie's
/// work has. Every expectation is written out in words before its assertions, so a wrong expectation is
/// as visible to a reader as a wrong answer.
@Suite struct AskScenarios {

    // 1 ────────────────────────────────────────────────────────────────────────────────────────────

    /// EXPECTED: Meera asks on Monday and the user says nothing, so Monday night the ask is open and a card
    /// asks the user to reply. The user answers on Tuesday, so Tuesday night the ask is answered and no card
    /// is made — the thing the card existed for has happened.
    @Test func askedTodayAnsweredTomorrow() async {
        let w = World([.direct("whatsapp:11", "Meera Joshi", handle: "whatsapp:+919810011001")])
        // What the brain wrote about her before tonight: one bullet that is still news, one from July that is not.
        w.write(note: "Meera Joshi", """
        # Meera Joshi

        ## About
        - Architect on the Bandra flat

        ## Now
        - Waiting on the revised floor plan from the contractor (2026-09-06)
        - Took over the Bandra flat from Rahul (2026-07-09)

        ## Context

        ## Earlier
        """)
        w.say("whatsapp:11", "hey, can you send me the revised floor plan?", day: 1, at: 11)
        let n1 = await w.night(1, judge: JudgeScript(cards: [.proposed("Send Meera the revised floor plan", to: "Meera Joshi",
                                                                      why: "She asked yesterday and you have not replied")]))
        #expect(n1.openAsks.count == 1, n1.summary)
        #expect(n1.ask(from: "Meera Joshi")?.isAnswered == false, n1.summary)
        #expect(n1.cardTitles == ["Send Meera the revised floor plan"], n1.summary)
        #expect(n1.lines("Meera Joshi").contains { $0.contains("⏳") && $0.contains("no reply yet") }, "\(n1.lines("Meera Joshi"))")
        // The note keeps its shape around the block: the bullet that is still news stays under Now, the one from
        // July is two months old and has gone down to Earlier as a clause on its month's line.
        #expect(n1.nowBullets["Meera Joshi"] == ["- Waiting on the revised floor plan from the contractor (2026-09-06)"],
                "\(n1.nowBullets["Meera Joshi"] ?? [])")
        let note = w.notes["Meera Joshi"] ?? ""
        #expect(note.contains("- 2026-07 — Took over the Bandra flat from Rahul"), "\(note)")
        #expect(note.hasPrefix("# Meera Joshi\n\n<!-- brownie:status -->"), "the block sits right under the title\n\(note)")

        w.say("whatsapp:11", "sending the revised floor plan now, the balcony is 20cm wider", mine: true, day: 2, at: 9)
        let n2 = await w.night(2)
        #expect(n2.ask(from: "Meera Joshi")?.outcome == .answered, n2.summary)
        #expect(n2.openAsks.isEmpty, n2.summary)
        #expect(n2.cards.isEmpty, n2.summary)
        #expect(n2.lines("Meera Joshi").contains { $0.contains("✅") && $0.contains("you replied") }, "\(n2.lines("Meera Joshi"))")
    }

    // 2 ────────────────────────────────────────────────────────────────────────────────────────────

    /// EXPECTED: nothing is said on Monday, so Monday night has no ask and no card at all. Sandeep asks on
    /// Tuesday, so Tuesday night has one open ask and one card.
    @Test func nothingTodayAskedTomorrow() async {
        let w = World([.direct("imessage:22", "Sandeep Rao", handle: "imessage:+919810022002")])
        let n1 = await w.night(1)
        #expect(n1.asks.isEmpty && n1.cards.isEmpty && n1.loops.isEmpty, n1.summary)
        #expect(n1.lines("Sandeep Rao").isEmpty, "a person with nothing between you gets no block")

        w.say("imessage:22", "could you share the insurance papers for the flat before Thursday", day: 2, at: 18)
        let n2 = await w.night(2, judge: JudgeScript(cards: [.proposed("Share the insurance papers with Sandeep", to: "Sandeep Rao", on: .imessage,
                                                                      why: "He asked yesterday evening")]))
        #expect(n2.openAsks.count == 1, n2.summary)
        #expect(n2.ask(from: "Sandeep Rao")?.isAnswered == false, n2.summary)
        #expect(n2.cardTitles == ["Share the insurance papers with Sandeep"], n2.summary)
    }

    // 3 ────────────────────────────────────────────────────────────────────────────────────────────

    /// EXPECTED: Farah asks about the Baroda quotation on Monday, three days of unrelated chat follow on both
    /// sides, and the answer comes on Thursday. The ask stays open through the noise — sympathy about a
    /// cancelled train is not an answer to a question about a quotation — closes on Thursday, and no second
    /// ask is invented out of the small talk.
    ///
    /// WHAT HAPPENS: on Tuesday the user's "oh no" (about her cancelled train) is read as a refusal of the
    /// quotation question. `AskAnswering.mine` strips "oh" as a softener, sees a bare "no", and returns
    /// `.declined` — which is a closed verdict, so the question is settled and never looked at again. The real
    /// answer on Thursday is never paired with it.
    @Test(.disabled("half-fixed: \"oh no\" no longer reads as declined, but a reply the rules cannot read still closes the ask by benefit of the doubt, so day 3 needs the reader the harness does not run"))
    func answeredThreeDaysLaterAfterUnrelatedChat() async {
        let w = World([.direct("whatsapp:33", "Farah Siddiqui", handle: "whatsapp:+919810033003")])
        w.say("whatsapp:33", "what's the final number on the Baroda quotation?", day: 1, at: 10)
        let n1 = await w.night(1)
        #expect(n1.openAsks.count == 1, n1.summary)

        w.say("whatsapp:33", "my train got cancelled, what a morning", day: 2, at: 8)
        w.say("whatsapp:33", "oh no", mine: true, day: 2, at: 9)
        w.say("whatsapp:33", "rebooked for tonight", day: 2, at: 12)
        let n2 = await w.night(2)
        #expect(n2.openAsks.count == 1, "small talk is not an answer — \(n2.line)")
        #expect(n2.asks.count == 1, "and it is not a new question either — \(n2.line)")

        w.say("whatsapp:33", "reached, finally", day: 3, at: 7)
        w.say("whatsapp:33", "good, get some sleep", mine: true, day: 3, at: 8)
        let n3 = await w.night(3)
        #expect(n3.openAsks.count == 1, n3.summary)

        w.say("whatsapp:33", "the Baroda quotation comes to 14.2 lakh including the freight", mine: true, day: 4, at: 11)
        let n4 = await w.night(4)
        #expect(n4.ask(from: "Farah Siddiqui")?.outcome == .answered, n4.summary)
        #expect(n4.asks.count == 1, "one question the whole week, not four — \(n4.line)")
        #expect(n4.openAsks.isEmpty, n4.summary)
    }

    // 4 ────────────────────────────────────────────────────────────────────────────────────────────

    /// EXPECTED: "checking now, give me an hour" is a promise, not an answer — Monday night the ask reads
    /// `promised` and stays open, and the note says "you said you would". The real answer comes on Tuesday, and
    /// Tuesday night the ask is answered, the promise replaced by what actually happened.
    @Test func checkingNowThenTheRealAnswer() async {
        let w = World([.direct("whatsapp:44", "Nitesh Kumar", handle: "whatsapp:+919810044004")])
        w.say("whatsapp:44", "is the staging database back up?", day: 1, at: 15)
        w.say("whatsapp:44", "checking now, give me an hour", mine: true, day: 1, at: 15.2)
        let n1 = await w.night(1)
        #expect(n1.ask(from: "Nitesh Kumar")?.outcome == .promised, "“checking now, give me an hour” is a promise — \(n1.line)")
        #expect(n1.openAsks.count == 1, "a promise leaves the question open — \(n1.line)")
        #expect(n1.lines("Nitesh Kumar").contains { $0.contains("⏳") && $0.contains("you said you would") }, "\(n1.lines("Nitesh Kumar"))")

        w.say("whatsapp:44", "staging is back up, the replica had run out of disk", mine: true, day: 2, at: 9)
        let n2 = await w.night(2)
        #expect(n2.ask(from: "Nitesh Kumar")?.outcome == .answered, "the answer replaces the promise — \(n2.line)")
        #expect(n2.openAsks.isEmpty, n2.summary)
    }

    // 5 ────────────────────────────────────────────────────────────────────────────────────────────

    /// EXPECTED: the user does the thing without saying so, and Priya writes "thanks, got it". The ask closes
    /// credited to her — `confirmedByThem`, the strongest word there is — the note says she said it's done, and
    /// no card is made to do what is already done.
    @Test func theyConfirmItThemselves() async {
        let w = World([.direct("whatsapp:55", "Priya Nair", handle: "whatsapp:+919810055005")])
        w.say("whatsapp:55", "can you add me to the Drive folder with the shoot photos?", day: 1, at: 13)
        let n1 = await w.night(1)
        #expect(n1.openAsks.count == 1, n1.summary)

        w.say("whatsapp:55", "thanks, got it", day: 2, at: 10)
        let n2 = await w.night(2)
        #expect(n2.ask(from: "Priya Nair")?.outcome == .confirmedByThem, "she closed it herself — \(n2.line)")
        #expect(n2.openAsks.isEmpty && n2.cards.isEmpty, n2.summary)
        #expect(n2.lines("Priya Nair").contains { $0.contains("✅") && $0.contains("they said it's done") }, "\(n2.lines("Priya Nair"))")
    }

    // 6 ────────────────────────────────────────────────────────────────────────────────────────────

    /// EXPECTED: "sorry, can't this week" closes the ask as declined. The note says you said no, no card is made,
    /// and the days that follow bring no nagging — a no is an answer.
    ///
    /// WHAT HAPPENS: `AskAnswering.mine` tests the "later" words before the refusals, and "this week" is a later.
    /// So a refusal that names a week reads as a promise to do it that week: the ask stays open, the note says
    /// "you said you would", and Brownie goes on waiting for a thing the user has already said no to.
    @Test
    func theUserDeclines() async {
        let w = World([.direct("whatsapp:66", "Rohan Bakshi", handle: "whatsapp:+919810066006")])
        w.say("whatsapp:66", "can you cover the Thursday session for me?", day: 1, at: 17)
        w.say("whatsapp:66", "sorry, can't this week", mine: true, day: 1, at: 19)
        let n1 = await w.night(1)
        #expect(n1.ask(from: "Rohan Bakshi")?.outcome == .declined, n1.summary)
        #expect(n1.openAsks.isEmpty && n1.cards.isEmpty, n1.summary)
        #expect(n1.lines("Rohan Bakshi").contains { $0.contains("✅") && $0.contains("you said no") }, "\(n1.lines("Rohan Bakshi"))")

        let n2 = await w.night(2)
        #expect(n2.openAsks.isEmpty && n2.cards.isEmpty, "a no stays a no — \(n2.line)")
        let n3 = await w.night(3)
        #expect(n3.openAsks.isEmpty && n3.cards.isEmpty, "and three days later it is still a no — \(n3.line)")
    }

    /// The same refusal without a week in it, to show where the line actually falls. This one is right, and it
    /// is what makes the scenario above a rule-order bug rather than a missing rule.
    @Test func aPlainRefusalIsRead() async {
        let w = World([.direct("whatsapp:661", "Rohan Bakshi", handle: "whatsapp:+919810066006")])
        w.say("whatsapp:661", "can you cover the Thursday session for me?", day: 1, at: 17)
        w.say("whatsapp:661", "sorry, can't", mine: true, day: 1, at: 19)
        let n1 = await w.night(1)
        #expect(n1.ask(from: "Rohan Bakshi")?.outcome == .declined, n1.summary)
        #expect(n1.openAsks.isEmpty && n1.cards.isEmpty, n1.summary)
    }

    // 7 ────────────────────────────────────────────────────────────────────────────────────────────

    /// EXPECTED: the user dismisses a card on Tuesday morning. Nothing is said afterwards, and on Tuesday night
    /// the judge proposes the very same thing again. It does not reach the morning: a card the user has already
    /// turned down is not offered again while nothing has changed.
    ///
    /// WHAT HAPPENS: it comes back, both as a bare card and as a card about a loop. `QuietCheck.run` looks at
    /// what the user *fired* and never at what they dismissed, and the preparer stamps every card with a fresh
    /// UUID, so nothing ties tonight's card to the one turned down last night. This is the repeat the founder
    /// is seeing.
    @Test
    func aDismissedCardDoesNotComeBack() async {
        let w = World([.direct("whatsapp:77", "Aditya Menon", handle: "whatsapp:+919810077007")])
        w.say("whatsapp:77", "can you introduce me to the Tata team?", day: 1, at: 12)
        let bare = "Introduce Aditya to the Tata team", loopy = "Send Aditya the Tata contact"
        let loop = Loop.proposed("Send Aditya the Tata contact", .mine, with: "Aditya Menon", openedAt: w.at(1, 12), id: "L-tata")
        let n1 = await w.night(1, judge: JudgeScript(cards: [.proposed(bare, to: "Aditya Menon", why: "He asked on Monday"),
                                                             .proposed(loopy, to: "Aditya Menon", why: "You said you would", loop: "L-tata")],
                                                     loops: [loop]))
        #expect(Set(n1.cardTitles) == [bare, loopy], n1.summary)

        // Tuesday morning both are dismissed; nothing is said all day; the judge proposes both again that night.
        let n2 = await w.night(2, judge: JudgeScript(cards: [.proposed(bare, to: "Aditya Menon", why: "He asked on Monday and you have not replied"),
                                                             .proposed(loopy, to: "Aditya Menon", why: "You said you would", loop: "L-tata")]),
                               did: [.dismissed(card: bare), .dismissed(card: loopy)])
        #expect(n2.cards.isEmpty, "you already said no to both of these — \(n2.line)")
        #expect(n2.droppedCards.count == 2, "and the quiet check should say why — \(n2.line)")
    }

    // 8 ────────────────────────────────────────────────────────────────────────────────────────────

    /// EXPECTED: the user marks a card done on Tuesday morning — the app fires it. On Tuesday night the judge
    /// proposes the same thing again, and it does not reach the morning: what you have already done is not
    /// asked of you twice.
    ///
    /// WHAT HAPPENS: a card that carries a loop id is caught, because the quiet check remembers a fired card
    /// per loop. A card with no loop behind it — which is what a card born of an ask is — comes straight back:
    /// nothing remembers that this exact thing was done nineteen hours ago.
    @Test
    func aCardMarkedDoneDoesNotComeBack() async {
        let w = World([.direct("whatsapp:88", "Kabir Shah", handle: "whatsapp:+919810088008")])
        w.say("whatsapp:88", "please send the signed NDA when you get a minute", day: 1, at: 10)
        w.say("whatsapp:88", "and can we do the demo Thursday?", day: 1, at: 10.1)
        let bare = "Send Kabir the signed NDA", loopy = "Book the Thursday demo slot"
        let loop = Loop.proposed("Book the Thursday demo slot", .mine, with: "Kabir Shah", openedAt: w.at(1, 10.1), id: "L-demo")
        let n1 = await w.night(1, judge: JudgeScript(cards: [.proposed(bare, to: "Kabir Shah", why: "He asked for the NDA on Monday"),
                                                             .proposed(loopy, to: "Kabir Shah", why: "You agreed to a Thursday demo", loop: "L-demo")],
                                                     loops: [loop]))
        #expect(Set(n1.cardTitles) == [bare, loopy], n1.summary)

        let n2 = await w.night(2, judge: JudgeScript(cards: [.proposed(bare, to: "Kabir Shah", why: "He asked for the NDA on Monday"),
                                                             .proposed(loopy, to: "Kabir Shah", why: "You agreed to a Thursday demo", loop: "L-demo")]),
                               did: [.markedDone(card: bare), .markedDone(card: loopy)])
        #expect(n2.droppedCards.contains { $0.title == loopy }, "the one with a loop is caught — \(n2.line)")
        #expect(n2.cards.isEmpty, "and so should the one without be — \(n2.line)")
    }
}
