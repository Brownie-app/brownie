import Testing
import Foundation
import Domain
import LocalSources
import CloudSources
import Knowledge
import Proactive

/// Scenarios 15–20: the apps that are not a phone's chat list — mail, a broadcast channel, a work Slack — and
/// the two places identity has to hold: across channels, and across two spellings of one name.
@Suite struct ChannelScenarios {

    /// Whether a source can be scanned for asks at all. Every chat-shaped source declares `AskScanning`; the
    /// ones that do not are invisible to the ask ledger however much is said in them.
    static func scansAsks(_ t: Any.Type) -> Bool { t is any AskScanning.Type }

    // 15 ───────────────────────────────────────────────────────────────────────────────────────────

    /// EXPECTED: Devika mails asking for the audited accounts on Monday. The user answers from their phone on
    /// Wednesday, on the same thread. Wednesday night the ask closes, credited to the reply, and the line on
    /// Devika's note says it came from mail.
    ///
    /// WHAT HAPPENS: nothing at all. `GmailSource` is a `Source` and nothing more — it declares no `ChatReader`
    /// and no `AskScanning` (`Sources/CloudSources/GmailSource.swift:7`), so the nightly ask scan never asks it
    /// for anything. No ask is ever opened from mail, so none can close. Everything downstream is fine: the same
    /// thread read as messages gives the right ask and the right verdict, which is shown below.
    @Test(.disabled("fails: mail is never scanned for asks — GmailSource declares no AskScanning"))
    func gmailAskAnsweredTwoDaysLater() async {
        #expect(Self.scansAsks(GmailSource.self), "mail carries asks like any other channel")

        // The same thread, replayed as messages, to show the gap is the wiring and not the reading.
        let w = World([.direct("gmail:thread-9", "Devika Ranganathan", handle: "email:devika@raghavan-co.in")])
        w.say("gmail:thread-9", "Could you send across the audited accounts for FY25 before the board call?", day: 1, at: 10)
        let n1 = await w.night(1)
        #expect(n1.openAsks.count == 1, n1.summary)
        w.say("gmail:thread-9", "Attaching the audited accounts for FY25 — sent from my iPhone", mine: true, day: 3, at: 7)
        let n3 = await w.night(3)
        #expect(n3.ask(from: "Devika Ranganathan")?.outcome == .answered, n3.summary)
        #expect(n3.lines("Devika Ranganathan").contains { $0.contains("✅") }, "\(n3.lines("Devika Ranganathan"))")
    }

    /// Which sources the ask ledger can reach at all, stated once so a new source is not quietly left out.
    @Test func whichSourcesCarryAsks() {
        #expect(Self.scansAsks(WhatsAppSource.self) && Self.scansAsks(iMessageSource.self), "the phone's chats")
        #expect(Self.scansAsks(SlackSource.self) && Self.scansAsks(TeamsSource.self), "work chat")
        #expect(!Self.scansAsks(GmailSource.self), "mail, today, cannot be asked for asks — scenario 15")
    }

    // 16 ───────────────────────────────────────────────────────────────────────────────────────────

    /// EXPECTED: a Telegram channel the user follows posts forty times in three days and asks nothing of anyone.
    /// Nothing is kept: no ask, no loop, no card, and no line on anyone's note.
    @Test func aTelegramChannelWithNoQuestions() async {
        let w = World([.group("telegram:-1001998", "Bengaluru Build Weekly")])
        for (i, line) in Self.channelPosts.enumerated() {
            w.say("telegram:-1001998", from: "Bengaluru Build Weekly", line, day: 1 + i / 14, at: 8 + Double(i % 14) * 0.7)
        }
        #expect(Self.channelPosts.count == 40)
        let n1 = await w.night(1), n2 = await w.night(2), n3 = await w.night(3)
        #expect(n1.asks.isEmpty && n2.asks.isEmpty && n3.asks.isEmpty, "a channel asks the user nothing — \(n3.line)")
        #expect(n3.cards.isEmpty && n3.loops.isEmpty, n3.summary)
        #expect(n3.status.isEmpty, "and nobody gets a status block out of it")

        // Not only because channels are skipped: read line by line, none of the forty is a question or a request.
        #expect(Self.channelPosts.allSatisfy { !AskDetector.isAsk($0) }, "\(Self.channelPosts.filter { AskDetector.isAsk($0) })")
    }

    /// Forty posts of a build-notes channel: announcements, links, numbers. Nothing addressed to anybody.
    static let channelPosts: [String] = [
        "Build 412 is out on the beta channel.", "Crash rate down to 0.31 percent this week.",
        "The new indexer ships behind a flag for now.", "Release notes: https://example.com/notes/412",
        "Thanks to everyone who tried the nightly.", "Build 413 rolls out tomorrow morning.",
        "We have moved the meetup to the ninth floor.", "Doors at 6, talks at 6:30.",
        "Slides from last week are on the drive.", "Two seats left for the workshop.",
        "The workshop is now full.", "Recording of the SQLite talk is up.",
        "New sticker batch arrived, grab one at the desk.", "Reminder: the office is closed on Thursday.",
        "Build 414 fixes the scroll jank on 14-inch machines.", "Memory use is down 40 MB on cold start.",
        "We dropped support for the old sync format.", "Migration runs once, on first launch.",
        "A short write-up on the migration: https://example.com/migration", "Nothing to do on your side.",
        "Build 415 is a hotfix for the migration.", "Apologies for the churn this week.",
        "The changelog now lives in the repo.", "We are hiring two more people on infra.",
        "Details on the careers page.", "Coffee cart is back on Fridays.",
        "Build 416 adds the export button.", "Exports are CSV for now, Parquet later.",
        "The design system got a dark mode pass.", "Contrast is up across the board.",
        "Build 417 is out.", "The flag for the new indexer is now on by default.",
        "Old indexer code is deleted.", "Benchmarks: 2.4x on a 200k-note vault.",
        "We will publish the methodology next week.", "Office hours moved to Wednesdays.",
        "The forum is read-only over the weekend.", "Back on Monday.",
        "Build 418 is a small one.", "That is all for this week.",
    ]

    // 17 ───────────────────────────────────────────────────────────────────────────────────────────

    /// EXPECTED: Arif asks for a review in a Slack DM on Monday. On Tuesday the user answers him in a thread on
    /// that message. Tuesday night the ask is closed — the answer was given, and where in the conversation it
    /// was given is Slack's business, not the user's.
    ///
    /// WHAT HAPPENS: the ask stays open and the note says "no reply yet". `SlackSource` reads a chat with
    /// `conversations.history` alone (`Sources/CloudSources/SlackSource.swift:235`) and never calls
    /// `conversations.replies`, so a reply inside a thread does not exist as far as Brownie is concerned. The
    /// user is chased for a review they wrote yesterday.
    @Test(.disabled("fails: a Slack answer written in a thread is never read — only conversations.history is called"))
    func slackReviewAnsweredInAThread() async {
        let w = World([.direct("slack:D0ARIF", "Arif Qureshi", handle: "slack:U0ARIF")])
        w.say("slack:D0ARIF", "can you review the pricing PR today or tomorrow?", day: 1, at: 11)
        let n1 = await w.night(1, judge: JudgeScript(cards: [.proposed("Review Arif's pricing PR", to: "Arif Qureshi", on: .slack,
                                                                      why: "He asked yesterday")]))
        #expect(n1.openAsks.count == 1 && n1.cardTitles.count == 1, n1.summary)

        w.say("slack:D0ARIF", "reviewed — two comments on the tiering, rest looks good", mine: true, day: 2, at: 10, inThread: true)
        // The judge still reads "NO REPLY YET" in the ask lines, so it proposes the chase again.
        let n2 = await w.night(2, judge: JudgeScript(cards: [.proposed("Review Arif's pricing PR", to: "Arif Qureshi", on: .slack,
                                                                      why: "He asked on Monday and you have not replied")]))
        #expect(n2.ask(from: "Arif Qureshi")?.isAnswered == true, "a thread reply is a reply — \(n2.line)")
        #expect(n2.cards.isEmpty, "and nobody should be chased for it — \(n2.line)")
    }

    // 18 ───────────────────────────────────────────────────────────────────────────────────────────

    /// EXPECTED: Nikhil asks on WhatsApp for the deployment runbook; the user sends it on Slack the next day and
    /// never goes back to WhatsApp. On its own Brownie cannot know — the two chats share no words and no source
    /// reads the other — so the WhatsApp ask stays open and a card offers to reply. The judge, which sees both
    /// channels' summaries, can close it by id through `ask_updates`, and then the note says where it was answered.
    @Test func askedOnWhatsAppAnsweredOnSlack() async {
        let w = World([.direct("whatsapp:181", "Nikhil Bose", handle: "whatsapp:+919810181018"),
                       .direct("slack:D0NIKHIL", "Nikhil Bose", handle: "slack:U0NIKHIL")])
        w.say("whatsapp:181", "do you have the deployment runbook handy?", day: 1, at: 9)
        let n1 = await w.night(1)
        #expect(n1.openAsks.count == 1, n1.summary)
        let askID = n1.openAsks[0].id

        // Day 2: the user answers on Slack instead. Nothing on WhatsApp changes.
        w.say("slack:D0NIKHIL", "runbook is here: https://example.com/runbook, the rollback step is at the end", mine: true, day: 2, at: 14)
        let n2 = await w.night(2)
        #expect(n2.openAsks.count == 1, "without the judge, the question on WhatsApp is still waiting — \(n2.line)")
        #expect(n2.lines("Nikhil Bose").contains { $0.contains("no reply yet") }, "\(n2.lines("Nikhil Bose"))")

        // Day 3: the judge reads both channels and says so by id.
        let n3 = await w.night(3, judge: JudgeScript(askUpdates: [(idPrefix: askID, how: "on Slack")]))
        #expect(n3.ask(from: "Nikhil Bose")?.outcome == .answered, n3.summary)
        #expect(n3.ask(from: "Nikhil Bose")?.outcomeHow == "on Slack", n3.summary)
        #expect(n3.openAsks.isEmpty && n3.cards.isEmpty, n3.summary)
        #expect(n3.lines("Nikhil Bose").contains { $0.contains("answered on Slack") && $0.contains("(the judge)") }, "\(n3.lines("Nikhil Bose"))")
    }

    // 19 ───────────────────────────────────────────────────────────────────────────────────────────

    /// EXPECTED: Zoya asks something on Monday and never gets an answer. Brownie lets the question go at 45 days
    /// with a ⌛ line that says so, and never nags about it again. Long before that — within a week or two of
    /// asking — the cards stop: a question the user has passed over five times is not worth a sixth card.
    ///
    /// WHAT HAPPENS: the lapse is exact and the ⌛ line is right. The cards are not: nothing anywhere counts how
    /// often a card about the same open ask has already been made and turned down, so a judge that keeps
    /// proposing one keeps getting one through, every night, for forty-five days.
    @Test
    func anAskNeverAnsweredForFiftyDays() async {
        let w = World([.direct("whatsapp:191", "Zoya Rehman", handle: "whatsapp:+919810191019")])
        w.say("whatsapp:191", "can you put me in touch with your architect?", day: 1, at: 10)
        let title = "Introduce Zoya to your architect"
        var survived: [Int] = []
        for day in 1...50 {
            // The judge sees "NO REPLY YET" in the ask lines and proposes the same nudge, night after night.
            let n = await w.night(day, judge: JudgeScript(cards: [.proposed(title, to: "Zoya Rehman", why: "She asked and you have not replied")]),
                                  did: day > 1 ? [.dismissed(card: title)] : [])
            if n.cardTitles.contains(title) { survived.append(day) }
            switch day {
            case 1...45: #expect(n.openAsks.count == 1, "still waiting — \(n.line)")
            case 46...50:
                #expect(n.ask(from: "Zoya Rehman")?.isLapsed == true, "let go at 45 days — \(n.line)")
                #expect(n.lines("Zoya Rehman").contains { $0.contains("⌛") && $0.contains("no longer tracked") }, "\(n.lines("Zoya Rehman"))")
            default: break
            }
        }
        #expect(survived.count <= 5, "a card five mornings running is already too many; \(survived.count) is not a product — days \(survived.prefix(10))")
    }

    // 20 ───────────────────────────────────────────────────────────────────────────────────────────

    /// EXPECTED: "Nitesh" on WhatsApp and "Nitesh Kumar" on Slack, with no phone or email in common, are two
    /// records until the user says otherwise. Nothing crosses between them — his Slack promise is not folded
    /// into her WhatsApp one, and a card for each of them is a card for each of them — and Brownie raises the
    /// question for the user to answer.
    ///
    /// WHAT HAPPENS: the registry is right — two records, and the pair is raised. The ledgers are not.
    /// `PersonKey.same` treats a bare first name as the same person as any fuller name starting with it
    /// (`Sources/Domain/Person.swift:30`), and both the loops ledger and card dedupe compare through it with no
    /// registry in the way. So the second person's promise is swallowed as a duplicate of the first's and only
    /// one of the two cards reaches the morning. (Only the notes are safe: the coordinator routes the status
    /// block through the registry by handle, not by name.)
    @Test
    func twoSpellingsAcrossTwoApps() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scenario-20-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = PersonRegistry(vault: dir, now: { World.epoch }, selfNames: ["Vivek Upreti"])
        await registry.load()
        let a = await registry.register(label: "Nitesh", handle: "whatsapp:+919810201020")
        let b = await registry.register(label: "Nitesh Kumar", handle: "slack:U0NITESH")
        #expect(a != b, "no phone, no email in common: two records")
        let raised = await registry.suspects()
        #expect(raised.count == 1, "and the question is put to the user")

        // What the ledgers make of the same two names, with no registry in the way.
        let mine = Loop.proposed("Send the wiring diagram", .mine, with: "Nitesh", openedAt: World.epoch, id: "L-a")
        let hers = Loop.proposed("Send the wiring diagram", .mine, with: "Nitesh Kumar", openedAt: World.epoch, id: "L-b")
        #expect(!LoopLedger.same(mine, hers), "two people, two promises")
        let one = Card.proposed("Send Nitesh the wiring diagram", to: "Nitesh", draft: "Diagram attached.")
        let two = Card.proposed("Send Nitesh Kumar the wiring diagram", to: "Nitesh Kumar", draft: "Diagram attached.")
        #expect(CardDedupe.dedupe([one, two]).count == 2, "two people, two messages")
    }
}
