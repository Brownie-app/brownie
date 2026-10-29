import Foundation
import Domain
import Support

/// Checking the loops the judge reported against the messages they came from.
///
/// The judge works from summaries alone, by design: it is told "the line that opened it (as summarised — never
/// invent wording)". So it cannot produce a verbatim span, and asking it to would only produce an invented one.
/// The span has to be found afterwards, here, by going back to the source — which is also the only place the
/// amounts and ids in `what` can be checked, because by the time the judge sees a summary the message is gone.
public enum LoopGate {

    public struct Outcome: Sendable, Equatable {
        public var kept: [Loop] = []
        /// A loop whose claim lost a clause nothing supported, with what went.
        public var repaired: [(id: String, before: String, after: String, unsupported: [String])] = []
        /// A loop refused outright: its claim could not be repaired into something still true.
        public var refused: [(id: String, what: String, unsupported: [String])] = []
        /// Loops nothing could be said about, because the conversation could not be read back.
        public var unchecked: Int = 0
        /// Loops that got a span: the ones whose specifics are now worth something.
        public var proven: Int = 0

        public static func == (a: Outcome, b: Outcome) -> Bool {
            a.kept == b.kept && a.unchecked == b.unchecked && a.proven == b.proven
                && a.repaired.map(\.id) == b.repaired.map(\.id) && a.refused.map(\.id) == b.refused.map(\.id)
        }
    }

    /// Pure, so the rules are testable without a source: `lines` is asked for the messages around one loop.
    public static func apply(_ loops: [Loop], lines: (Loop) -> [SourceLine]) -> Outcome {
        var out = Outcome()
        for loop in loops {
            let window = lines(loop)
            guard !window.isEmpty else { out.unchecked += 1; out.kept.append(loop); continue }

            var loop = loop
            // The span is the message itself. Not an extract of it: an extract is a judgement about which part
            // mattered, and a wrong one would be a new way to mislead. The message is simply what was said.
            if let span = Verbatim.support(for: loop.what + " " + loop.quote, in: window) {
                loop.span = span
                out.proven += 1
            }

            let bad = Specifics.unsupported(in: loop.what, against: window)
            guard !bad.isEmpty else { out.kept.append(loop); continue }

            if let repaired = Claim.withoutUnsupported(loop.what, specifics: bad), repaired != loop.what {
                out.repaired.append((loop.id, loop.what, repaired, bad))
                out.kept.append(Loop(id: loop.id, direction: loop.direction, person: loop.person, what: repaired,
                                     quote: loop.quote, sourceLabel: loop.sourceLabel, due: loop.due, dueDate: loop.dueDate,
                                     status: loop.status, openedAt: loop.openedAt, noticedAt: loop.noticedAt,
                                     closedAt: loop.closedAt, closedHow: loop.closedHow, closedBy: loop.closedBy,
                                     lapsedAt: loop.lapsedAt, firedCardIDs: loop.firedCardIDs,
                                     cameBackCount: loop.cameBackCount, span: loop.span))
            } else {
                out.refused.append((loop.id, loop.what, bad))
            }
        }
        return out
    }

    /// The same, against live sources. One lookup per person, reused across that person's loops.
    public static func apply(_ loops: [Loop], lookup: SourceLineLookup, log: Log? = nil) async -> Outcome {
        var byPerson: [String: [SourceLine]] = [:]
        for loop in loops where byPerson[loop.person] == nil {
            byPerson[loop.person] = await lookup(loop.person, loop.openedAt)
        }
        let out = apply(loops, lines: { byPerson[$0.person] ?? [] })
        if let log {
            for r in out.repaired { log.warn("loop \(r.id.prefix(8)): nothing said \(r.unsupported.joined(separator: ", ")) — “\(r.before)” → “\(r.after)”") }
            for r in out.refused { log.warn("loop \(r.id.prefix(8)) refused: nothing said \(r.unsupported.joined(separator: ", ")) in “\(r.what)”") }
            log.info("loop gate: \(out.kept.count) kept, \(out.proven) with a span, \(out.repaired.count) repaired, \(out.refused.count) refused, \(out.unchecked) unchecked")
        }
        return out
    }
}

/// Checking a card before it is shown, and in particular the word `verified` on it.
///
/// `verification` arrives as whatever the preparer's model put in its JSON — `(d["verification"] as? String) ==
/// "verified"` — so the model grades its own work and has never once failed itself. The two rules below are the
/// grading the app can do on its own: the claim's specifics have to be in a message, and the evidence has to
/// include something Brownie did not write.
public enum CardGate {

    public struct Outcome: Sendable {
        public var cards: [Card] = []
        public var downgraded: [(id: String, title: String, why: String)] = []
    }

    /// Reasons a card cannot call itself verified, in the words the card will carry.
    public enum Doubt: String, Sendable {
        case unsupported = "a figure or date in this isn't in any message I can find"
        case circular = "everything backing this is something I wrote myself"
    }

    public static func apply(_ cards: [Card], lines: (Card) -> [SourceLine]) -> Outcome {
        var out = Outcome()
        for card in cards {
            guard card.verification == .verified else { out.cards.append(card); continue }
            var doubt: Doubt? = nil

            // Independence first: it needs no source read, and it is the failure that produced the worst card
            // in the audit — a summary and the note written from it, counted as two.
            if !card.evidence.isEmpty, card.evidence.allSatisfy(\.isDerived) { doubt = .circular }

            if doubt == nil {
                let window = lines(card)
                if !window.isEmpty, !Specifics.unsupported(in: card.title + " " + card.why, against: window).isEmpty { doubt = .unsupported }
            }

            guard let doubt else { out.cards.append(card); continue }
            out.downgraded.append((card.id, card.title, doubt.rawValue))
            out.cards.append(downgrade(card, to: doubt))
        }
        return out
    }

    public static func apply(_ cards: [Card], lookup: SourceLineLookup, log: Log? = nil) async -> Outcome {
        var byCard: [String: [SourceLine]] = [:]
        for card in cards {
            guard let person = CardDedupe.person(card) ?? personFromLabel(card.sourceLabel) else { continue }
            byCard[card.id] = await lookup(person, card.createdAt)
        }
        let out = apply(cards, lines: { byCard[$0.id] ?? [] })
        if let log {
            for d in out.downgraded { log.warn("card \(d.id.prefix(8)) “\(d.title)”: not verified — \(d.why)") }
        }
        return out
    }

    /// Keeps the card and the model's own reasoning, and says plainly why the app would not sign it off. The
    /// user still sees the thing; they just are not told it was checked when it was not.
    static func downgrade(_ c: Card, to doubt: Doubt) -> Card {
        var out = Card(id: c.id, title: c.title, sourceLabel: c.sourceLabel, why: c.why, actionLabel: c.actionLabel,
                       dueLine: c.dueLine, urgency: c.urgency, draftLabel: c.draftLabel, draft: c.draft, recipe: c.recipe,
                       evidence: c.evidence, verification: .unverified,
                       verifiedLine: "Not checked — \(doubt.rawValue).", state: c.state, createdAt: c.createdAt,
                       cameBack: c.cameBack, loopID: c.loopID)
        out.snoozedUntil = c.snoozedUntil; out.resolvedAt = c.resolvedAt; out.dueDate = c.dueDate
        out.staleLine = c.staleLine; out.owner = c.owner; out.handledBy = c.handledBy
        return out
    }

    /// "WhatsApp · Asha Mehra (+15550…)" → "Asha Mehra". A card whose recipe is a message already knows
    /// who it is for; one driving the screen or a browser only has the label.
    static func personFromLabel(_ label: String) -> String? {
        let parts = label.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return nil }
        let name = PersonKey.displayName(parts[1])
        return name.isEmpty ? nil : name
    }
}
