import Foundation
import Domain

/// The fixed shape of a People or Groups note, so a year of nights cannot bloat or stale one: the title, the status
/// block (Proactive's, byte for byte, right under the title), then `## About` (standing facts, undated), `## Now`
/// (dated bullets — what the cards are made from), `## Context` (dated bullets that are no longer news) and
/// `## Earlier` (one line per calendar month, newest first). The brain writes prose into that shape; this is the code
/// that puts a note back into it when the brain, the user or an older builder wrote something else: a "Pending" list
/// becomes Now, an unknown heading's dated bullets become Context and the rest About, every Now and Context bullet
/// ends with `(YYYY-MM-DD)`, `(since YYYY-MM-DD)` or `(date unclear)`. The one rule above the shape: nothing the user
/// wrote is lost. A date is read only where the shape puts it — at the end of a bullet, in parentheses or after a dash —
/// or where the brain's other habit puts it, opening the bullet ("**16 Sep 2026:** …", "2026-09-16 — …"), from where
/// it moves to the end; a date in the middle of a sentence is words; whatever the parser has no opinion about (an HTML
/// comment, a table, a fenced code block, a block quote, a `###` sub-heading) is carried through as it was, in the
/// section it sat in; the lines indented under a bullet stay under it. Only the status block is Brownie's to take out.
/// The time rules (what leaves Now, what Earlier forgets) live in `NoteAging` and are applied here too, with the
/// `NoteLint` word rules between, so a normalised note holds every invariant at once. Idempotent for the same `now`:
/// a normalised note passes through unchanged.
public enum NoteSkeleton {
    public static let aboutCap = 30, nowCap = 6, contextCap = 12
    public static let unclear = "(date unclear)"
    static let aboutHeading = "## About", nowHeading = "## Now", contextHeading = "## Context", earlierHeading = "## Earlier"
    /// A sync conflict the user has not resolved is left exactly as it is: folding both versions together would hide the choice.
    static let conflictHeading = "## Brownie's version ("

    // MARK: the pieces

    /// One thing under a heading as the parser read it: a bullet (its first line's words, a wrapped line joined on, and
    /// the lines indented under it — nested bullets, an aside — kept whole in `nested` with the parent's indent taken
    /// off), a paragraph of prose, or a run the shape has no opinion about and carries through as it was.
    struct Item: Equatable {
        enum Kind { case bullet, prose, verbatim }
        var kind: Kind
        var text: String
        var nested: [String] = []
        var rendered: String { kind == .verbatim ? text : (["- " + text] + nested).joined(separator: "\n") }
        var spacing: (before: Bool, after: Bool) { NoteSkeleton.spacing(text, verbatim: kind == .verbatim) }
        /// The words on one line, for a clause on a month line: what was nested follows in parentheses.
        var flat: String { NoteSkeleton.flat(text, nested) }
    }
    /// One dated bullet: its text without the date, the day it names (nil when unclear), whether it is a "since", and
    /// the lines nested under it. A verbatim item that sat among the bullets rides along with `verbatim` set and no date.
    struct Bullet: Equatable {
        var text: String
        var day: String?
        var since: Bool
        var nested: [String]
        var verbatim: Bool
        init(text: String, day: String?, since: Bool = false, nested: [String] = [], verbatim: Bool = false) {
            self.text = text; self.day = day; self.since = since; self.nested = nested; self.verbatim = verbatim
        }
        init(verbatim item: Item) { self.init(text: item.text, day: nil, verbatim: true) }
        var stamp: String { day.map { since ? "(since \($0))" : "(\($0))" } ?? NoteSkeleton.unclear }
        var rendered: String { verbatim ? text : (["- " + text + " " + stamp] + nested).joined(separator: "\n") }
        var spacing: (before: Bool, after: Bool) { NoteSkeleton.spacing(text, verbatim: verbatim) }
        /// Newest first; an unclear date sorts last.
        var sortKey: String { day ?? "0000-00-00" }
        /// The bullet as a clause on a month line: its words, what was nested under it in parentheses.
        var clause: String { NoteSkeleton.flat(text, nested) }
        /// The bullet back as an About item, a since date kept as part of the words.
        var asAbout: Item { Item(kind: .bullet, text: text + (day == nil ? "" : " " + stamp), nested: nested) }
    }
    /// Where a blank line goes when items are rendered: a table, a fence or a quote reads as its own block with one
    /// either side; a sub-heading wants one above it and its list right under it; a comment or a bullet sits on its line.
    static func spacing(_ text: String, verbatim: Bool) -> (before: Bool, after: Bool) {
        guard verbatim, !text.hasPrefix("<!--") else { return (false, false) }
        return (true, !text.hasPrefix("#"))
    }
    /// One Earlier line: "- YYYY-MM — clause; clause".
    struct MonthLine: Equatable {
        var month: String
        var clauses: [String]
        var rendered: String { "- \(month) — " + clauses.joined(separator: "; ") }
    }
    /// The note taken apart. `folded` names the headings that were not the four, for the change log; `earlierExtra`
    /// is what sat under Earlier that is not a month line and not a bullet (a comment, a table).
    struct Parts: Equatable {
        var title: String?
        var status: String?
        var about: [Item] = [], now: [Bullet] = [], context: [Bullet] = [], earlier: [MonthLine] = [], earlierExtra: [Item] = []
        var folded: [String] = []
        var conflict = false
    }
    /// What one pass did, in numbers; `changes` says it in words. The word rules' numbers ride along in `lint`.
    struct Report: Equatable {
        var folded: [String] = []
        var dated = 0, unclear = 0, impossible = 0
        var lint = NoteLint.Report()
        var movedToEarlier = 0, movedToContext = 0, movedToAbout = 0, aboutToContext = 0, retired = 0
        var droppedEarlier = 0, droppedClauses = 0
        /// The counted changes in words; a body that changed with nothing to count (sections put in order) says so.
        var changes: [String] { counted.isEmpty ? ["put in shape"] : counted }
        var counted: [String] {
            var out: [String] = []
            func n(_ v: Int, _ one: String, _ many: String) -> String { "\(v) \(v == 1 ? one : many)" }
            if !folded.isEmpty { out.append("folded " + folded.map { "‘\($0)’" }.joined(separator: ", ")) }
            if dated > 0 { out.append(n(dated, "bullet dated", "bullets dated")) }
            if unclear > 0 { out.append(n(unclear, "bullet marked date unclear", "bullets marked date unclear")) }
            if impossible > 0 { out.append(n(impossible, "impossible date marked unclear", "impossible dates marked unclear")) }
            out += lint.counted
            if movedToEarlier > 0 { out.append(n(movedToEarlier, "bullet moved to Earlier", "bullets moved to Earlier")) }
            if movedToContext > 0 { out.append(n(movedToContext, "bullet moved to Context", "bullets moved to Context")) }
            if aboutToContext > 0 { out.append(n(aboutToContext, "About bullet past the cap moved to Context", "About bullets past the cap moved to Context")) }
            if movedToAbout > 0 { out.append(n(movedToAbout, "standing fact past the cap kept under About", "standing facts past the cap kept under About")) }
            if retired > 0 { out.append(n(retired, "retired line kept under Earlier", "retired lines kept under Earlier")) }
            if droppedEarlier > 0 { out.append(n(droppedEarlier, "Earlier line let go", "Earlier lines let go")) }
            if droppedClauses > 0 { out.append(n(droppedClauses, "Earlier clause let go", "Earlier clauses let go")) }
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

    /// The words that name a section, matched whole (so "Outstanding" is not "standing") with the longest match
    /// deciding. The old builder wrote "Pending", "Pending and commitments", "Open items", "Recent", "Background" and
    /// the like; a user writes "Family", "Kids", "Work"; each lands where its content belongs.
    static let headingWords: [(Section, String)] = [
        (.about, "what the group is"), (.about, "about"), (.about, "who"), (.about, "background"), (.about, "profile"), (.about, "relationships?"),
        (.about, "basics"), (.about, "overview"), (.about, "members?"), (.about, "standing"), (.about, "family"), (.about, "kids"), (.about, "home"), (.about, "work"),
        (.now, "asks and promises"), (.now, "now"), (.now, "pending"), (.now, "open"), (.now, "commitments?"), (.now, "waiting"), (.now, "outstanding"),
        (.now, "upcoming"), (.now, "to[ -]?do"), (.now, "next steps?"), (.now, "asks?"), (.now, "promises?"), (.now, "requests?"),
        (.context, "context"), (.context, "recent(ly)?"), (.context, "timelines?"), (.context, "history"), (.context, "dated"), (.context, "facts"), (.context, "notes"),
        (.context, "update[sd]?"), (.context, "activit(y|ies)"), (.context, "going on"), (.context, "plan(s|ned|ning)?"),
        (.earlier, "earlier"), (.earlier, "older"), (.earlier, "past"), (.earlier, "previous(ly)?"), (.earlier, "archived?"),
    ]
    static let headingRules: [(Section, NSRegularExpression)] = headingWords.map { ($0.0, try! NSRegularExpression(pattern: "(?<![a-z])(?:" + $0.1 + ")(?![a-z])")) }

    /// Which of the four a heading means, by its longest whole-word match; none is unknown.
    static func classify(_ heading: String) -> Section {
        let h = heading.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var best: (section: Section, length: Int)?
        for (section, rule) in headingRules {
            for m in rule.matches(in: h, range: NSRange(h.startIndex..., in: h)) where m.range.length > (best?.length ?? 0) { best = (section, m.range.length) }
        }
        return best?.section ?? .unknown
    }

    static let bulletMark = try! NSRegularExpression(pattern: #"^\s*(?:[-*+]|\d+[.)])\s+(.*)$"#)
    static let headingMark = try! NSRegularExpression(pattern: #"^(#{1,2})\s+(.*?)\s*$"#)
    static let subheadingMark = try! NSRegularExpression(pattern: #"^#{3,6}\s+"#)
    static let fenceMark = try! NSRegularExpression(pattern: #"^(`{3,}|~{3,})"#)

    /// Which lines sit inside a fenced code block or a multi-line HTML comment (the fence and comment lines included):
    /// a `#` line in there is not a heading and the note is not split at it.
    static func opaque(_ lines: [String]) -> [Bool] {
        var out = [Bool](repeating: false, count: lines.count), fence: String?, comment = false
        for (i, raw) in lines.enumerated() {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if let f = fence {
                out[i] = true
                if closes(t, f) { fence = nil }
            } else if comment {
                out[i] = true
                if t.contains("-->") { comment = false }
            } else if let f = fenceOpen(t) {
                out[i] = true; fence = f
            } else if t.hasPrefix("<!--"), !t.contains("-->") {
                out[i] = true; comment = true
            }
        }
        return out
    }
    static func fenceOpen(_ trimmed: String) -> String? {
        guard let m = fenceMark.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)), let r = Range(m.range(at: 1), in: trimmed) else { return nil }
        return String(trimmed[r])
    }
    /// A closing fence is the opener's character, at least as many, and nothing else on the line.
    static func closes(_ trimmed: String, _ fence: String) -> Bool { trimmed.count >= fence.count && trimmed.allSatisfy { $0 == fence.first! } }

    /// A run the shape carries through untouched, starting at line `i`, and the index after it: a fenced code block to
    /// its closing fence (or the end), an HTML comment to its `-->`, a table's consecutive `|` rows, a block quote's
    /// consecutive `>` lines, one `###` sub-heading. Nil when line `i` is ordinary.
    static func verbatimRun(_ lines: [String], at i: Int) -> (text: String, next: Int)? {
        let first = lines[i].trimmingCharacters(in: .whitespaces)
        func through(_ closed: (String) -> Bool) -> (String, Int) {
            var j = i + 1
            while j < lines.count, !closed(lines[j].trimmingCharacters(in: .whitespaces)) { j += 1 }
            var end = min(j, lines.count - 1)
            // a run left open runs to the end, the blank lines there not included, or it would grow one every pass
            while end > i, lines[end].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
            return (lines[i...end].joined(separator: "\n"), end + 1)
        }
        func run(_ keep: (String) -> Bool) -> (String, Int) {
            var j = i + 1
            while j < lines.count, keep(lines[j].trimmingCharacters(in: .whitespaces)) { j += 1 }
            return (lines[i..<j].joined(separator: "\n"), j)
        }
        if let f = fenceOpen(first) { return through { closes($0, f) } }
        if first.hasPrefix("<!--") { return first.contains("-->") ? (lines[i], i + 1) : through { $0.contains("-->") } }
        if first.hasPrefix("|") { return run { $0.hasPrefix("|") } }
        if first.hasPrefix(">") { return run { $0.hasPrefix(">") } }
        if subheadingMark.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)) != nil { return (lines[i], i + 1) }
        return nil
    }

    /// A run of lines as items: each bullet one item with the lines indented deeper than it kept under it (a wrapped
    /// line before any nested one joins the bullet's own words), a bullet indented no deeper is the next bullet, each
    /// paragraph one item, and each fence, comment, table, quote or sub-heading one verbatim item. A rule is decoration.
    static func items(_ lines: [String]) -> [Item] {
        var out: [Item] = [], bullet: (text: String, indent: Int, nested: [String])?, para: [String] = [], i = 0
        func flushPara() { if !para.isEmpty { out.append(Item(kind: .prose, text: para.joined(separator: " "))); para = [] } }
        func flushBullet() { if let b = bullet { out.append(Item(kind: .bullet, text: b.text, nested: b.nested)); bullet = nil } }
        func flush() { flushPara(); flushBullet() }
        while i < lines.count {
            let line = lines[i].replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " }.count
            if trimmed.isEmpty { flush(); i += 1; continue }
            if trimmed == "---" || trimmed == "***" { i += 1; continue }
            let under = bullet.map { indent > $0.indent } ?? false
            // a fence or a sub-heading is never part of a bullet; the rest of the verbatim runs are, when indented under one
            let alwaysWhole = fenceOpen(trimmed) != nil || subheadingMark.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
            if !under || alwaysWhole, let (text, next) = verbatimRun(lines, at: i) {
                flush(); out.append(Item(kind: .verbatim, text: text)); i = next; continue
            }
            if under, let b = bullet {
                let kept = String(line.dropFirst(b.indent))
                if bulletMark.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil || !b.nested.isEmpty { bullet!.nested.append(kept) }
                else { bullet!.text += " " + trimmed }   // a wrapped line
                i += 1; continue
            }
            if let m = bulletMark.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let r = Range(m.range(at: 1), in: line) {
                flush(); bullet = (String(line[r]).trimmingCharacters(in: .whitespaces), indent, []); i += 1; continue
            }
            flushBullet(); para.append(trimmed); i += 1
        }
        flush()
        return out
    }

    /// The words of a bullet and its nested lines on one line: "parent (child, child)".
    static func flat(_ text: String, _ nested: [String]) -> String {
        let inner = nested.map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if let m = bulletMark.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let r = Range(m.range(at: 1), in: t) { return String(t[r]).trimmingCharacters(in: .whitespaces) }
            return t
        }.filter { !$0.isEmpty }
        return inner.isEmpty ? text : text + " (" + inner.joined(separator: ", ") + ")"
    }

    /// The note taken apart: the title and status block set aside, every section's items sent where they belong.
    /// Only `#` and `##` open a section; a deeper heading is an item of the section it sits in.
    static func parse(_ body: String, now: Date, timeZone: TimeZone, report: inout Report) -> Parts {
        var p = Parts()
        p.status = NoteStatus.extract(from: body)
        var lines = NoteStatus.strip(body).components(separatedBy: "\n")
        var hidden = opaque(lines)
        if let i = lines.indices.first(where: { !hidden[$0] && lines[$0].hasPrefix("# ") }) { p.title = lines[i].trimmingCharacters(in: .whitespaces); lines.remove(at: i); hidden.remove(at: i) }
        let window = dateWindow(now: now, timeZone: timeZone)
        // split at headings
        var sections: [(section: Section, heading: String, lines: [String])] = [(.preamble, "", [])]
        for (i, line) in lines.enumerated() {
            if !hidden[i], let m = headingMark.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let r = Range(m.range(at: 2), in: line) {
                let heading = String(line[r])
                if line.hasPrefix(conflictHeading) { p.conflict = true }
                sections.append((classify(heading), heading, []))
            } else { sections[sections.count - 1].lines.append(line) }
        }
        func bullet(_ it: Item) -> Bullet { it.kind == .verbatim ? Bullet(verbatim: it) : dated(it, window: window, report: &report) }
        for s in sections {
            let its = items(s.lines)
            guard !its.isEmpty else { continue }
            let canonical = ["About", "Now", "Context", "Earlier"].contains(s.heading)
            if s.section != .preamble, !canonical { p.folded.append(s.heading) }
            switch s.section {
            case .preamble, .about: p.about += its
            case .now: p.now += its.map(bullet)
            case .context: p.context += its.map(bullet)
            case .unknown:
                // a bullet that carries a date is news; everything else is a standing fact by construction
                for it in its {
                    var probe = Report()
                    let b = it.kind == .bullet ? dated(it, window: window, report: &probe) : nil
                    if let b, b.day != nil { report.dated += probe.dated; p.context.append(b) } else { p.about.append(it) }
                }
            case .earlier:
                for it in its {
                    if it.kind == .verbatim { p.earlierExtra.append(it); continue }
                    let text = it.flat
                    if let (month, clauses) = monthLine(text) { p.earlier.append(MonthLine(month: month, clauses: clauses)) }
                    else if let (month, clause) = monthOf(text, window: window) { p.earlier.append(MonthLine(month: month, clauses: [clause])) }
                    else { p.context.append(dated(Item(kind: .bullet, text: text), window: window, report: &report)) }
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
    /// "July 2026:" or "2026-07 —" opening a line: the month the old builder folded a clause under.
    static let monthPrefix = try! NSRegularExpression(pattern: #"^(?:([A-Za-z]{3,9})\.?\s+(\d{4})|(\d{4})-(\d{2}))(?![-\d])\s*(?:[:—–-]\s*)?"#)
    static let trailing = try! NSRegularExpression(pattern: #"\s*\(\s*(since\s+)?([^()]*?)\s*\)\s*$"#, options: .caseInsensitive)
    /// "… — 16 Sep 2026" or "… · since 2026-09-01": the other place a date is read, after the last spaced dash or dot.
    static let trailingDash = try! NSRegularExpression(pattern: #"^(.*\S)\s+[—–·]\s+(since\s+)?(\S.*?)\s*$"#, options: .caseInsensitive)
    /// "2026-07 — clause; clause"; a full date ("2026-07-15 —") is not a month and falls through to `monthOf`.
    static let monthLineMark = try! NSRegularExpression(pattern: #"^(\d{4}-\d{2})(?![-\d])\s*(?:—|–|-|:)\s*(.*)$"#)
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
    /// The plausible window — nothing ten years back, nothing two years on — and today, which a bare "16 Sep" is read against.
    typealias Window = (min: String, max: String, today: String)
    static func dateWindow(now: Date, timeZone: TimeZone) -> Window {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let lo = cal.date(byAdding: .year, value: -10, to: now) ?? now, hi = cal.date(byAdding: .year, value: 2, to: now) ?? now
        return (NoteMeta.day(lo, timeZone), NoteMeta.day(hi, timeZone), NoteMeta.day(now, timeZone))
    }

    /// "**16 Sep 2026:** words", "16 Sep 2026 — words", "2026-09-16: words", "Sep 16: words": a date opening the
    /// bullet, bold or not, with a colon or a spaced dash after it (the colon inside or outside the bold). The head is
    /// whatever sits before the first such separator; `headDay` then says whether it is a date at all.
    static let leadingMark = try! NSRegularExpression(pattern: #"^(?:\*\*\s*([\w ,.\-]{3,24}?)\s*(?::\s*\*\*|\*\*\s*:|\*\*\s*[—–])|([\w ,.\-]{3,24}?)\s*(?::|[—–]))\s*(\S.*)$"#)
    static let bareDayMonth = try! NSRegularExpression(pattern: #"^(\d{1,2})(?:st|nd|rd|th)?\s+([A-Za-z]{3,9})\.?$"#)
    static let bareMonthDay = try! NSRegularExpression(pattern: #"^([A-Za-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?$"#)

    /// The head of a bullet as a day: a full date in any of the three styles, or a bare "16 Sep" / "Sep 16", which takes
    /// the year that makes it most recent without putting it after today.
    static func headDay(_ head: String, today: String) -> String? {
        if let d = pureDate(head) { return d }
        let ns = head as NSString, all = NSRange(location: 0, length: ns.length)
        var found: (day: String, month: Int)?
        if let m = bareDayMonth.firstMatch(in: head, range: all), let mo = months[ns.substring(with: m.range(at: 2)).lowercased()] { found = (ns.substring(with: m.range(at: 1)), mo) }
        else if let m = bareMonthDay.firstMatch(in: head, range: all), let mo = months[ns.substring(with: m.range(at: 1)).lowercased()] { found = (ns.substring(with: m.range(at: 2)), mo) }
        guard let (day, month) = found, let year = Int(today.prefix(4)) else { return nil }
        for y in [year, year - 1] { if let d = validDay(y: String(y), m: String(month), d: day), d <= today { return d } }
        return nil
    }
    /// The words after a date opening the bullet, and the day it names; nil when the bullet opens with words.
    static func leading(_ text: String, today: String) -> (rest: String, day: String)? {
        guard let m = leadingMark.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let rest = Range(m.range(at: 3), in: text) else { return nil }
        let head = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
        guard let hr = Range(head, in: text), let day = headDay(String(text[hr]), today: today) else { return nil }
        return (String(text[rest]).trimmingCharacters(in: .whitespaces), day)
    }

    /// The date at the end of a bullet, where the shape puts it, and the words before it: "(2026-09-16)", "(16 Sep
    /// 2026)", "(since …)", a range, "(date unclear)", or the same after a spaced dash or dot ("— 16 Sep 2026"). Nil
    /// when the bullet ends in words — a date in the middle of a sentence is words. `day` is nil for "(date unclear)".
    static func ending(_ text: String) -> (before: String, day: String?, since: Bool)? {
        if let m = trailing.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let inner = Range(m.range(at: 2), in: text) {
            let content = String(text[inner]), before = String(text[..<Range(m.range, in: text)!.lowerBound]).trimmingCharacters(in: .whitespaces)
            if content.lowercased() == "date unclear" { return (before, nil, false) }
            if let day = pureDate(content) { return (before, day, m.range(at: 1).location != NSNotFound) }
        }
        if let m = trailingDash.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let br = Range(m.range(at: 1), in: text), let cr = Range(m.range(at: 3), in: text),
           let day = pureDate(String(text[cr])) { return (String(text[br]), day, m.range(at: 2).location != NSNotFound) }
        return nil
    }

    /// One bullet made dated: the date at its end is read and normalised; a date opening the bullet comes off, and is
    /// the bullet's date when the end gave none (a bullet with both keeps the end's); a bullet that opens and ends in
    /// words is unclear, its words whole. A date outside the window is a slip, not a fact: the bullet keeps the slip
    /// as words and is unclear unless its head names a day.
    static func dated(_ it: Item, window: Window, report: inout Report) -> Bullet {
        let text = it.text.trimmingCharacters(in: .whitespaces)
        let end = ending(text)
        var words = text, day: String?, since = false
        if let end {
            if let d = end.day, d < window.min || d > window.max { report.impossible += 1 } else { (words, day, since) = end }
        }
        if let lead = leading(words, today: window.today), lead.day >= window.min, lead.day <= window.max {
            words = lead.rest
            if day == nil { day = lead.day }
            report.dated += 1
        } else if end == nil { report.unclear += 1 }
        else if let d = day, !text.hasSuffix(since ? "(since \(d))" : "(\(d))") { report.dated += 1 }
        return Bullet(text: words, day: day, since: since, nested: it.nested)
    }
    /// A line already in the Earlier shape: its month and clauses.
    static func monthLine(_ text: String) -> (String, [String])? {
        guard let m = monthLineMark.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let mr = Range(m.range(at: 1), in: text), let cr = Range(m.range(at: 2), in: text) else { return nil }
        let clauses = text[cr].components(separatedBy: "; ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (String(text[mr]), clauses)
    }
    /// The month an old Earlier bullet belongs to — its last full date, else the "July 2026" or "2026-07" opening it,
    /// else the last one anywhere in it — and its clause: the words whole, except that a date at the end in the shape's
    /// own form and a month opening the line ("July 2026: joined the team" → "joined the team") come off, since the
    /// month line carries them.
    static func monthOf(_ text: String, window: Window) -> (month: String, clause: String)? {
        if let d = days(in: text).last?.day { return d >= window.min && d <= window.max ? (String(d.prefix(7)), stripDate(text)) : nil }
        let ns = text as NSString
        // both patterns capture (month word, year) or (year, month number) as groups 1-2 or 3-4
        func month(_ m: NSTextCheckingResult) -> String? {
            let out: String
            if m.range(at: 1).location != NSNotFound, let mo = months[ns.substring(with: m.range(at: 1)).lowercased()] { out = String(format: "%@-%02d", ns.substring(with: m.range(at: 2)), mo) }
            else if m.range(at: 3).location != NSNotFound, let mo = Int(ns.substring(with: m.range(at: 4))), (1...12).contains(mo) { out = ns.substring(with: m.range(at: 3)) + "-" + ns.substring(with: m.range(at: 4)) }
            else { return nil }
            return out >= String(window.min.prefix(7)) && out <= String(window.max.prefix(7)) ? out : nil
        }
        if let m = monthPrefix.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), let mo = month(m) {
            let rest = ns.substring(from: m.range.length).trimmingCharacters(in: .whitespaces)
            return (mo, rest.isEmpty ? text : rest)
        }
        for m in monthYear.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            if let mo = month(m) { return (mo, text) }
        }
        return nil
    }
    /// The bullet without the date at its end in the shape's own form, for a clause on a month line; a "since" is kept
    /// whole, its date being part of the fact.
    static func stripDate(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let (before, _, since) = ending(t), !since, !before.isEmpty else { return t }
        return before
    }

    // MARK: render

    /// The four sections in order, empty ones left out, the status block back under the title; blank lines where
    /// `spacing` puts them.
    static func render(_ p: Parts) -> String {
        func join(_ entries: [(text: String, spacing: (before: Bool, after: Bool))]) -> String {
            var out = ""
            for (i, e) in entries.enumerated() {
                if i > 0 { out += e.spacing.before || entries[i - 1].spacing.after ? "\n\n" : "\n" }
                out += e.text
            }
            return out
        }
        var sections: [String] = []
        if !p.about.isEmpty { sections.append(aboutHeading + "\n" + join(p.about.map { ($0.rendered, $0.spacing) })) }
        if !p.now.isEmpty { sections.append(nowHeading + "\n" + join(p.now.map { ($0.rendered, $0.spacing) })) }
        if !p.context.isEmpty { sections.append(contextHeading + "\n" + join(p.context.map { ($0.rendered, $0.spacing) })) }
        if !p.earlier.isEmpty || !p.earlierExtra.isEmpty { sections.append(earlierHeading + "\n" + join(p.earlier.map { ($0.rendered, (false, false)) } + p.earlierExtra.map { ($0.rendered, $0.spacing) })) }
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
