import Foundation
import Domain

/// The asks ledger: what people asked the user in direct chats, and when the user answered. Local only.
public enum AskLedger {
    public static let horizon: TimeInterval = 45 * 86400

    /// New scans replace what they cover (an answer can arrive later); old asks fall off after the horizon.
    public static func merge(existing: [Ask], found: [Ask], now: Date) -> [Ask] {
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for f in found {
            // a fresh scan brings the reply; the judgement already made about that same reply is kept
            var f = f
            if let old = byID[f.id], old.answeredAt == f.answeredAt, old.reply == f.reply { f.addressed = old.addressed }
            byID[f.id] = f
        }
        return byID.values.filter { now.timeIntervalSince($0.askedAt) < horizon }.sorted { $0.askedAt > $1.askedAt }
    }

    static let answering = ["answer", "reply", "respond", "get back", "question", "guidance", "tell", "let", "confirm", "share", "send"]
    /// Loops the user owed someone that their reply settled: a `mine` loop about answering that person, opened before the reply.
    public static func closures(loops: [Loop], asks: [Ask], now: Date) -> [Loop] {
        loops.map { l in
            guard l.status == .open, l.direction == .mine, answering.contains(where: { l.what.lowercased().contains($0) }) else { return l }
            guard let a = asks.first(where: { $0.isAnswered && samePerson($0.person, l.person) && $0.askedAt <= l.openedAt && l.openedAt <= $0.answeredAt! }) else { return l }
            var l = l; l.status = .closed; l.closedAt = a.answeredAt; l.closedHow = "you replied \(when(a.answeredAt!, now: now))"
            return l
        }
    }

    /// What the judge is told — dates only, never the words.
    public static func judgeLines(_ asks: [Ask], now: Date) -> String {
        let open = asks.filter(\.isOpen), answered = asks.filter(\.isAnswered)
        guard !asks.isEmpty else { return "" }
        let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"
        var lines: [String] = []
        for a in open.prefix(20) {
            if let r = a.answeredAt { lines.append("- \(a.person) asked the user something on \(f.string(from: a.askedAt)) · the user wrote at \(f.string(from: r)) but NOT about it — still unanswered (\(when(a.askedAt, now: now)))") }
            else { lines.append("- \(a.person) asked the user something on \(f.string(from: a.askedAt)) · NO REPLY YET (\(when(a.askedAt, now: now)))") }
        }
        for a in answered.prefix(20) { lines.append("- \(a.person) asked the user something on \(f.string(from: a.askedAt)) · the user replied \(f.string(from: a.answeredAt!)) — done") }
        return "ASKS IN DIRECT CHATS (read from the chats themselves; a reply means it is answered — do not make an item to answer or update that person again unless they wrote after the reply):\n" + lines.joined(separator: "\n") + "\n"
    }

    public static func samePerson(_ a: String, _ b: String) -> Bool { PersonKey.same(a, b) }
    static func when(_ d: Date, now: Date) -> String {
        let s = now.timeIntervalSince(d)
        if s < 3600 { return "\(max(1, Int(s / 60))) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) h ago" }
        let days = Int(s / 86400); return days == 1 ? "yesterday" : "\(days) days ago"
    }
}

/// The block Brownie writes at the top of a person's note — the plain record of what's between you, from the ledgers, not the brain.
public enum BetweenYou {
    public static let open = "<!-- brownie:between-you -->", close = "<!-- /brownie:between-you -->"

    public static func render(person: String, asks: [Ask], loops: [Loop], now: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "d MMM"; let t = DateFormatter(); t.dateFormat = "d MMM HH:mm"
        let theirAsks = asks.filter { AskLedger.samePerson($0.person, person) }.sorted { $0.askedAt > $1.askedAt }.prefix(8)
        let theirLoops = loops.filter { AskLedger.samePerson($0.person, person) && ($0.status == .open || now.timeIntervalSince($0.closedAt ?? .distantPast) < 14 * 86400) }
        var lines: [String] = []
        for a in theirAsks {
            let q = a.question.replacingOccurrences(of: "\n", with: " ")
            if let r = a.answeredAt, a.addressed == false { lines.append("- ⏳ \(f.string(from: a.askedAt)) they asked: “\(q)” — you wrote at \(t.string(from: r)) but **not about this**; still open") }
            else if let r = a.answeredAt { lines.append("- ✅ \(f.string(from: a.askedAt)) they asked: “\(q)” — you replied \(t.string(from: r))\(a.addressed == nil ? " _(not checked)_" : "")") }
            else { lines.append("- ⏳ \(f.string(from: a.askedAt)) they asked: “\(q)” — **no reply yet** (\(AskLedger.when(a.askedAt, now: now)))") }
        }
        for l in theirLoops.sorted(by: { ($0.status == .open ? 0 : 1, $0.openedAt) < ($1.status == .open ? 0 : 1, $1.openedAt) }) {
            let who = l.direction == .mine ? "you promised" : "they promised"
            lines.append(l.status == .open ? "- ⏳ \(f.string(from: l.openedAt)) \(who): \(l.what)\(l.due.map { " · due \($0)" } ?? "")" : "- ✅ \(f.string(from: l.openedAt)) \(who): \(l.what) — \(l.closedHow ?? "done")")
        }
        guard !lines.isEmpty else { return "" }
        return open + "\n## Between you\n_Kept by Brownie from the chats and the loops ledger; updated every run. Not written by the brain._\n" + lines.joined(separator: "\n") + "\n" + close + "\n"
    }

    /// The note body with the block replaced (or inserted after the H1), unchanged when the block is the same.
    public static func upsert(into body: String, block: String) -> String {
        let trimmed = block.trimmingCharacters(in: .newlines)
        if let s = body.range(of: open), let e = body.range(of: close) {
            // the block plus the blank line after it, so removing leaves the note as it was
            var end = e.upperBound
            while end < body.endIndex, body[end] == "\n", body.distance(from: e.upperBound, to: end) < 2 { end = body.index(after: end) }
            let old = String(body[s.lowerBound..<e.upperBound])
            if trimmed.isEmpty { var b = body; b.removeSubrange(s.lowerBound..<end); return b }
            if old == trimmed { return body }
            var b = body; b.replaceSubrange(s.lowerBound..<e.upperBound, with: trimmed); return b
        }
        guard !trimmed.isEmpty else { return body }
        // right after the title line
        if body.hasPrefix("# "), let nl = body.firstIndex(of: "\n") {
            var b = body; b.insert(contentsOf: "\n" + trimmed + "\n", at: body.index(after: nl)); return b
        }
        return trimmed + "\n\n" + body
    }
}
