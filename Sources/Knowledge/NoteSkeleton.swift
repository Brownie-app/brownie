import Foundation
import Domain

/// The fixed shape of a People or Groups note, so a year of nights cannot bloat or stale one: the title, the status
/// block (Proactive's, byte for byte, right under the title), then `## About` (standing facts, undated), `## Now`
/// (dated bullets — what the cards are made from), `## Context` (dated bullets that are no longer news) and
/// `## Earlier` (one line per calendar month, newest first). The brain writes prose into that shape; this is the code
/// that puts a note back into it when the brain, the user or an older builder wrote something else: a "Pending" list
/// becomes Now, an unknown heading's bullets become Context and its paragraphs About, every Now and Context bullet
/// ends with `(YYYY-MM-DD)`, `(since YYYY-MM-DD)` or `(date unclear)`. The time rules (what leaves Now, what
/// Earlier forgets) live in `NoteAging` and are applied here too, so a normalised note holds every invariant at once.
/// Idempotent for the same `now`: a normalised note passes through unchanged.
public enum NoteSkeleton {
    public static let aboutCap = 20, nowCap = 6, contextCap = 12
    public static let unclear = "(date unclear)"
    static let aboutHeading = "## About", nowHeading = "## Now", contextHeading = "## Context", earlierHeading = "## Earlier"
    /// A sync conflict the user has not resolved is left exactly as it is: folding both versions together would hide the choice.
    static let conflictHeading = "## Brownie's version ("

    // MARK: the pieces

    /// One dated bullet: its text without the date, the day it names (nil when unclear), and whether it is a "since".
    struct Bullet: Equatable {
        var text: String
        var day: String?
        var since = false
        var rendered: String { "- " + text + " " + (day.map { since ? "(since \($0))" : "(\($0))" } ?? NoteSkeleton.unclear) }
        /// Newest first; an unclear date sorts last.
        var sortKey: String { day ?? "0000-00-00" }
    }
    /// One Earlier line: "- YYYY-MM — clause; clause".
    struct MonthLine: Equatable {
        var month: String
        var clauses: [String]
        var rendered: String { "- \(month) — " + clauses.joined(separator: "; ") }
    }
    /// The note taken apart. `folded` names the headings that were not the four, for the change log.
    struct Parts: Equatable {
        var title: String?
        var status: String?
        var about: [String] = [], now: [Bullet] = [], context: [Bullet] = [], earlier: [MonthLine] = []
        var folded: [String] = []
        var conflict = false
    }
    /// What one pass did, in numbers; `changes` says it in words.
    struct Report: Equatable {
        var folded: [String] = []
        var dated = 0, unclear = 0, impossible = 0
        var movedToEarlier = 0, movedToContext = 0, retired = 0
        var droppedAbout = 0, droppedContext = 0, droppedEarlier = 0
        /// The counted changes in words; a body that changed with nothing to count (sections put in order) says so.
        var changes: [String] { counted.isEmpty ? ["put in shape"] : counted }
        var counted: [String] {
            var out: [String] = []
            if !folded.isEmpty { out.append("folded " + folded.map { "‘\($0)’" }.joined(separator: ", ")) }
            if dated > 0 { out.append("\(dated) bullet\(dated == 1 ? "" : "s") dated") }
            if unclear > 0 { out.append("\(unclear) bullet\(unclear == 1 ? "" : "s") marked date unclear") }
            if impossible > 0 { out.append("\(impossible) impossible date\(impossible == 1 ? "" : "s") marked unclear") }
            if movedToEarlier > 0 { out.append("\(movedToEarlier) bullet\(movedToEarlier == 1 ? "" : "s") moved to Earlier") }
            if movedToContext > 0 { out.append("\(movedToContext) bullet\(movedToContext == 1 ? "" : "s") moved to Context") }
            if retired > 0 { out.append("\(retired) retired line\(retired == 1 ? "" : "s") kept under Earlier") }
            if droppedAbout > 0 { out.append("\(droppedAbout) About bullet\(droppedAbout == 1 ? "" : "s") past the cap dropped") }
            if droppedContext > 0 { out.append("\(droppedContext) Context bullet\(droppedContext == 1 ? "" : "s") past the cap dropped") }
            if droppedEarlier > 0 { out.append("\(droppedEarlier) Earlier line\(droppedEarlier == 1 ? "" : "s") let go") }
            return out
        }
    }

    // MARK: normalise

    /// The body in the fixed shape, and what changed. A topic or the portrait is returned as it is; so is a note
    /// carrying an unresolved sync conflict.
    public static func normalize(body: String, kind: NoteMeta.Kind, now: Date, timeZone: TimeZone = .current) -> (body: String, changes: [String]) {
        guard let (out, report) = NoteAging.pass(body: body, kind: kind, now: now, retired: [], timeZone: timeZone) else { return (body, []) }
        return (out, out == body ? [] : report.changes)
    }

    // MARK: parse

    enum Section { case preamble, about, now, context, earlier, unknown }

    /// Which of the four a heading means. The old builder wrote "Pending", "Pending and commitments", "Open items",
    /// "Recent", "Background" and the like; each lands where its content belongs.
    static func classify(_ heading: String) -> Section {
        let h = heading.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ":.-"))
        if h == "about" || h.hasPrefix("about ") || h == "who" || h.hasPrefix("who ") || h.contains("background") || h.contains("profile") || h.contains("relationship")
            || h.contains("basics") || h.contains("overview") || h.contains("members") || h.contains("what the group is") || h.contains("standing") { return .about }
        if h == "now" || h.contains("pending") || h == "open" || h.hasPrefix("open ") || h.contains("commitment") || h.contains("waiting") || h.contains("outstanding")
            || h.contains("upcoming") || h.contains("to do") || h.contains("todo") || h.contains("next step") || h == "asks" || h == "promises" || h.contains("asks and promises") || h.contains("requests") { return .now }
        if h.hasPrefix("context") || h.hasPrefix("recent") || h.contains("timeline") || h.contains("history") || h.contains("dated") || h == "facts" || h == "notes"
            || h.contains("update") || h.contains("activity") || h.contains("going on") || h.contains("plan") { return .context }
        if h.hasPrefix("earlier") || h.hasPrefix("older") || h == "past" || h.hasPrefix("previous") || h.hasPrefix("archive") { return .earlier }
        return .unknown
    }

    struct Item { let text: String; let isBullet: Bool }
    static let bulletMark = try! NSRegularExpression(pattern: #"^\s*(?:[-*+]|\d+[.)])\s+(.*)$"#)
    static let headingMark = try! NSRegularExpression(pattern: #"^(#{1,6})\s+(.*?)\s*$"#)

    /// A run of lines as items: each bullet one item (its indented or nested continuation folded in), each paragraph one item.
    static func items(_ lines: [String]) -> [Item] {
        var out: [Item] = [], bullet: String?, para: [String] = []
        func flushPara() { if !para.isEmpty { out.append(Item(text: para.joined(separator: " "), isBullet: false)); para = [] } }
        func flushBullet() { if let b = bullet { out.append(Item(text: b, isBullet: true)); bullet = nil } }
        for raw in lines {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flushPara(); flushBullet(); continue }
            if trimmed == "---" || trimmed == "***" || trimmed.hasPrefix("<!--") { continue }
            let indented = line.hasPrefix(" ")
            if let m = bulletMark.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let r = Range(m.range(at: 1), in: line) {
                let text = String(line[r]).trimmingCharacters(in: .whitespaces)
                if indented, bullet != nil { bullet! += "; " + text; continue }   // a nested bullet rides with its parent
                flushPara(); flushBullet(); bullet = text; continue
            }
            if indented, bullet != nil { bullet! += " " + trimmed; continue }
            flushBullet()
            para.append(trimmed)
        }
        flushPara(); flushBullet()
        return out
    }

    /// The note taken apart: the title and status block set aside, every section's items sent where they belong.
    static func parse(_ body: String, now: Date, timeZone: TimeZone, report: inout Report) -> Parts {
        var p = Parts()
        p.status = NoteStatus.extract(from: body)
        var lines = NoteStatus.strip(body).components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.hasPrefix("# ") }) { p.title = lines[i].trimmingCharacters(in: .whitespaces); lines.remove(at: i) }
        let window = dateWindow(now: now, timeZone: timeZone)
        // split at headings
        var sections: [(section: Section, heading: String, lines: [String])] = [(.preamble, "", [])]
        for line in lines {
            if let m = headingMark.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let r = Range(m.range(at: 2), in: line) {
                let heading = String(line[r])
                if line.hasPrefix(conflictHeading) { p.conflict = true }
                sections.append((classify(heading), heading, []))
            } else { sections[sections.count - 1].lines.append(line) }
        }
        for s in sections {
            let its = items(s.lines)
            guard !its.isEmpty else { continue }
            let canonical = ["About", "Now", "Context", "Earlier"].contains(s.heading)
            if s.section != .preamble, !canonical { p.folded.append(s.heading) }
            switch s.section {
            case .preamble, .about: p.about += its.map(\.text)
            case .now: p.now += its.map { dated($0.text, window: window, report: &report) }
            case .context: p.context += its.map { dated($0.text, window: window, report: &report) }
            case .unknown:
                for it in its { if it.isBullet { p.context.append(dated(it.text, window: window, report: &report)) } else { p.about.append(it.text) } }
            case .earlier:
                for it in its {
                    if let (month, clauses) = monthLine(it.text) { p.earlier.append(MonthLine(month: month, clauses: clauses)) }
                    else if let (month, clause) = monthOf(it.text, window: window) { p.earlier.append(MonthLine(month: month, clauses: [clause])) }
                    else { p.context.append(dated(it.text, window: window, report: &report)) }
                }
            }
        }
        report.folded = p.folded
        return p
    }

    // MARK: dates

    static let months: [String: Int] = {
        var m: [String: Int] = [:]
        for (i, name) in ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"].enumerated() {
            m[name] = i + 1; m[String(name.prefix(3))] = i + 1
        }
        m["sept"] = 9
        return m
    }()
    static let iso = try! NSRegularExpression(pattern: #"\b(\d{4})-(\d{2})-(\d{2})\b"#)
    static let dmy = try! NSRegularExpression(pattern: #"\b(\d{1,2})(?:st|nd|rd|th)?\s+([A-Za-z]{3,9})\.?,?\s+(\d{4})\b"#)
    static let mdy = try! NSRegularExpression(pattern: #"\b([A-Za-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\b"#)
    static let monthYear = try! NSRegularExpression(pattern: #"\b(?:([A-Za-z]{3,9})\.?\s+(\d{4})|(\d{4})-(\d{2}))\b"#)
    static let trailing = try! NSRegularExpression(pattern: #"\s*\(\s*(since\s+)?([^()]*?)\s*\)\s*$"#, options: .caseInsensitive)
    static let monthLineMark = try! NSRegularExpression(pattern: #"^(\d{4}-\d{2})\s*(?:—|–|-|:)\s*(.*)$"#)
    static let dayMonth = try! NSRegularExpression(pattern: #"\b(\d{1,2}) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\b"#)

    /// Every calendar date in `s` as `YYYY-MM-DD`, with where it sits, in order of appearance. Only real days count (no 31 Feb).
    static func days(in s: String) -> [(range: NSRange, day: String)] {
        let ns = s as NSString, all = NSRange(location: 0, length: ns.length)
        var out: [(NSRange, String)] = []
        for m in iso.matches(in: s, range: all) {
            if let d = validDay(y: ns.substring(with: m.range(at: 1)), m: ns.substring(with: m.range(at: 2)), d: ns.substring(with: m.range(at: 3))) { out.append((m.range, d)) }
        }
        for m in dmy.matches(in: s, range: all) {
            guard let mo = months[ns.substring(with: m.range(at: 2)).lowercased()] else { continue }
            if let d = validDay(y: ns.substring(with: m.range(at: 3)), m: String(mo), d: ns.substring(with: m.range(at: 1))) { out.append((m.range, d)) }
        }
        for m in mdy.matches(in: s, range: all) {
            guard let mo = months[ns.substring(with: m.range(at: 1)).lowercased()] else { continue }
            if let d = validDay(y: ns.substring(with: m.range(at: 3)), m: String(mo), d: ns.substring(with: m.range(at: 2))) { out.append((m.range, d)) }
        }
        return out.sorted { $0.0.location < $1.0.location }.map { (range: $0.0, day: $0.1) }
    }
    static func validDay(y: String, m: String, d: String) -> String? {
        guard let yy = Int(y), let mm = Int(m), let dd = Int(d), (1...12).contains(mm), (1...31).contains(dd) else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        guard let date = cal.date(from: DateComponents(year: yy, month: mm, day: dd)), cal.component(.day, from: date) == dd else { return nil }
        return String(format: "%04d-%02d-%02d", yy, mm, dd)
    }
    /// The one date a parenthesis holds — or the last of a range ("2026-06-29–2026-09-09"). Nil when the text is not only a date.
    static func pureDate(_ s: String) -> String? {
        let found = days(in: s)
        guard let last = found.last else { return nil }
        let ns = NSMutableString(string: s)
        for f in found.reversed() { ns.replaceCharacters(in: f.range, with: " ") }
        let rest = (ns as String).replacingOccurrences(of: #"\bto\b"#, with: " ", options: .regularExpression).replacingOccurrences(of: #"\bfrom\b"#, with: " ", options: .regularExpression)
        let leftover = rest.filter { !$0.isWhitespace && !"–—-→,/".contains($0) }
        return leftover.isEmpty ? last.day : nil
    }
    /// The plausible window: nothing ten years back, nothing two years on.
    static func dateWindow(now: Date, timeZone: TimeZone) -> (min: String, max: String) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let lo = cal.date(byAdding: .year, value: -10, to: now) ?? now, hi = cal.date(byAdding: .year, value: 2, to: now) ?? now
        return (NoteMeta.day(lo, timeZone), NoteMeta.day(hi, timeZone))
    }

    /// One bullet's text made dated: a trailing "(2026-09-16)", "(16 Sep 2026)", "(since …)" or a range is read and
    /// normalised; failing that the last date anywhere in the text names the day; failing that the bullet is unclear.
    /// A date outside the window is unclear too — a 1926 is a slip, not a fact.
    static func dated(_ raw: String, window: (min: String, max: String), report: inout Report) -> Bullet {
        let text = raw.trimmingCharacters(in: .whitespaces)
        func checked(_ day: String) -> String? {
            if day < window.min || day > window.max { report.impossible += 1; return nil }
            return day
        }
        if let m = trailing.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let inner = Range(m.range(at: 2), in: text) {
            let content = String(text[inner]), before = String(text[..<Range(m.range, in: text)!.lowerBound]).trimmingCharacters(in: .whitespaces)
            let since = m.range(at: 1).location != NSNotFound
            if content.lowercased() == "date unclear" { return Bullet(text: before, day: nil) }
            if let day = pureDate(content) {
                let ok = checked(day)
                if ok != nil, content != day { report.dated += 1 }
                return Bullet(text: before, day: ok, since: since && ok != nil)
            }
        }
        if let last = days(in: text).last {
            let ok = checked(last.day)
            if ok != nil { report.dated += 1 }
            return Bullet(text: text, day: ok)
        }
        report.unclear += 1
        return Bullet(text: text, day: nil)
    }
    /// A line already in the Earlier shape: its month and clauses.
    static func monthLine(_ text: String) -> (String, [String])? {
        guard let m = monthLineMark.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let mr = Range(m.range(at: 1), in: text), let cr = Range(m.range(at: 2), in: text) else { return nil }
        let clauses = text[cr].components(separatedBy: "; ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (String(text[mr]), clauses)
    }
    /// The month an old Earlier bullet belongs to — its last full date, else a "July 2026" or "2026-07" in it — and the
    /// clause left when that date is taken out ("July 2026: joined the team" → "joined the team").
    static func monthOf(_ text: String, window: (min: String, max: String)) -> (month: String, clause: String)? {
        if let d = days(in: text).last?.day { return d >= window.min && d <= window.max ? (String(d.prefix(7)), stripDate(text)) : nil }
        let ns = text as NSString
        for m in monthYear.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let month: String
            if m.range(at: 1).location != NSNotFound, let mo = months[ns.substring(with: m.range(at: 1)).lowercased()] { month = String(format: "%@-%02d", ns.substring(with: m.range(at: 2)), mo) }
            else if m.range(at: 3).location != NSNotFound, let mo = Int(ns.substring(with: m.range(at: 4))), (1...12).contains(mo) { month = ns.substring(with: m.range(at: 3)) + "-" + ns.substring(with: m.range(at: 4)) }
            else { continue }
            guard month >= String(window.min.prefix(7)), month <= String(window.max.prefix(7)) else { continue }
            let rest = ns.replacingCharacters(in: m.range, with: " ").trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":—–-,;()")))
            return (month, rest.isEmpty ? text : rest)
        }
        return nil
    }
    /// The bullet without its trailing parenthesised date, for a clause on a month line.
    static func stripDate(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let m = trailing.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let inner = Range(m.range(at: 2), in: t),
           pureDate(String(t[inner])) != nil || t[inner].lowercased() == "date unclear" {
            return String(t[..<Range(m.range, in: t)!.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    // MARK: render

    /// The four sections in order, empty ones left out, the status block back under the title.
    static func render(_ p: Parts) -> String {
        var sections: [String] = []
        if !p.about.isEmpty { sections.append(aboutHeading + "\n" + p.about.map { "- " + $0 }.joined(separator: "\n")) }
        if !p.now.isEmpty { sections.append(nowHeading + "\n" + p.now.map(\.rendered).joined(separator: "\n")) }
        if !p.context.isEmpty { sections.append(contextHeading + "\n" + p.context.map(\.rendered).joined(separator: "\n")) }
        if !p.earlier.isEmpty { sections.append(earlierHeading + "\n" + p.earlier.map(\.rendered).joined(separator: "\n")) }
        var out = p.title.map { $0 + "\n" } ?? ""
        if !sections.isEmpty { out += (p.title == nil ? "" : "\n") + sections.joined(separator: "\n\n") + "\n" }
        if let s = p.status { out = NoteStatus.insert(s, into: out) }
        return out
    }

    /// Newest first, ties in the order written; exact repeats folded.
    static func tidy(_ bullets: [Bullet]) -> [Bullet] {
        var seen = Set<String>(), unique: [Bullet] = []
        for b in bullets where seen.insert(b.rendered).inserted { unique.append(b) }
        return unique.enumerated().sorted { ($1.element.sortKey, $0.offset) < ($0.element.sortKey, $1.offset) }.map(\.element)
    }
}
