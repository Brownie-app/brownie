import Testing
import Foundation
import Domain
import LocalSources
import Proactive

/// Scenarios 9–14: what reaches the morning when two cards mean one thing, what a group chat is worth, and
/// which promises are real enough to be tracked.
@Suite struct CardAndLoopScenarios {

    // 9 ────────────────────────────────────────────────────────────────────────────────────────────

    /// EXPECTED: one commitment routed two ways is one card, and where it is two cards there is a rule a user
    /// could state. The rule: cards fold when they are about the same loop, whatever the channel, and when they
    /// are addressed to the same person about the same thing in other words. Two different people get two cards,
    /// because two people each need telling — that is the rule, not an accident.
    @Test func oneCommitmentRoutedTwoWays() async {
        let w = World([.direct("whatsapp:91", "Meena Joshi", handle: "whatsapp:+919000000709"),
                       .direct("whatsapp:92", "Kiran Rane", handle: "whatsapp:+919000000718")])
        let loop = Loop.proposed("Send the signed lease to the broker", .mine, with: "Meena Joshi", openedAt: w.at(1, 10), id: "L-lease")

        // One loop, two channels, two recipients: the loop id ties them, so it is one card.
        let n1 = await w.night(1, judge: JudgeScript(cards: [.proposed("Tell Meena the lease is signed", to: "Meena Joshi", why: "You promised the signed lease", loop: "L-lease"),
                                                             .proposed("Mail Kiran the signed lease", to: "kiran@example.com", on: .mail, why: "You promised the signed lease", loop: "L-lease")],
                                                     loops: [loop]))
        #expect(n1.cards.count == 1, "one commitment is one card, whatever channel it would go out on — \(n1.line)")
        #expect(n1.foldedCards == 1, n1.summary)

        // The same thing said twice to one person on two channels: no loop, but the words give it away.
        let n2 = await w.night(2, judge: JudgeScript(cards: [.proposed("Send Meena the signed lease", to: "Meena Joshi", why: "She is waiting on the signed lease", draft: "The signed lease is attached."),
                                                             .proposed("Mail Meena the signed lease", to: "Meena Joshi", on: .mail, why: "She is waiting on the signed lease", draft: "The signed lease is attached.")]))
        #expect(n2.cards.count == 1, "one person, one thing, one card — \(n2.line)")

        // Two people about the same thing: two cards, because each of them needs telling.
        let n3 = await w.night(3, judge: JudgeScript(cards: [.proposed("Send Meena the signed lease", to: "Meena Joshi", why: "She is waiting on the signed lease"),
                                                             .proposed("Send Kiran the signed lease", to: "Kiran Rane", why: "He is waiting on the signed lease")]))
        #expect(n3.cards.count == 2, "two people, two messages — \(n3.line)")
    }

    // 10 ───────────────────────────────────────────────────────────────────────────────────────────

    /// EXPECTED: in a group of four, two other people sort out a thing between themselves and nobody turns to
    /// the user. No ask is opened and no card is made — Brownie does not answer for the room.
    @Test func aGroupQuestionThatIsNotForTheUser() async {
        let w = World([.group("whatsapp:101", "Flat 402 — Building Works")])
        w.say("whatsapp:101", from: "Sneha Kulkarni", "Deepak, did the plumber ever come back about the terrace?", day: 1, at: 9)
        w.say("whatsapp:101", from: "Deepak Iyer", "he's coming Thursday, can you be home?", day: 1, at: 9.5)
        w.say("whatsapp:101", from: "Sneha Kulkarni", "yes, I'll be in all day", day: 1, at: 10)
        w.say("whatsapp:101", "👍", mine: true, day: 1, at: 11)
        let n1 = await w.night(1)
        #expect(n1.asks.isEmpty, "the questions were between the two of them — \(n1.line)")
        #expect(n1.cards.isEmpty && n1.loops.isEmpty, n1.summary)
    }

    // 11 ───────────────────────────────────────────────────────────────────────────────────────────

    /// EXPECTED: in the same group, Sneha turns to the user by name — "Ishan, can you send the deck before
    /// the meeting?" — and that is an ask like any other: open, on the ledger, on the note.
    ///
    /// WHAT HAPPENS: nothing. `scanAsks` drops every group before the detector ever sees a line
    /// (`Sources/LocalSources/AskDetector.swift:75`), so a request made to the user by name in a group is
    /// invisible to the ask ledger. The detector itself reads the line correctly — it is never handed it.
    @Test
    func aGroupQuestionAddressedToTheUser() async {
        let w = World([.group("whatsapp:111", "Tideline — Launch")])
        w.say("whatsapp:111", from: "Sneha Kulkarni", "Ishan, can you send the deck before the meeting?", day: 1, at: 9)
        w.say("whatsapp:111", from: "Deepak Iyer", "same question about the pricing sheet", day: 1, at: 9.2)
        let n1 = await w.night(1)
        #expect(AskDetector.isAsk("Ishan, can you send the deck before the meeting?"), "the detector reads the line — it is simply never given it")
        #expect(n1.openAsks.count == 1, "a request to you by name is an ask wherever it was made — \(n1.line)")
    }

    // 12 ───────────────────────────────────────────────────────────────────────────────────────────

    /// EXPECTED: "let's build something big together" is warmth, not a deliverable. The judge files it as a
    /// promise anyway; the bar turns it away with a reason, and the ledger stays empty. A real deliverable
    /// said in the same breath is admitted, so the bar is a filter and not a wall.
    @Test func aPromiseThatIsASentiment() async {
        let w = World([.direct("whatsapp:121", "Ishaan Verma", handle: "whatsapp:+919000000719")])
        w.say("whatsapp:121", "great call today, let's build something big together", day: 1, at: 20)
        w.say("whatsapp:121", "absolutely — sending you the cap table tonight", mine: true, day: 1, at: 20.5)
        let n1 = await w.night(1, judge: JudgeScript(loops: [
            .proposed("Build something big together", .mine, with: "Ishaan Verma", openedAt: w.at(1, 20)),
            .proposed("Focus on her network", .mine, with: "Ishaan Verma", openedAt: w.at(1, 20)),
            .proposed("Send Ishaan the cap table", .mine, with: "Ishaan Verma", openedAt: w.at(1, 20.5), id: "L-cap"),
        ]))
        #expect(n1.openLoops.map(\.what) == ["Send Ishaan the cap table"], "only the deliverable — \(n1.line)")
        #expect(n1.rejectedLoops.count == 2, n1.summary)
        #expect(n1.rejectedLoops.contains { $0.what == "Build something big together" && $0.why.contains("intention") }, "\(n1.rejectedLoops)")
    }

    // 13 ───────────────────────────────────────────────────────────────────────────────────────────

    /// EXPECTED: a due said in words gets the right date — "by Friday" said on Tuesday is that Friday, "next
    /// week" is a week out, a named day in September is that day — and a loop with a date gets its card the
    /// morning before the date, even though nothing new was said.
    @Test func aPromiseWithADueDateInWords() async {
        let w = World([.direct("whatsapp:131", "Lalita Pathak", handle: "whatsapp:+919000000555")])
        // The judge dates a loop against the run's own clock, not the hour the promise was said: night 1 is
        // 3 AM on Wednesday 9 September 2026, and day 1 is the Tuesday before it.
        let tz = w.timeZone, run = w.nightAt(1)
        #expect(DueWords.date("by Friday", now: run, timeZone: tz) == w.at(4, 9), "Friday of the same week, at 9")
        #expect(DueWords.date("next week", now: run, timeZone: tz) == w.at(13, 9), "the Sunday after the coming one")
        #expect(DueWords.date("September 16", now: run, timeZone: tz) == w.at(9, 9), "a named day this month")

        w.say("whatsapp:131", "good call today", day: 1, at: 15)
        w.say("whatsapp:131", "I'll get you the perpetual licensing numbers by Friday", mine: true, day: 1, at: 16)
        let loop = Loop.proposed("Send Lalita the perpetual licensing numbers", .mine, with: "Lalita Pathak",
                                 quote: "by Friday", due: "by Friday", openedAt: w.at(1, 16), id: "L-lic")
        let n1 = await w.night(1, judge: JudgeScript(loops: [loop]))
        #expect(n1.loop("Send Lalita the perpetual licensing numbers")?.dueDate == w.at(4, 9), "the words became a date — \(n1.line)")
        #expect(n1.cards.isEmpty, "nothing is due yet — \(n1.line)")

        let n2 = await w.night(2)   // the morning of Thursday 10 September, the morning before Friday
        #expect(n2.cards.first?.dueLine == "Due tomorrow", "the card comes the morning before — \(n2.line)")
        #expect(n2.cards.map(\.loopID) == ["L-lic"], n2.summary)

        let n3 = await w.night(3)
        #expect(n3.cards.isEmpty, "and it is not sent twice — \(n3.line)")
    }

    /// The same promise, said as a reply to the question that prompted it. EXPECTED: the loop is open until
    /// Friday, like any other, and the nudge comes the morning before.
    ///
    /// WHAT HAPPENS: the loop is closed the next night with "you replied". `AskLedger.closures` treats any
    /// `mine` loop whose words contain "send", "share", "reply", "confirm" … as a loop about answering that
    /// person, and closes it on the user's first reply to their question — even when that reply was only a
    /// promise to do it later. So the promise Brownie was tracking is marked done by the promise itself, and
    /// Friday passes with nothing said.
    @Test
    func aPromiseInReplyClosesTheLoopItPromised() async {
        let w = World([.direct("whatsapp:133", "Lalita Pathak", handle: "whatsapp:+919000000555")])
        w.say("whatsapp:133", "when can you get me the perpetual licensing numbers?", day: 1, at: 15)
        w.say("whatsapp:133", "by Friday", mine: true, day: 1, at: 16)
        let loop = Loop.proposed("Send Lalita the perpetual licensing numbers", .mine, with: "Lalita Pathak",
                                 quote: "by Friday", due: "by Friday", openedAt: w.at(1, 16), id: "L-lic")
        let n1 = await w.night(1, judge: JudgeScript(loops: [loop]))
        #expect(n1.openLoops.count == 1, n1.summary)

        let n2 = await w.night(2)
        #expect(n2.openLoops.count == 1, "“by Friday” is a promise, not the thing promised — \(n2.line)")
        #expect(n2.cards.first?.dueLine == "Due tomorrow", "so the nudge still comes — \(n2.line)")
    }

    /// A date said as a day-and-month that has just gone by is read as the past and is overdue on the spot.
    /// "September 6" said on the 8th means next year to a person and two days ago to `DueWords`.
    @Test func aNamedDayThatHasJustGoneBy() async {
        let w = World([.direct("whatsapp:132", "Lalita Pathak", handle: "whatsapp:+919000000555")])
        #expect(DueWords.date("September 6", now: w.nightAt(1), timeZone: w.timeZone) == w.at(-1, 9), "three days in the past, not next year")
        let loop = Loop.proposed("Send Lalita the revised quote", .mine, with: "Lalita Pathak", due: "September 6", openedAt: w.at(1, 16), id: "L-q")
        let n1 = await w.night(1, judge: JudgeScript(loops: [loop]))
        #expect(n1.cards.first?.dueLine == "Overdue 3 days", "so the nudge fires the same night — \(n1.line)")
    }

    // 14 ───────────────────────────────────────────────────────────────────────────────────────────

    /// EXPECTED: the judge reads the same exchange from both sides and files the promise twice — once as the
    /// user's and once as Anjali's. That is one promise: the first stays, the mirror is turned away with a
    /// reason, and the Loops screen shows one line, not two facing each other.
    @Test func theSamePromiseFromBothSides() async {
        let w = World([.direct("whatsapp:141", "Anjali Deshpande", handle: "whatsapp:+919000000720")])
        w.say("whatsapp:141", "can you send the electricity bill for the flat?", day: 1, at: 14)
        w.say("whatsapp:141", "yes, I'll send the electricity bill tonight", mine: true, day: 1, at: 14.2)
        let n1 = await w.night(1, judge: JudgeScript(loops: [
            .proposed("Send Anjali the flat's electricity bill", .mine, with: "Anjali Deshpande", openedAt: w.at(1, 14.2), id: "L-mine"),
            .proposed("Provide the electricity bill for the flat", .theirs, with: "Anjali Deshpande", openedAt: w.at(1, 14.2), id: "L-theirs"),
        ]))
        #expect(n1.openLoops.count == 1, "one promise, not two facing each other — \(n1.line)")
        #expect(n1.openLoops.first?.direction == .mine, "the user's own side is the one that stays — \(n1.line)")
        #expect(n1.rejectedLoops.contains { $0.why.contains("mirrors") }, "\(n1.rejectedLoops)")
    }
}
