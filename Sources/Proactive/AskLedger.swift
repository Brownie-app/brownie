import Foundation
import Domain

/// The asks ledger: what people asked the user in direct chats, and when the user answered. Local only.
public enum AskLedger {
    /// An ask is let go after this long with no answer, and no chat is ever read further back than this for one.
    public static let horizon: TimeInterval = StatusRules.askLapse
    /// An ask stays in the ledger this long after it was asked, so one that was answered or let go is remembered — not found again as new.
    public static let retention: TimeInterval = 90 * 86400

    /// New scans replace what they cover (an answer can arrive later); asks that waited too long are let go; old asks fall off after the retention.
    /// A fresh scan always brings the newest window. An ask already settled keeps its verdict and everything the verdict
    /// rests on — a later read never reopens it; the same person asking again is a new ask. One still open keeps a
    /// judgement made about the very same exchange, and is judged afresh when there is more to read.
    public static func merge(existing: [Ask], found: [Ask], now: Date) -> [Ask] {
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for f in found {
            var f = f
            if let old = byID[f.id] {
                if old.isSettled {
                    f.answeredAt = old.answeredAt; f.reply = old.reply; f.addressed = old.addressed
                    f.outcome = old.outcome; f.outcomeAt = old.outcomeAt; f.outcomeBy = old.outcomeBy; f.outcomeHow = old.outcomeHow
                } else {
                    if old.window == f.window, old.answeredAt == f.answeredAt, old.reply == f.reply {
                        f.addressed = old.addressed; f.outcome = old.outcome; f.outcomeAt = old.outcomeAt; f.outcomeBy = old.outcomeBy; f.outcomeHow = old.outcomeHow
                    }
                    // let go stays let go — unless a reply finally came
                    if f.answeredAt == nil { f.lapsedAt = old.lapsedAt }
                }
            }
            byID[f.id] = f
        }
        let kept = byID.values.filter { now.timeIntervalSince($0.askedAt) < retention }
        return StatusRules.lapse(asks: kept, now: now).sorted { ($1.askedAt, $0.id) < ($0.askedAt, $1.id) }
    }

    /// The judge's word that an open ask was answered somewhere else — a Slack summary showing the user sent the URL
    /// that was asked for on WhatsApp. The ask closes as answered, dated tonight, with the judge's few words on where.
    /// Only an open ask: the judge can close, never reopen, and an ask let go stays let go. The id is matched leniently
    /// — with or without its "ask-" prefix, or cut short — since the judge writes it back by hand.
    public static func apply(updates: [(idPrefix: String, how: String)], to asks: [Ask], now: Date) -> [Ask] {
        var out = asks
        for u in updates {
            var key = u.idPrefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            for p in ["ask-", "ask "] where key.hasPrefix(p) { key = String(key.dropFirst(p.count)) }
            guard key.count >= 4, let i = out.firstIndex(where: { $0.isOpen && $0.id.dropFirst(4).hasPrefix(key) }) else { continue }
            let how = String(u.how.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))).prefix(80))
            out[i].settle(.answered, at: now, by: "judge", how: how.isEmpty ? nil : how)
            if out[i].answeredAt == nil { out[i].answeredAt = now }
        }
        return out
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
    /// Loops the user owed someone that their reply settled: a `mine` loop about answering that person, opened before the
    /// reply. Only an ask the user's own reply in the chat settled: not one closed on their word or the judge's, where
    /// "you replied" would not be true.
    public static func closures(loops: [Loop], asks: [Ask], now: Date) -> [Loop] {
        loops.map { l in
            guard l.status == .open, l.direction == .mine, answering.contains(where: { l.what.lowercased().contains($0) }) else { return l }
            guard let a = asks.first(where: { a in a.isAnswered && a.byReply && samePerson(a.person, l.person) && a.askedAt <= l.openedAt && StatusRules.settledAt(a).map { l.openedAt <= $0 } == true }) else { return l }
            var l = l; l.status = .closed; l.closedAt = StatusRules.settledAt(a); l.closedHow = "you replied"; l.closedBy = "reply"
            return l
        }
    }

    /// Loops that the asks they came from settled: an open loop with the same person whose `what` shares half its
    /// words with a settled ask's question — the judge opened "Send Nitesh the estimates" the night Nitesh asked for
    /// them, and the night the ask closes (the user sent them, Nitesh said he has them, or the judge saw them sent on
    /// Slack) the loop goes with it, once. A loop opened more than a day after the ask settled is newer news and stays.
    public static func followers(loops: [Loop], asks: [Ask], now: Date) -> [Loop] {
        loops.map { l in
            guard l.status == .open else { return l }
            guard let a = asks.first(where: { a in a.isSettled && samePerson(a.person, l.person) && StatusRules.settledAt(a).map { l.openedAt <= $0 + 86400 } == true && overlap(a.question, l.what) >= 0.5 }) else { return l }
            var l = l; l.status = .closed; l.closedAt = StatusRules.settledAt(a) ?? now; l.closedHow = "the ask it came from was answered"; l.closedBy = "ask"
            return l
        }
    }
    /// The share of the question's words a promise carries, with the ledger's own words and a little stemming ("estimate" ~ "estimates").
    static func overlap(_ question: String, _ what: String) -> Double {
        let q = LoopLedger.words(question), w = LoopLedger.words(what)
        guard !q.isEmpty, !w.isEmpty else { return 0 }
        let shared = q.filter { qw in w.contains { $0 == qw || $0.hasPrefix(qw) || qw.hasPrefix($0) } }
        return Double(shared.count) / Double(min(q.count, w.count))
    }

    /// What the judge is told — dates only, never the words. Each open ask carries its id, so the judge can say in
    /// `ask_updates` that the summaries show it answered somewhere else. An ask let go is said to be let go, never
    /// "no reply yet", and loops let go are listed so the judge neither reports them nor finds them again.
    public static func judgeLines(_ asks: [Ask], loops: [Loop] = [], now: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"
        let open = asks.filter(\.isOpen)
        let answered = asks.filter { $0.isAnswered && StatusRules.isShown(settledAt: StatusRules.settledAt($0), now: now) }
        let lapsed = asks.filter { $0.isLapsed && StatusRules.isShown(settledAt: $0.lapsedAt, now: now) }
        var out = ""
        if !asks.isEmpty {
            var lines: [String] = []
            for a in open.prefix(20) {
                let head = "- ask \(a.id) · \(a.person) asked the user something on \(f.string(from: a.askedAt))"
                if a.outcome == .promised { lines.append(head + " · the user said they would get to it (\(f.string(from: a.outcomeAt ?? a.answeredAt ?? a.askedAt))) — still open (\(when(a.askedAt, now: now)))") }
                else if let r = a.answeredAt { lines.append(head + " · the user wrote at \(f.string(from: r)) but NOT about it — still unanswered (\(when(a.askedAt, now: now)))") }
                else { lines.append(head + " · NO REPLY YET (\(when(a.askedAt, now: now)))") }
            }
            for a in answered.prefix(20) {
                let head = "- \(a.person) asked the user something on \(f.string(from: a.askedAt))", at = f.string(from: StatusRules.settledAt(a) ?? a.askedAt)
                switch a.outcome {
                case .confirmedByThem: lines.append(head + " · they said it is settled \(at) — done")
                case .declined: lines.append(head + " · the user said no \(at) — done")
                case .answered where a.outcomeBy == "judge": lines.append(head + " · answered \(a.outcomeHow ?? "elsewhere") \(at) — done")
                default: lines.append(head + " · the user replied \(at) — done")
                }
            }
            for a in lapsed.prefix(20) { lines.append("- \(a.person) asked the user something on \(f.string(from: a.askedAt)) · LAPSED — no reply in \(StatusRules.askLapseDays) days; Brownie let it go, do not make an item for it") }
            if !lines.isEmpty { out += "ASKS IN DIRECT CHATS (read from the chats themselves; a reply means it is answered — do not make an item to answer or update that person again unless they wrote after the reply; an OPEN one the summaries plainly show the user answered somewhere else goes in ask_updates by its id):\n" + lines.joined(separator: "\n") + "\n" }
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

    /// Open asks that have waited the full term are let go, dated now — a promise to get to it counts from the asking, like no reply. Nothing else changes.
    public static func lapse(asks: [Ask], now: Date) -> [Ask] {
        asks.map { a in
            guard a.isOpen, now.timeIntervalSince(a.askedAt) >= askLapse else { return a }
            var a = a; a.lapsedAt = now; return a
        }
    }
    /// An open loop nobody touched — no card fired, never came back — is let go 90 days after its last news: the day it
    /// was opened or the night Brownie learned of it, whichever is later (a promise from an old recording read late is
    /// news from that night, not born lapsed), or its due date when it has one, so a dated loop is never let go before its date.
    public static func lapse(loops: [Loop], now: Date) -> [Loop] {
        loops.map { l in
            guard l.status == .open, l.firedCardIDs.isEmpty, l.cameBackCount == 0 else { return l }
            let lastNews = max(max(l.openedAt, l.noticedAt ?? l.openedAt), l.dueDate ?? l.openedAt)
            guard now.timeIntervalSince(lastNews) >= loopLapse else { return l }
            var l = l; l.status = .lapsed; l.lapsedAt = now; l.closedAt = now; l.closedBy = "lapsed"; return l
        }
    }

    /// The moment an item settled — answered, closed or let go. Nil while it is still open. For an ask, the line that
    /// decided it (their receipt, the user's refusal, the judge's night) — or, from before there were verdicts, the reply.
    public static func settledAt(_ a: Ask) -> Date? { a.isAnswered ? (a.outcomeAt ?? a.answeredAt) : a.lapsedAt }
    public static func settledAt(_ l: Loop) -> Date? {
        switch l.status {
        case .open: return nil
        case .lapsed: return l.lapsedAt ?? l.closedAt ?? l.openedAt
        case .closed, .dismissed: return l.closedAt ?? l.openedAt
        }
    }
    /// On the note: still open, or settled less than `shownFor` ago.
    public static func isShown(settledAt: Date?, now: Date) -> Bool { settledAt.map { now.timeIntervalSince($0) < shownFor } ?? true }
    /// How long a line that has left the block is still handed to the gardener: a fortnight, not one night. The gardener
    /// runs only on a night with something to sync, and a Mac closed on the one night a line fell due would lose its trace
    /// for good; a line offered on every night of a fortnight lands once, because the gardener keeps each clause once.
    public static let retiredFor: TimeInterval = 14 * 86400
    /// Left the note lately: settled between 14 and 28 days ago.
    public static func leftLately(settledAt: Date?, now: Date) -> Bool {
        guard let s = settledAt else { return false }
        let age = now.timeIntervalSince(s); return age >= shownFor && age < shownFor + retiredFor
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

    /// The dated line of every item that left the block in the last fortnight — for a gardener to keep under the note's
    /// Earlier section, which holds each clause once however many nights it is offered.
    public static func retiredLines(person: String, asks: [Ask], loops: [Loop], now: Date, timeZone: TimeZone = .current, routed: Bool = false) -> [String] {
        entries(person: person, asks: asks, loops: loops, timeZone: timeZone, routed: routed).filter { StatusRules.leftLately(settledAt: $0.settledAt, now: now) }.map(\.line)
    }
    /// The same for asks and loops already routed to one note (the registry chose them, by handle first, then by the
    /// full label): no name is re-checked here, so a handle match under another chat name keeps its trace and a bare
    /// first name the registry could pin on nobody is nobody's.
    public static func retiredLines(asks: [Ask], loops: [Loop], now: Date, timeZone: TimeZone = .current) -> [String] {
        retiredLines(person: "", asks: asks, loops: loops, now: now, timeZone: timeZone, routed: true)
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
            if a.isAnswered {
                let at = StatusRules.settledAt(a) ?? a.askedAt
                switch a.outcome {
                case .confirmedByThem: line = head("✅") + "they said it's done, \(day.string(from: at))"
                case .declined: line = head("✅") + "you said no, \(day.string(from: at))"
                case .answered where a.outcomeBy == "judge": line = head("✅") + "answered \(a.outcomeHow ?? "elsewhere"), \(day.string(from: at)) (the judge)"
                default: line = head("✅") + "you replied \(time.string(from: at))" + (a.addressed == nil ? " _(not checked)_" : "")
                }
            }
            else if let gone = a.lapsedAt {
                let why = a.outcome == .promised ? "you said you would, \(day.string(from: a.outcomeAt ?? a.answeredAt ?? gone))"
                    : a.answeredAt.map { "you wrote \(time.string(from: $0)) but not about this" } ?? "no reply in \(StatusRules.askLapseDays) days"
                line = head("⌛") + why + "; no longer tracked (lapsed \(day.string(from: gone)))"
            }
            else if a.outcome == .promised { line = head("⏳") + "you said you would, \(day.string(from: a.outcomeAt ?? a.answeredAt ?? a.askedAt)); still open" }
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
    /// A block under the old markers is replaced too, which is how a note migrates. `NoteStatus` does the work, so
    /// what goes in here is exactly what `NoteStatus.strip` takes out and the hash never sees a difference.
    public static func upsert(into body: String, block: String) -> String { NoteStatus.upsert(block, into: body) }
}
