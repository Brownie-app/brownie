import Foundation
import Domain

/// The clock rules of a People or Groups note, in code and not in the brain: a Now bullet older than 45 days leaves
/// for Earlier as a clause on its month's line ("- 2026-07 — clause; clause", 240 characters at most, the oldest
/// clauses dropped first); Context keeps its twelve newest by date; Earlier keeps twelve months and nothing past a
/// year; and the dated one-liners of asks and promises that left the status block (`StatusBlock.retiredLines`, handed
/// in by the pipeline so Knowledge never imports Proactive) join the month they settled in, so a resolved ask leaves
/// a trace: "they asked … — you replied 16 Sep". A cap never drops: what is past it moves down (About to Context,
/// Now to Context, Context to Earlier — a "since" standing fact back up to About with its date) and only Earlier lets
/// go, saying so. Every rule takes `now`, so each is testable against a fixed clock, and every rule is idempotent for
/// the same `now`.
public enum NoteAging {
    public static let nowDays = 45, earlierDays = 365, earlierCap = 12, monthLineChars = 240

    /// The body with the rules applied, and what changed. Runs the note through the skeleton's parser, so a note
    /// that was never normalised is normalised on the way; a note already in shape and in date passes through unchanged.
    public static func age(body: String, kind: NoteMeta.Kind, now: Date, retired: [String] = [], timeZone: TimeZone = .current) -> (body: String, changes: [String]) {
        guard let (out, report) = pass(body: body, kind: kind, now: now, retired: retired, timeZone: timeZone) else { return (body, []) }
        return (out, out == body ? [] : report.changes)
    }

    /// The whole pass on one body — parse, settle, render — with the numbers behind it; nil for a kind the shape
    /// does not cover or a note carrying an unresolved sync conflict, both left exactly as they are.
    static func pass(body: String, kind: NoteMeta.Kind, now: Date, retired: [String], timeZone: TimeZone) -> (body: String, report: NoteSkeleton.Report)? {
        guard kind == .person || kind == .group else { return nil }
        var report = NoteSkeleton.Report()
        let parts = NoteSkeleton.parse(body, now: now, timeZone: timeZone, report: &report)
        guard !parts.conflict else { return nil }
        return (NoteSkeleton.render(settle(parts, now: now, timeZone: timeZone, retired: retired, report: &report)), report)
    }

    // MARK: the rules, on the pieces

    /// Every cap and clock rule at once, in the order that keeps them all true: About folded and its overflow sent to
    /// Context; Now sorted, its stale bullets folded into Earlier (a "since" is a standing state, so it goes to Context
    /// instead), its overflow to Context; Context sorted, its dated overflow to Earlier or — a "since" — to About;
    /// Earlier merged by month, the retired lines added, lines capped, old months let go. A comment, a table or the like
    /// that sat in a section is not a bullet: it neither counts toward a cap nor moves.
    static func settle(_ parts: NoteSkeleton.Parts, now: Date, timeZone: TimeZone, retired: [String], report: inout NoteSkeleton.Report) -> NoteSkeleton.Parts {
        var p = parts
        let window = NoteSkeleton.dateWindow(now: now, timeZone: timeZone)
        // About: standing facts in the order written, exact repeats folded; the facts past the cap go down to Context rather than away.
        var seen = Set<String>(), about: [NoteSkeleton.Item] = [], pastCap: [NoteSkeleton.Item] = [], facts = 0
        for it in p.about where seen.insert(it.rendered).inserted {
            if it.kind == .verbatim { about.append(it); continue }
            facts += 1
            if facts > NoteSkeleton.aboutCap { pastCap.append(it) } else { about.append(it) }
        }
        report.aboutToContext += pastCap.count
        p.about = about
        var toContext = pastCap.map { NoteSkeleton.dated($0, window: window, report: &report) }
        // Now: newest first; older than 45 days leaves; past the cap the rest go to Context.
        let staleBefore = NoteMeta.day(now.addingTimeInterval(-Double(nowDays) * 86400), timeZone)
        var now_: [NoteSkeleton.Bullet] = [], toEarlier: [NoteSkeleton.Bullet] = [], live = 0
        for b in NoteSkeleton.tidy(p.now) {
            if b.verbatim { now_.append(b); continue }
            if let d = b.day, d < staleBefore { if b.since { toContext.append(b) } else { toEarlier.append(b) }; continue }
            live += 1
            if live > NoteSkeleton.nowCap { toContext.append(b) } else { now_.append(b) }
        }
        report.movedToContext += toContext.count - pastCap.count
        p.now = now_
        // Context: newest first, the twelve newest dated bullets kept; past the cap a "since" is a standing fact and goes
        // to About with its date, any other dated bullet goes to Earlier as a clause on its month; an unclear bullet has
        // no month to go to and stays.
        var context: [NoteSkeleton.Bullet] = [], toAbout: [NoteSkeleton.Bullet] = [], dated = 0
        for b in NoteSkeleton.tidy(p.context + toContext) {
            guard b.day != nil else { context.append(b); continue }
            dated += 1
            if dated <= NoteSkeleton.contextCap { context.append(b) } else if b.since { toAbout.append(b) } else { toEarlier.append(b) }
        }
        p.context = context
        report.movedToAbout += toAbout.count
        p.about += toAbout.sorted { ($0.sortKey, $0.text) < ($1.sortKey, $1.text) }.map(\.asAbout)
        report.movedToEarlier += toEarlier.count
        // Earlier: one line per month, the moved bullets oldest first so a line reads in order, then the retired lines.
        var months: [String: [String]] = [:], order: [String] = []
        // A clause is already on its line when it reads there whole — a clause that itself holds "; " was split on the way back in.
        func holds(_ month: String, _ c: String) -> Bool { ("; " + (months[month] ?? []).joined(separator: "; ") + "; ").contains("; " + c + "; ") }
        func add(_ month: String, _ clause: String) {
            let c = clause.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty else { return }
            if months[month] == nil { order.append(month) }
            if !holds(month, c) { months[month, default: []].append(c) }
        }
        for line in p.earlier { for c in line.clauses { add(line.month, c) } }
        for b in toEarlier.sorted(by: { ($0.sortKey, $0.text) < ($1.sortKey, $1.text) }) { add(String(b.day!.prefix(7)), b.clause) }
        for line in retired {
            guard let (month, clause) = retiredClause(line, now: now, timeZone: timeZone) else { continue }
            if !holds(month, clause) { report.retired += 1 }
            add(month, clause)
        }
        let floorMonth = String(NoteMeta.day(now.addingTimeInterval(-Double(earlierDays) * 86400), timeZone).prefix(7))
        var lines = order.map { month -> NoteSkeleton.MonthLine in
            let (kept, dropped) = capped(months[month] ?? [], month: month)
            report.droppedClauses += dropped
            return NoteSkeleton.MonthLine(month: month, clauses: kept)
        }.sorted { $0.month > $1.month }
        let before = lines.count
        lines = Array(lines.filter { $0.month >= floorMonth }.prefix(earlierCap))
        report.droppedEarlier += before - lines.count
        p.earlier = lines
        return p
    }

    /// A month line stays under 240 characters: the oldest clauses go first; a lone clause too long is cut with an
    /// ellipsis. With the clauses, how many were let go (a cut one counts).
    static func capped(_ clauses: [String], month: String) -> (clauses: [String], dropped: Int) {
        var cs = clauses, dropped = 0
        func length() -> Int { NoteSkeleton.MonthLine(month: month, clauses: cs).rendered.count }
        while length() > monthLineChars, cs.count > 1 { cs.removeFirst(); dropped += 1 }
        if length() > monthLineChars, let only = cs.first {
            let room = monthLineChars - (length() - only.count) - 1
            cs = [String(only.prefix(max(0, room))) + "…"]; dropped += 1
        }
        return (cs, dropped)
    }

    /// A status-block line that left the note ("- ✅ 2 Sep — they asked: “…” — you replied 16 Sep 14:00") as the month it
    /// settled in and the clause to keep: the bullet mark, the icon, the leading date and the "(not checked)" aside go;
    /// the month is that of the last "d MMM" in the line, read against now's year (the year before when that is ahead of
    /// today), and this month when the line carries no date at all.
    static func retiredClause(_ line: String, now: Date, timeZone: TimeZone) -> (month: String, clause: String)? {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("- ") { s.removeFirst(2) }
        s = s.replacingOccurrences(of: "_(not checked)_", with: "")
        s = String(s.drop { $0.isWhitespace || "✅⌛⏳✓✗•".contains($0) }).trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "d MMM yyyy"
        let year = cal.component(.year, from: now)
        var month = String(NoteMeta.day(now, timeZone).prefix(7))
        let ns = s as NSString
        let found = NoteSkeleton.dayMonth.matches(in: s, range: NSRange(location: 0, length: ns.length))
        if let last = found.last, var date = f.date(from: ns.substring(with: last.range) + " \(year)") {
            if date > now, let back = cal.date(byAdding: .year, value: -1, to: date) { date = back }
            month = String(NoteMeta.day(date, timeZone).prefix(7))
        }
        // "2 Sep — they asked…" reads better on a month line without the day that opened it
        if let first = found.first, first.range.location == 0 {
            let after = ns.substring(from: first.range.length).trimmingCharacters(in: .whitespaces)
            if after.hasPrefix("—") || after.hasPrefix("–") || after.hasPrefix("-") { s = String(after.dropFirst()).trimmingCharacters(in: .whitespaces) }
        }
        return (month, s.replacingOccurrences(of: "\n", with: " "))
    }
}
