import Foundation
import Domain

/// The asks ledger: what people asked the user in direct chats, and when the user answered. Local only.
public enum AskLedger {
    /// An ask is let go after this long with no answer, and no chat is ever read further back than this for one.
    public static let horizon: TimeInterval = StatusRules.askLapse
    /// An ask stays in the ledger this long after it was asked, so one that was answered or let go is remembered — not found again as new.
    public static let retention: TimeInterval = 90 * 86400

    /// New scans replace what they cover (an answer can arrive later); asks that waited too long are let go; old asks fall off after the retention.
    public static func merge(existing: [Ask], found: [Ask], now: Date) -> [Ask] {
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for f in found {
            var f = f
            if let old = byID[f.id] {
                // a fresh scan brings the reply; the judgement already made about that same reply is kept, a different reply is judged afresh
                if old.answeredAt == f.answeredAt, old.reply == f.reply { f.addressed = old.addressed }
                // let go stays let go — unless a reply finally came
                if f.answeredAt == nil { f.lapsedAt = old.lapsedAt }
            }
            byID[f.id] = f
        }
        let kept = byID.values.filter { now.timeIntervalSince($0.askedAt) < retention }
        return StatusRules.lapse(asks: kept, now: now).sorted { ($1.askedAt, $0.id) < ($0.askedAt, $1.id) }
    }

    /// How far back one source's chats are read for asks: to the oldest ask from it still waiting, an hour earlier so the
    /// question is seen again and its reply paired with it — never less than three days, never past the horizon.
    /// So a question answered on day four is found on day four, not listed as unanswered for six weeks.
    public static func scanSince(open: [Ask], now: Date) -> Date {
        let floor = now.addingTimeInterval(-horizon), recent = now.addingTimeInterval(-3 * 86400)
        guard let oldest = open.filter(\.isOpen).map(\.askedAt).min() else { return recent }
        return max(floor, min(recent, oldest.addingTimeInterval(-3600)))
    }
    /// The night's scan, from the ledger: every chat is read three days back, except that a chat with an ask still
    /// waiting is read back to that ask — its own, not the source's oldest — and an ask whose reply was judged to be
    /// about something else names that reply, so the scan pairs it with the user's next message instead.
    public static func scan(existing: [Ask], now: Date) -> AskScan {
        let open = existing.filter(\.isOpen)
        let byBucket = Dictionary(grouping: open, by: \.bucket).mapValues { scanSince(open: $0, now: now) }
        let judged = Dictionary(open.filter { $0.addressed == false }.compactMap { a in a.answeredAt.map { (a.id, $0) } }, uniquingKeysWith: { a, _ in a })
        return AskScan(since: scanSince(open: [], now: now), sinceByBucket: byBucket, judgedReplies: judged)
    }

    static let answering = ["answer", "reply", "respond", "get back", "question", "guidance", "tell", "let", "confirm", "share", "send"]
    /// Loops the user owed someone that their reply settled: a `mine` loop about answering that person, opened before the reply.
    public static func closures(loops: [Loop], asks: [Ask], now: Date) -> [Loop] {
        loops.map { l in
            guard l.status == .open, l.direction == .mine, answering.contains(where: { l.what.lowercased().contains($0) }) else { return l }
            guard let a = asks.first(where: { $0.isAnswered && samePerson($0.person, l.person) && $0.askedAt <= l.openedAt && l.openedAt <= $0.answeredAt! }) else { return l }
            var l = l; l.status = .closed; l.closedAt = a.answeredAt; l.closedHow = "you replied"; l.closedBy = "reply"
            return l
        }
    }

    /// What the judge is told — dates only, never the words. An ask let go is said to be let go, never "no reply yet",
    /// and loops let go are listed so the judge neither reports them nor finds them again.
    public static func judgeLines(_ asks: [Ask], loops: [Loop] = [], now: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"
        let open = asks.filter(\.isOpen)
        let answered = asks.filter { $0.isAnswered && StatusRules.isShown(settledAt: $0.answeredAt, now: now) }
        let lapsed = asks.filter { $0.isLapsed && StatusRules.isShown(settledAt: $0.lapsedAt, now: now) }
        var out = ""
        if !asks.isEmpty {
            var lines: [String] = []
            for a in open.prefix(20) {
                if let r = a.answeredAt { lines.append("- \(a.person) asked the user something on \(f.string(from: a.askedAt)) · the user wrote at \(f.string(from: r)) but NOT about it — still unanswered (\(when(a.askedAt, now: now)))") }
                else { lines.append("- \(a.person) asked the user something on \(f.string(from: a.askedAt)) · NO REPLY YET (\(when(a.askedAt, now: now)))") }
            }
            for a in answered.prefix(20) { lines.append("- \(a.person) asked the user something on \(f.string(from: a.askedAt)) · the user replied \(f.string(from: a.answeredAt!)) — done") }
            for a in lapsed.prefix(20) { lines.append("- \(a.person) asked the user something on \(f.string(from: a.askedAt)) · LAPSED — no reply in \(StatusRules.askLapseDays) days; Brownie let it go, do not make an item for it") }
            if !lines.isEmpty { out += "ASKS IN DIRECT CHATS (read from the chats themselves; a reply means it is answered — do not make an item to answer or update that person again unless they wrote after the reply):\n" + lines.joined(separator: "\n") + "\n" }
        }
        let letGo = loops.filter { $0.status == .lapsed && StatusRules.isShown(settledAt: StatusRules.settledAt($0), now: now) }
        if !letGo.isEmpty {
            out += "LOOPS LET GO (open \(StatusRules.loopLapseDays) days with no news, so no longer tracked — do not report them, and do not open them again):\n"
                + letGo.prefix(20).map { "- loop \($0.id.prefix(8)) · \($0.direction == .mine ? "the user → \($0.person)" : "\($0.person) → the user") · \($0.what) · let go" }.joined(separator: "\n") + "\n"
        }
        return out
    }

    public static func samePerson(_ a: String, _ b: String) -> Bool { PersonKey.same(a, b) }
    static func when(_ d: Date, now: Date) -> String {
        let s = now.timeIntervalSince(d)
        if s < 3600 { return "\(max(1, Int(s / 60))) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) h ago" }
        let days = Int(s / 86400); return days == 1 ? "yesterday" : "\(days) days ago"
    }
}

/// The clock rules of the status block, in code and not in the brain: when an ask or a loop is let go, and how long
/// a settled item stays on the note before it leaves. Every rule takes `now`, so each is testable against a fixed clock.
public enum StatusRules {
    /// A question with no answer for this long is let go.
    public static let askLapse: TimeInterval = 45 * 86400
    /// An open loop with no news for this long is let go.
    public static let loopLapse: TimeInterval = 90 * 86400
    /// An answered, closed or let-go item stays on the note this long, then leaves.
    public static let shownFor: TimeInterval = 14 * 86400
    static var askLapseDays: Int { Int(askLapse / 86400) }
    static var loopLapseDays: Int { Int(loopLapse / 86400) }

    /// Open asks that have waited the full term are let go, dated now. Nothing else changes.
    public static func lapse(asks: [Ask], now: Date) -> [Ask] {
        asks.map { a in
            guard a.isOpen, now.timeIntervalSince(a.askedAt) >= askLapse else { return a }
            var a = a; a.lapsedAt = now; return a
        }
    }
    /// An open loop nobody touched — no card fired, never came back — is let go 90 days after its last news: the day it
    /// was opened, or its due date when it has one, so a dated loop is never let go before its date.
    public static func lapse(loops: [Loop], now: Date) -> [Loop] {
        loops.map { l in
            guard l.status == .open, l.firedCardIDs.isEmpty, l.cameBackCount == 0 else { return l }
            let lastNews = max(l.openedAt, l.dueDate ?? l.openedAt)
            guard now.timeIntervalSince(lastNews) >= loopLapse else { return l }
            var l = l; l.status = .lapsed; l.lapsedAt = now; l.closedAt = now; l.closedBy = "lapsed"; return l
        }
    }

    /// The moment an item settled — answered, closed or let go. Nil while it is still open.
    public static func settledAt(_ a: Ask) -> Date? { a.isAnswered ? a.answeredAt : a.lapsedAt }
    public static func settledAt(_ l: Loop) -> Date? {
        switch l.status {
        case .open: return nil
        case .lapsed: return l.lapsedAt ?? l.closedAt ?? l.openedAt
        case .closed, .dismissed: return l.closedAt ?? l.openedAt
        }
    }
    /// On the note: still open, or settled less than `shownFor` ago.
    public static func isShown(settledAt: Date?, now: Date) -> Bool { settledAt.map { now.timeIntervalSince($0) < shownFor } ?? true }
    /// Left the note within the last day: settled between 14 and 15 days ago.
    public static func leftToday(settledAt: Date?, now: Date) -> Bool {
        guard let s = settledAt else { return false }
        let age = now.timeIntervalSince(s); return age >= shownFor && age < shownFor + 86400
    }
}

/// The block Brownie writes at the top of a person's note — the plain record of what's between you, from the ledgers,
/// not the brain. Every date is absolute, so the block reads the same on any day and the note is only rewritten when
/// something actually changed.
public enum StatusBlock {
    public static let open = "<!-- brownie:status -->", close = "<!-- /brownie:status -->"
    /// The markers the block carried before it was renamed; a note still holding them is migrated on its next write.
    public static let legacyOpen = "<!-- brownie:between-you -->", legacyClose = "<!-- /brownie:between-you -->"
    static let heading = "## Between you", note = "_Kept by Brownie from the chats and the loops ledger. Not written by the brain._"

    /// One item on the note: its line, and when it settled (nil while open).
    struct Entry { let line: String; let settledAt: Date? }

    /// `routed`: the caller already chose these asks and loops for this note (the registry did), so no name filter is applied here —
    /// a handle match under a wholly different chat name, or a merge the user made, must not be dropped by a name check.
    public static func render(person: String, asks: [Ask], loops: [Loop], now: Date, timeZone: TimeZone = .current, routed: Bool = false) -> String {
        let lines = entries(person: person, asks: asks, loops: loops, timeZone: timeZone, routed: routed).filter { StatusRules.isShown(settledAt: $0.settledAt, now: now) }.map(\.line)
        guard !lines.isEmpty else { return "" }
        return open + "\n" + heading + "\n" + note + "\n" + lines.joined(separator: "\n") + "\n" + close + "\n"
    }

    /// The dated line of every item that left the block in the last day — for a gardener to keep under the note's Earlier section.
    public static func retiredLines(person: String, asks: [Ask], loops: [Loop], now: Date, timeZone: TimeZone = .current, routed: Bool = false) -> [String] {
        entries(person: person, asks: asks, loops: loops, timeZone: timeZone, routed: routed).filter { StatusRules.leftToday(settledAt: $0.settledAt, now: now) }.map(\.line)
    }

    /// This person's asks (newest first, at most eight) then loops (open first, oldest first). Order is total, so two
    /// runs over the same ledgers give the same bytes.
    static func entries(person: String, asks: [Ask], loops: [Loop], timeZone: TimeZone, routed: Bool = false) -> [Entry] {
        let day = DateFormatter(), time = DateFormatter()
        for f in [day, time] { f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone }
        day.dateFormat = "d MMM"; time.dateFormat = "d MMM HH:mm"
        let theirAsks = asks.filter { routed || AskLedger.samePerson($0.person, person) }.sorted { ($1.askedAt, $0.id) < ($0.askedAt, $1.id) }.prefix(8)
        let theirLoops = loops.filter { (routed || AskLedger.samePerson($0.person, person)) && $0.status != .dismissed }
            .sorted { ($0.status == .open ? 0 : 1, $0.openedAt, $0.id) < ($1.status == .open ? 0 : 1, $1.openedAt, $1.id) }
        var out: [Entry] = []
        for a in theirAsks {
            func head(_ icon: String) -> String { "- \(icon) \(day.string(from: a.askedAt)) — they asked: “\(a.question.replacingOccurrences(of: "\n", with: " "))” — " }
            let line: String
            if a.isAnswered { line = head("✅") + "you replied \(time.string(from: a.answeredAt!))" + (a.addressed == nil ? " _(not checked)_" : "") }
            else if let gone = a.lapsedAt {
                let why = a.answeredAt.map { "you wrote \(time.string(from: $0)) but not about this" } ?? "no reply in \(StatusRules.askLapseDays) days"
                line = head("⌛") + why + "; no longer tracked (lapsed \(day.string(from: gone)))"
            }
            else if let r = a.answeredAt { line = head("⏳") + "you wrote \(time.string(from: r)) but not about this; still open" }
            else { line = head("⏳") + "no reply yet" }
            out.append(Entry(line: line, settledAt: StatusRules.settledAt(a)))
        }
        for l in theirLoops {
            func head(_ icon: String) -> String { "- \(icon) \(l.direction == .mine ? "you promised" : "they promised") (\(day.string(from: l.openedAt))): \(l.what)" }
            let line: String
            switch l.status {
            case .open: line = head("⏳") + (l.due.map { " · due \($0)" } ?? "")
            case .lapsed: line = head("⌛") + " — no news in \(StatusRules.loopLapseDays) days; no longer tracked (lapsed \(day.string(from: StatusRules.settledAt(l)!)))"
            case .closed, .dismissed: line = head("✅") + " — done \(day.string(from: StatusRules.settledAt(l)!))" + (l.closedHow.map { " (\($0))" } ?? "")
            }
            out.append(Entry(line: line, settledAt: StatusRules.settledAt(l)))
        }
        return out
    }

    /// The note body with the block replaced (or inserted after the H1), unchanged when the block is the same.
    /// A block under the old markers is replaced too, which is how a note migrates.
    public static func upsert(into body: String, block: String) -> String {
        let trimmed = block.trimmingCharacters(in: .newlines)
        for (o, c) in [(open, close), (legacyOpen, legacyClose)] {
            guard let s = body.range(of: o), let e = body.range(of: c), s.lowerBound < e.lowerBound else { continue }
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
