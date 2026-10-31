import Foundation
import Domain

/// Ten seconds before the cards show: is each one still true? A card whose loop closed, whose file is gone,
/// or that was already fired for the same loop is dropped; one built only on old notes is flagged.
public enum QuietCheck {
    public struct Result: Sendable, Equatable {
        public var kept: [Card] = []
        public var dropped: [(card: Card, why: String)] = []
        public static func == (a: Result, b: Result) -> Bool { a.kept == b.kept && a.dropped.map(\.card) == b.dropped.map(\.card) && a.dropped.map(\.why) == b.dropped.map(\.why) }
    }
    /// The setting: notes older than this many days no longer count as evidence on their own.
    public static let defaultStaleDays = 7

    /// You wrote to someone this recently → no card asking you to write to them again, unless a date or a came-back says so.
    public static let recentReplyHours = 6.0

    /// How long a card you turned down keeps the same card from being proposed again. A card you *fired* is quiet for
    /// its own lifetime — you did it, and next week's version of the same errand is a fair thing to raise. A card you
    /// *dismissed* is a judgement about the thing itself, and asking again tomorrow is the single most annoying thing
    /// this app can do, so it stays quiet for a fortnight. A due date or a came-back still gets through: both are news.
    public static let dismissedQuietDays = 14.0

    /// `noteUpdated` answers with the day a note's substance last changed (`Note.updatedAt`, from its front-matter's
    /// `updated`), never the file's mtime — the nightly status-block rewrite and iCloud must not make a note look fresh.
    /// How recently an ask must have been settled for a card that chases it to be dropped. Beyond this the answer is
    /// old news and a card about the same subject is a new errand, not a stale chase.
    public static let answeredQuietDays = 7.0

    public static func run(cards: [Card], loops: [Loop], past: [Card], asks: [Ask] = [], noteUpdated: (String) -> Date?, fileExists: (String) -> Bool, now: Date, staleDays: Int) -> Result {
        var r = Result()
        for c in cards where c.state == .ready {
            // you just wrote to them — the next move is theirs
            if let p = c.person, !c.isDue, !c.isComeBack, let sent = past.first(where: { $0.state == .fired && samePerson($0.person, p) && now.timeIntervalSince($0.resolvedAt ?? $0.createdAt) < recentReplyHours * 3600 }) {
                r.dropped.append((c, "you wrote to \(p.split(separator: " ").first.map(String.init) ?? p) \(ago(now.timeIntervalSince(sent.resolvedAt ?? sent.createdAt)))")); continue
            }
            // its loop is no longer open — closed since the card was made, let go for want of news, or dismissed by the user
            if let l = c.loopID, let loop = loops.first(where: { $0.id == l }), loop.status != .open {
                switch loop.status {
                case .lapsed: r.dropped.append((c, "the loop it was about was let go"))
                case .dismissed: r.dropped.append((c, "the loop it was about was dismissed"))
                case .closed, .open: r.dropped.append((c, "the loop it was about closed\(loop.closedHow.map { " — \($0)" } ?? "")"))
                }
                continue
            }
            // the same loop was fired within the card's lifetime, and this is not a deliberate nudge
            if let l = c.loopID, !c.isComeBack, past.contains(where: { $0.loopID == l && $0.state == .fired && now.timeIntervalSince($0.resolvedAt ?? $0.createdAt) < Card.lifetime }) {
                r.dropped.append((c, "you already fired a card for this")); continue
            }
            // you have seen this card before and answered it — by doing it, or by turning it down. A card born of an
            // ask carries no loop id and is stamped with a fresh id every night, so the rule above never sees it; this
            // one recognises the card itself. Without it the same nudge arrives every morning until the ask lapses.
            let twin: Card? = (c.isComeBack || c.isDue) ? nil : past.first { (p: Card) -> Bool in
                guard p.state == .dismissed || p.state == .fired else { return false }
                let quiet: TimeInterval = p.state == .dismissed ? dismissedQuietDays * 86400 : Card.lifetime
                guard now.timeIntervalSince(p.resolvedAt ?? p.createdAt) < quiet else { return false }
                return QuietCheck.twin(p, c)
            }
            if let twin {
                let when = ago(now.timeIntervalSince(twin.resolvedAt ?? twin.createdAt))
                r.dropped.append((c, twin.state == .fired ? "you already did this \(when)" : "you turned this down \(when)")); continue
            }
            // the question it chases has been answered since. A card born of an ask carries no loop id, so the rule
            // above cannot see it; this one matches the card against the asks themselves, the same way a loop is
            // matched to the ask it came from. It is the deterministic backstop for a judge that proposed a chase
            // from a summary written before the answer arrived.
            if let p = c.person, let settled = asks.first(where: { a in
                // isAnswered, not isSettled: here the benefit of the doubt is the kind reading. They asked, the user
                // wrote back, and the reply shares the subject — that is enough not to nag. A promise is not an answer,
                // and `isAnswered` already says so, which is what keeps the chase for a thing genuinely still owed.
                guard a.isAnswered, samePerson(p, a.person) else { return false }
                guard let at = StatusRules.settledAt(a), now.timeIntervalSince(at) < answeredQuietDays * 86400 else { return false }
                // the title alone, not the reasoning: the title is what the card is about, while "why" is prose that
                // only dilutes the share of words the two have in common.
                return AskLedger.overlap(a.question, c.title) >= 0.5
            }) {
                r.dropped.append((c, "they have been answered since — \(settled.person) asked \"\(settled.question.prefix(60))\"")); continue
            }
            // an attachment or a note the recipe needs is gone
            if let missing = neededFiles(c).first(where: { !fileExists($0) }) {
                r.dropped.append((c, "the file it needs is gone: \((missing as NSString).lastPathComponent)")); continue
            }
            // evidence: notes older than the setting are stale; a card standing only on stale notes is dropped
            let notes = c.evidence.compactMap { e -> (String, Date)? in
                let s = e.source.trimmingCharacters(in: .whitespaces)
                guard s.hasSuffix(".md"), let d = noteUpdated(s) else { return nil }
                return (s, d)
            }
            let staleNotes = notes.filter { now.timeIntervalSince($0.1) > Double(staleDays) * 86400 }
            let otherEvidence = c.evidence.count - notes.count
            if !staleNotes.isEmpty, otherEvidence == 0, staleNotes.count == notes.count {
                let days = Int(now.timeIntervalSince(staleNotes.map(\.1).max()!) / 86400)
                r.dropped.append((c, "built only on notes last updated \(days) days ago")); continue
            }
            var kept = c
            if let oldest = staleNotes.max(by: { $0.1 > $1.1 }) {
                kept.staleLine = "Partly from a note last updated \(Int(now.timeIntervalSince(oldest.1) / 86400)) days ago (\(oldest.0))"
            } else { kept.staleLine = nil }
            r.kept.append(kept)
        }
        r.kept += cards.filter { $0.state != .ready }
        return r
    }

    /// The share of words two cards must have in common to be the same card a fortnight apart. Higher than the
    /// one night's dedupe uses, because that one only ever compares cards the same judge made in the same hour,
    /// where near-identical wording really is one errand — while this one reaches back over days, and two
    /// different things to say to the same person must both still get through.
    static let twinOverlap = 0.8
    /// The same card as one you already answered: the same loop, or the same person and almost the same words.
    static func twin(_ a: Card, _ b: Card) -> Bool {
        if let l = a.loopID, let m = b.loopID { return l == m }
        guard let pa = CardDedupe.person(a), let pb = CardDedupe.person(b), PersonKey.sameKey(pa, pb) else { return false }
        let wa = LoopLedger.words(a.title + " " + a.why + " " + a.draft), wb = LoopLedger.words(b.title + " " + b.why + " " + b.draft)
        guard !wa.isEmpty, !wb.isEmpty else { return false }
        return Double(wa.intersection(wb).count) / Double(min(wa.count, wb.count)) >= twinOverlap
    }

    /// One matcher for the whole app: "Lokesh (+919000000111)" and "Lokesh" are one person, by `PersonKey`.
    static func samePerson(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        return PersonKey.same(a, b)
    }
    static func ago(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        if m < 2 { return "just now" }
        if m < 60 { return "\(m) minutes ago" }
        if m < 36 * 60 { return "\(m / 60) hour\(m / 60 == 1 ? "" : "s") ago" }
        let d = m / (24 * 60)
        return d == 1 ? "yesterday" : "\(d) days ago"
    }
    static func neededFiles(_ c: Card) -> [String] {
        switch c.recipe {
        case .imessage(_, _, let att), .mail(_, _, _, let att): return att.filter { $0.hasPrefix("/") || $0.hasPrefix("~") }.map { ($0 as NSString).expandingTildeInPath }
        default: return []
        }
    }
}
