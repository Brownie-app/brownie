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

    public static func run(cards: [Card], loops: [Loop], past: [Card], noteUpdated: (String) -> Date?, fileExists: (String) -> Bool, now: Date, staleDays: Int) -> Result {
        var r = Result()
        for c in cards where c.state == .ready {
            // you just wrote to them — the next move is theirs
            if let p = c.person, !c.isDue, !c.isComeBack, let sent = past.first(where: { $0.state == .fired && samePerson($0.person, p) && now.timeIntervalSince($0.resolvedAt ?? $0.createdAt) < recentReplyHours * 3600 }) {
                r.dropped.append((c, "you wrote to \(p.split(separator: " ").first.map(String.init) ?? p) \(ago(now.timeIntervalSince(sent.resolvedAt ?? sent.createdAt)))")); continue
            }
            // its loop closed since the card was made
            if let l = c.loopID, let loop = loops.first(where: { $0.id == l }), loop.status == .closed {
                r.dropped.append((c, "the loop it was about closed\(loop.closedHow.map { " — \($0)" } ?? "")")); continue
            }
            // the same loop was fired within the card's lifetime, and this is not a deliberate nudge
            if let l = c.loopID, !c.isComeBack, past.contains(where: { $0.loopID == l && $0.state == .fired && now.timeIntervalSince($0.resolvedAt ?? $0.createdAt) < Card.lifetime }) {
                r.dropped.append((c, "you already fired a card for this")); continue
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

    static func samePerson(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        // "Nitesh (+919540752593)" and "Nitesh" are one person: drop the number, compare the first two words
        func key(_ s: String) -> String {
            var t = s; if let r = t.range(of: "(") { t = String(t[..<r.lowerBound]) }
            return t.lowercased().split(whereSeparator: { !$0.isLetter }).prefix(2).joined(separator: " ")
        }
        return key(a) == key(b)
    }
    static func ago(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        if m < 2 { return "just now" }
        if m < 60 { return "\(m) minutes ago" }
        return "\(m / 60) hour\(m / 60 == 1 ? "" : "s") ago"
    }
    static func neededFiles(_ c: Card) -> [String] {
        switch c.recipe {
        case .imessage(_, _, let att), .mail(_, _, _, let att): return att.filter { $0.hasPrefix("/") || $0.hasPrefix("~") }.map { ($0 as NSString).expandingTildeInPath }
        default: return []
        }
    }
}
