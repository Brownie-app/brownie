import Testing
import Foundation
import Domain
import LocalSources
import Proactive

/// Sixteen conversations across every channel, replayed through the real rules and printed as a report — what was
/// said, and what Brownie makes of it. Not an assertion suite: `docs/scenarios.md` and the twenty scenarios are
/// where the expectations live. This exists so a person can read the behaviour rather than infer it from tests.
///
///     swift test --skip EvalTests --filter ScenarioReport
@Suite struct ScenarioReport {

    @Test func whatBrownieMakesOfSixteenChats() async {
        var out = ["", String(repeating: "═", count: 92),
                   "  SIXTEEN CONVERSATIONS · what the rules make of them, with no reader and no cloud judge",
                   String(repeating: "═", count: 92)]

        // 1 ── WhatsApp · a plain request, answered the next day
        out += await report(1, "WhatsApp", "a plain request, answered the next day") { w in
            w.say("whatsapp:1", "can you send the signed rent agreement today?", day: 1, at: 10)
            _ = await w.night(1)
            w.say("whatsapp:1", "sent it to your email just now", mine: true, day: 2, at: 9)
            return await w.night(2)
        } chats: { [.direct("whatsapp:1", "Tanvi Rege", handle: "whatsapp:+919000000701")] }

        // 2 ── WhatsApp · the user says no, with a week in the sentence
        out += await report(2, "WhatsApp", "a refusal that names a week — the one that used to read as a promise") { w in
            w.say("whatsapp:2", "can you take the Thursday standup this week?", day: 1, at: 11)
            w.say("whatsapp:2", "sorry, can't this week", mine: true, day: 1, at: 12)
            return await w.night(1)
        } chats: { [.direct("whatsapp:2", "Devan Mehra", handle: "whatsapp:+919000000702")] }

        // 3 ── WhatsApp · sympathy about something else, in the middle of a waiting question
        out += await report(3, "WhatsApp", "\u{201C}oh no\u{201D} about her train — not an answer, and not a refusal") { w in
            w.say("whatsapp:3", "what's the final number on the Baroda quotation?", day: 1, at: 10)
            _ = await w.night(1)
            w.say("whatsapp:3", "my train got cancelled, what a morning", day: 2, at: 8)
            w.say("whatsapp:3", "oh no", mine: true, day: 2, at: 9)
            return await w.night(2)
        } chats: { [.direct("whatsapp:3", "Farah Siddiqui", handle: "whatsapp:+919000000703")] }

        // 4 ── WhatsApp · a promise dated by a weekday
        out += await report(4, "WhatsApp", "\u{201C}by Friday\u{201D} — a promise, not an answer") { w in
            w.say("whatsapp:4", "when do I get the Q3 numbers?", day: 1, at: 9)
            w.say("whatsapp:4", "by Friday", mine: true, day: 1, at: 9.5)
            return await w.night(1, judge: JudgeScript(loops: [
                .proposed("Send Lalita the Q3 numbers", .mine, with: "Lalita Pathak", openedAt: w.at(1, 9.5), id: "L-q3"),
            ]))
        } chats: { [.direct("whatsapp:4", "Lalita Pathak", handle: "whatsapp:+919000000704")] }

        // 5 ── iMessage · they say themselves that it is settled
        out += await report(5, "Messages", "they close it themselves") { w in
            w.say("imessage:5", "did the deposit go through?", day: 1, at: 16)
            w.say("imessage:5", "checking", mine: true, day: 1, at: 16.2)
            w.say("imessage:5", "got it, thanks", day: 1, at: 18)
            return await w.night(1)
        } chats: { [.direct("imessage:5", "Amma", handle: "imessage:+919000000705")] }

        // 6 ── iMessage · ordinary chatter with nothing owed
        out += await report(6, "Messages", "nothing is being asked of anyone") { w in
            w.say("imessage:6", "that dosa place near the office has shut", day: 1, at: 13)
            w.say("imessage:6", "no way, we were there in May", mine: true, day: 1, at: 13.2)
            w.say("imessage:6", "haha yes. anyway, see you Sunday", day: 1, at: 13.4)
            return await w.night(1)
        } chats: { [.direct("imessage:6", "Zubin Patel", handle: "imessage:+919000000706")] }

        // 7 ── Telegram · a channel that asks nobody anything
        out += await report(7, "Telegram", "a channel posting into the void") { w in
            for (i, line) in ["Applications for the Feb cohort are open.", "Reminder: demo night is on the 14th.",
                              "We are hiring a community lead.", "New writeup: shipping on-device models on Apple silicon.",
                              "Anyone hiring? Post in the thread.", "Venue changed to Lakeside."].enumerated() {
                w.say("telegram:-1001", from: "Bengaluru Build Weekly", line, day: 1, at: 9 + Double(i))
            }
            return await w.night(1)
        } chats: { [.group("telegram:-1001", "Bengaluru Build Weekly")] }

        // 8 ── Telegram · a direct request with a date in it
        out += await report(8, "Telegram", "a request with a deadline in words") { w in
            w.say("telegram:8", "bhai, invoice bhej do by Monday please", day: 1, at: 15)
            return await w.night(1, judge: JudgeScript(loops: [
                .proposed("Send Imran the invoice", .mine, with: "Imran Qadri", quote: "invoice bhej do by Monday", due: "by Monday", openedAt: w.at(1, 15), id: "L-inv"),
            ]))
        } chats: { [.direct("telegram:8", "Imran Qadri", handle: "telegram:88800008")] }

        // 9 ── Slack · the answer is written in a thread
        out += await report(9, "Slack", "answered in a thread — invisible until this week") { w in
            w.say("slack:D9", "can you review the pricing PR today or tomorrow?", day: 1, at: 11)
            _ = await w.night(1, judge: JudgeScript(cards: [.proposed("Review Noor's pricing PR", to: "Noor Qureshi", on: .slack, why: "He asked today")]))
            w.say("slack:D9", "reviewed — two comments on the tiering, rest looks good", mine: true, day: 2, at: 10, inThread: true)
            return await w.night(2, judge: JudgeScript(cards: [.proposed("Review Noor's pricing PR", to: "Noor Qureshi", on: .slack, why: "He asked on Monday and you have not replied")]))
        } chats: { [.direct("slack:D9", "Noor Qureshi", handle: "slack:U0NOOR")] }

        // 10 ── Slack · a question thrown at a channel
        out += await report(10, "Slack", "a question to the room, not to you") { w in
            w.say("slack:C10", from: "Deepak Iyer", "does anyone know why staging is on the old schema?", day: 1, at: 10)
            w.say("slack:C10", from: "Sneha Kulkarni", "same, and who owns the migration now?", day: 1, at: 10.2)
            return await w.night(1)
        } chats: { [.group("slack:C10", "#platform")] }

        // 11 ── WhatsApp group · a request to the user by name
        out += await report(11, "WhatsApp group", "named in a group — an ask like any other") { w in
            w.say("whatsapp:111", from: "Sneha Kulkarni", "Ishan, can you send the deck before the meeting?", day: 1, at: 9)
            w.say("whatsapp:111", from: "Deepak Iyer", "same question about the pricing sheet", day: 1, at: 9.2)
            return await w.night(1)
        } chats: { [.group("whatsapp:111", "Tideline — Launch")] }

        // 12 ── Gmail · the request is one sentence inside a long mail
        out += await report(12, "Gmail", "a request buried in a long mail") { w in
            w.say("gmail:t12", """
            Hi Ishan,

            Thanks for the time on Tuesday — the team found the walkthrough genuinely useful, and Rhea has \
            circulated the notes internally. We are close to a decision on the vendor, and the finance committee \
            meets on the 14th, which is sooner than we expected when we last spoke about timelines.

            Could you send across the audited accounts for FY25 before the board call?

            There is no rush on the rest of the pack; the accounts are the only thing the committee has asked for \
            by name, and everything else can follow once they have met and come back to us with questions.

            Best,
            Rhea
            """, day: 1, at: 10)
            return await w.night(1)
        } chats: { [.direct("gmail:t12", "Rhea Chhabra", handle: "email:rhea@chhabra-co.test")] }

        // 13 ── Gmail · answered from a phone two days later
        out += await report(13, "Gmail", "answered two days later, from a phone") { w in
            w.say("gmail:t13", "Could you share the signed MoU before we file?", day: 1, at: 10)
            _ = await w.night(1)
            w.say("gmail:t13", "Attaching the signed MoU — sent from my iPhone", mine: true, day: 3, at: 7)
            return await w.night(3)
        } chats: { [.direct("gmail:t13", "Yusuf Krishnan", handle: "email:yusuf@meridianpartners.test")] }

        // 14 ── WhatsApp · a card the user turned down, proposed again
        out += await report(14, "WhatsApp", "a card you turned down last night") { w in
            w.say("whatsapp:14", "still waiting on that intro to the Blume partner", day: 1, at: 12)
            _ = await w.night(1, judge: JudgeScript(cards: [.proposed("Introduce Farid to the Blume partner", to: "Farid Sethi", why: "He asked today")]),
                              did: [])
            return await w.night(2, judge: JudgeScript(cards: [.proposed("Introduce Farid to the Blume partner", to: "Farid Sethi", why: "He asked on Monday")]),
                                 did: [.dismissed(card: "Introduce Farid to the Blume partner")])
        } chats: { [.direct("whatsapp:14", "Farid Sethi", handle: "whatsapp:+919000000707")] }

        // 15 ── two apps, one first name, possibly two people
        out += await report(15, "WhatsApp + Slack", "one first name, two spellings") { w in
            w.say("whatsapp:15", "can you send the wiring diagram?", day: 1, at: 10)
            w.say("slack:D15", "and the wiring diagram when you get a moment?", day: 1, at: 11)
            return await w.night(1, judge: JudgeScript(loops: [
                .proposed("Send the wiring diagram", .mine, with: "Lokesh", openedAt: w.at(1, 10), id: "L-a"),
                .proposed("Send the wiring diagram", .mine, with: "Lokesh Kadri", openedAt: w.at(1, 11), id: "L-b"),
            ]))
        } chats: { [.direct("whatsapp:15", "Lokesh", handle: "whatsapp:+919000000708"),
                    .direct("slack:D15", "Lokesh Kadri", handle: "slack:U0NIT")] }

        // 16 ── WhatsApp · Hinglish, and a line of the user's own that looks like an instruction
        out += await report(16, "WhatsApp", "Hinglish, and the user's own line that reads like an order") { w in
            w.say("whatsapp:16", "pen test ka address mil gaya?", day: 1, at: 14)
            w.say("whatsapp:16", "email me tha which he was sending to others", mine: true, day: 1, at: 14.5)
            w.say("whatsapp:16", "theek hai, dekh leta hoon", day: 1, at: 15)
            return await w.night(1)
        } chats: { [.direct("whatsapp:16", "Lalita Pathak", handle: "whatsapp:+919000000704")] }

        out.append(String(repeating: "═", count: 92))
        print(out.joined(separator: "\n"))
    }

    // MARK: - printing

    func report(_ n: Int, _ source: String, _ headline: String,
                _ play: (World) async -> Night, chats: () -> [Chat]) async -> [String] {
        let w = World(chats())
        let night = await play(w)
        var out = ["", "── \(n) · \(source) · \(headline) " + String(repeating: "─", count: max(0, 70 - headline.count - source.count))]
        for c in w.chats {
            if w.chats.count > 1 { out.append("   [\(c.name)]") }
            for m in c.messages.sorted(by: { $0.date < $1.date }) {
                out.append("   " + stamp(m.date, w) + "  " + (m.isMe ? "you " : String((m.sender + "      ").prefix(6))) + "  " + one(m.text))
            }
        }
        out.append("")
        if night.asks.isEmpty { out.append("   ask     · none — nobody asked the user for anything") }
        for a in night.asks {
            let verdict = a.outcome.map(\.rawValue) ?? (a.answeredAt == nil ? "open" : "unjudged (the reader would decide)")
            out.append("   ask     · \(a.person): “\(one(a.question, 52))” → \(verdict)\(a.isLapsed ? ", let go" : "")")
        }
        for l in night.loops { out.append("   loop    · \(l.what) → \(l.status.rawValue)\(l.closedHow.map { " (\($0))" } ?? "")\(l.dueDate != nil ? " · due \(day(l.dueDate!, w))" : "")") }
        for r in night.rejectedLoops { out.append("   loop    · \(r.what) → turned away (\(r.why))") }
        if night.cards.isEmpty && night.droppedCards.isEmpty { out.append("   card    · none") }
        for c in night.cards { out.append("   card    · \(c.title)") }
        for d in night.droppedCards { out.append("   card    · \(d.title) → dropped (\(d.why))") }
        for (person, lines) in night.status.sorted(by: { $0.key < $1.key }) {
            for l in lines { out.append("   note    · \(person): \(l)") }
        }
        return out
    }

    func one(_ s: String, _ cap: Int = 64) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ").split(separator: " ").joined(separator: " ")
        return t.count <= cap ? t : String(t.prefix(cap - 1)) + "…"
    }
    func stamp(_ d: Date, _ w: World) -> String {
        let days = Int(d.timeIntervalSince(World.epoch) / 86400)
        let mins = Int(d.timeIntervalSince(World.epoch).truncatingRemainder(dividingBy: 86400) / 60)
        return String(format: "day %d %02d:%02d", days, mins / 60, mins % 60)
    }
    func day(_ d: Date, _ w: World) -> String { "day \(Int(d.timeIntervalSince(World.epoch) / 86400))" }
}
