import Foundation
import Domain

/// A note's body read as blocks, so the screen can draw it instead of showing the Markdown raw. Pure over the
/// string: headings (H1–H3), paragraphs, bullets, checkboxes, quotes, fenced code, rules, and the status block as
/// a block of its own; inside a line, bold, italic, code, `[url](…)` and the three wikilink forms. An HTML
/// comment is never a block and never text — a card id on a checkbox line is kept as data, the rest is dropped.
public enum NoteBlocks {
    public enum Inline: Equatable, Sendable {
        case text(String), code(String)
        /// Emphasis wraps whatever sits inside it: `**[[Meera]]**` is a bold link, and a code span inside `_…_` keeps its face.
        case bold([Inline]), italic([Inline])
        /// `[[target]]`, `[[target|label]]`, `[[target#heading]]`: the note named, the heading within it, the words shown.
        case wikilink(target: String, heading: String?, label: String)
        case url(label: String, url: String)
    }
    public struct ListItem: Equatable, Sendable {
        public let indent: Int
        /// The number of a `1.` item; nil for a bullet.
        public let ordinal: Int?
        public let inlines: [Inline]
        public init(indent: Int, ordinal: Int?, inlines: [Inline]) { self.indent = indent; self.ordinal = ordinal; self.inlines = inlines }
    }
    public struct CheckItem: Equatable, Sendable {
        public let checked: Bool
        public let inlines: [Inline]
        /// The `<!-- card:id -->` on a Today.md line, so a tap can tick the card.
        public let cardID: String?
        public init(checked: Bool, inlines: [Inline], cardID: String?) { self.checked = checked; self.inlines = inlines; self.cardID = cardID }
    }
    public enum Block: Equatable, Sendable {
        case heading(level: Int, inlines: [Inline])
        case paragraph([Inline])
        case list([ListItem])
        case checklist([CheckItem])
        case quote([Inline])
        case code(String)
        case rule
        /// The status block's items, the leading "- " dropped: "⏳ 3 Sep — they asked: …". Its heading and its note are not repeated.
        case status(lines: [String])
    }

    // MARK: blocks

    public static func parse(_ body: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = [], list: [ListItem] = [], checks: [CheckItem] = [], quote: [String] = [], status: [String]? = nil, code: [String]? = nil
        func flush() {
            if !para.isEmpty { out.append(.paragraph(inlines(para.joined(separator: " ")))); para = [] }
            if !list.isEmpty { out.append(.list(list)); list = [] }
            if !checks.isEmpty { out.append(.checklist(checks)); checks = [] }
            if !quote.isEmpty { out.append(.quote(inlines(quote.joined(separator: "\n")))); quote = [] }
        }
        for rawLine in stripComments(body, keepCardIDs: true).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var s = status {
                if trimmed.hasPrefix(NoteStatus.close) || trimmed.hasPrefix(NoteStatus.legacyClose) { out.append(.status(lines: s)); status = nil; continue }
                if trimmed.hasPrefix("- ") { s.append(String(trimmed.dropFirst(2))); status = s }
                else if !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("_") { s.append(trimmed); status = s }
                continue
            }
            if var c = code {
                if trimmed.hasPrefix("```") { out.append(.code(c.joined(separator: "\n"))); code = nil } else { c.append(line); code = c }
                continue
            }
            if trimmed.hasPrefix(NoteStatus.open) || trimmed.hasPrefix(NoteStatus.legacyOpen) { flush(); status = []; continue }
            if trimmed.hasPrefix("```") { flush(); code = []; continue }
            if trimmed.isEmpty { flush(); continue }
            if trimmed.hasPrefix("#"), let level = headingLevel(trimmed) {
                flush(); out.append(.heading(level: min(level, 3), inlines: inlines(String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))); continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { flush(); out.append(.rule); continue }
            if trimmed.hasPrefix(">") {
                // a quote closes what came before it except another quote line
                if !para.isEmpty || !list.isEmpty || !checks.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)); continue
            }
            if let box = checkbox(trimmed) {
                if !para.isEmpty || !list.isEmpty || !quote.isEmpty { flush() }
                checks.append(box); continue
            }
            if let item = listItem(line) {
                if !para.isEmpty || !checks.isEmpty || !quote.isEmpty { flush() }
                list.append(item); continue
            }
            if !list.isEmpty || !checks.isEmpty || !quote.isEmpty { flush() }
            para.append(trimmed)
        }
        if let s = status { out.append(.status(lines: s)) }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }

    static func headingLevel(_ s: String) -> Int? {
        let hashes = s.prefix(while: { $0 == "#" }).count
        guard hashes >= 1, hashes <= 6, s.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }
    static func checkbox(_ trimmed: String) -> CheckItem? {
        guard trimmed.count >= 5, "-*+".contains(trimmed.first!), trimmed.dropFirst().hasPrefix(" [") else { return nil }
        let box = trimmed.dropFirst(3)
        guard let mark = box.first, " xX".contains(mark), box.dropFirst().hasPrefix("]") else { return nil }
        var rest = String(box.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        var cardID: String?
        if let m = cardMarker.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)), let r = Range(m.range(at: 1), in: rest), let whole = Range(m.range, in: rest) {
            cardID = String(rest[r]); rest.removeSubrange(whole); rest = rest.trimmingCharacters(in: .whitespaces)
        }
        return CheckItem(checked: mark != " ", inlines: inlines(rest), cardID: cardID)
    }
    static func listItem(_ line: String) -> ListItem? {
        let lead = line.prefix(while: { $0 == " " || $0 == "\t" })
        let indent = lead.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
        let rest = line.dropFirst(lead.count)
        if let f = rest.first, "-*+".contains(f), rest.dropFirst().hasPrefix(" ") { return ListItem(indent: indent, ordinal: nil, inlines: inlines(String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))) }
        let digits = rest.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3, rest.dropFirst(digits.count).hasPrefix(". ") { return ListItem(indent: indent, ordinal: Int(digits), inlines: inlines(String(rest.dropFirst(digits.count + 2)).trimmingCharacters(in: .whitespaces))) }
        return nil
    }

    static let cardMarker = try! NSRegularExpression(pattern: #"<!--\s*card:([^\s>]+)\s*-->"#)
    static let anyComment = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->"#)
    static let otherComment = try! NSRegularExpression(pattern: #"<!--(?!\s*card:|\s*/?brownie:)[\s\S]*?-->"#)
    /// The text without HTML comments. With `keepCardIDs` the card markers (and the status block's own markers, which
    /// the block parser reads) survive for the line parsers to take; the inline parser drops whatever is left.
    static func stripComments(_ s: String, keepCardIDs: Bool) -> String {
        let re = keepCardIDs ? otherComment : anyComment
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    // MARK: inlines

    public static func inlines(_ raw: String) -> [Inline] {
        let s = Array(stripComments(raw, keepCardIDs: false))
        var out: [Inline] = [], text = "", i = 0
        func flushText() { if !text.isEmpty { out.append(.text(text)); text = "" } }
        func find(_ close: [Character], from: Int) -> Int? {
            var j = from
            while j + close.count <= s.count { if Array(s[j..<j + close.count]) == close { return j }; j += 1 }
            return nil
        }
        while i < s.count {
            let c = s[i]
            if c == "[", i + 1 < s.count, s[i + 1] == "[", let end = find(["]", "]"], from: i + 2), end > i + 2 {
                let inner = String(s[(i + 2)..<end])
                flushText(); out.append(wikilink(inner)); i = end + 2; continue
            }
            if c == "[", let close = find(["]"], from: i + 1), close + 1 < s.count, s[close + 1] == "(", let paren = find([")"], from: close + 2), close > i + 1 {
                flushText(); out.append(.url(label: String(s[(i + 1)..<close]), url: String(s[(close + 2)..<paren]))); i = paren + 1; continue
            }
            if c == "`", let end = find(["`"], from: i + 1), end > i + 1 {
                flushText(); out.append(.code(String(s[(i + 1)..<end]))); i = end + 1; continue
            }
            if (c == "*" || c == "_"), i + 1 < s.count, s[i + 1] == c, i + 2 < s.count, !s[i + 2].isWhitespace, let end = find([c, c], from: i + 2), end > i + 2, !s[end - 1].isWhitespace {
                flushText(); out.append(.bold(inlines(String(s[(i + 2)..<end])))); i = end + 2; continue
            }
            if (c == "*" || c == "_"), i + 1 < s.count, !s[i + 1].isWhitespace, s[i + 1] != c, c == "*" || i == 0 || !(s[i - 1].isLetter || s[i - 1].isNumber),
               let end = find([c], from: i + 1), end > i + 1, !s[end - 1].isWhitespace, c == "*" || end + 1 == s.count || !(s[end + 1].isLetter || s[end + 1].isNumber) {
                flushText(); out.append(.italic(inlines(String(s[(i + 1)..<end])))); i = end + 1; continue
            }
            text.append(c); i += 1
        }
        flushText()
        return out
    }

    /// `[[Name]]`, `[[Name|alias]]`, `[[Name#heading]]`, `[[Name#heading|alias]]`.
    static func wikilink(_ inner: String) -> Inline {
        var target = inner, label: String? = nil, heading: String? = nil
        if let bar = target.firstIndex(of: "|") { label = String(target[target.index(after: bar)...]); target = String(target[..<bar]) }
        if let hash = target.firstIndex(of: "#") { heading = String(target[target.index(after: hash)...]).trimmingCharacters(in: .whitespaces); target = String(target[..<hash]) }
        target = target.trimmingCharacters(in: .whitespaces)
        let shown = (label?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? (heading.map { "\(target) › \($0)" } ?? target)
        return .wikilink(target: target, heading: heading.flatMap { $0.isEmpty ? nil : $0 }, label: shown)
    }

    /// The words alone, links by their label.
    public static func plain(_ inlines: [Inline]) -> String {
        inlines.map { i -> String in
            switch i { case .text(let s), .code(let s): return s; case .bold(let i), .italic(let i): return plain(i); case .wikilink(_, _, let l), .url(let l, _): return l }
        }.joined()
    }

    /// The whole note as the screen draws it, a line per block item: no comment markers, no heading, bullet or
    /// emphasis syntax, and of the status block only the items the card shows — not its markers, its heading or
    /// its note. This is what the search index holds and cuts snippets from, so a hit never shows what the note
    /// view hides and "brownie" or "ledger" match no note that merely carries the block.
    public static func plainText(_ body: String) -> String {
        var out: [String] = []
        for b in parse(body) {
            switch b {
            case .heading(_, let i), .paragraph(let i), .quote(let i): out.append(plain(i))
            case .list(let items): out += items.map { plain($0.inlines) }
            case .checklist(let items): out += items.map { plain($0.inlines) }
            case .code(let s): out.append(s)
            case .status(let lines): out += lines
            case .rule: break
            }
        }
        return out.joined(separator: "\n")
    }

    /// The count of ⏳ items in the status block — what is still open between the user and this person.
    public static func openItems(in body: String) -> Int {
        for case .status(let lines) in parse(body) { return lines.filter { $0.hasPrefix("⏳") }.count }
        return 0
    }

    /// A Today.md line's box, ticked or cleared by its card id; the text is otherwise untouched.
    public static func setCheckbox(in markdown: String, cardID: String, checked: Bool) -> String {
        markdown.split(separator: "\n", omittingEmptySubsequences: false).map { sub -> String in
            var l = String(sub)
            guard l.contains("card:"), let m = cardMarker.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)), let r = Range(m.range(at: 1), in: l), l[r] == cardID else { return l }
            guard let open = l.range(of: "- ["), l.distance(from: open.upperBound, to: l.endIndex) >= 2 else { return l }
            let box = open.upperBound
            l.replaceSubrange(box...box, with: checked ? "x" : " ")
            return l
        }.joined(separator: "\n")
    }
}

/// The lines the screen says about a note, from its front-matter and never the file's mtime.
public enum NoteFacts {
    /// A person's note this many days without its substance changing is "quiet" on the header.
    public static let quietAfter = 30

    /// "Updated 16 Sep · sources: WhatsApp · Nitesh, Slack": the front-matter's day (the year added only when it is
    /// not this one) and its sources; a note with no day yet falls back to the store's date.
    public static func metaLine(_ n: Note, now: Date = Date(), calendar: Calendar = .current) -> String {
        var parts: [String] = []
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
        if let d = NoteMeta.date(n.meta.updated, calendar.timeZone) {
            f.dateFormat = calendar.component(.year, from: d) == calendar.component(.year, from: now) ? "d MMM" : "d MMM yyyy"
            parts.append("Updated " + f.string(from: d))
        } else { f.dateFormat = "d MMM yyyy"; parts.append("Updated " + f.string(from: n.updatedAt)) }
        if !n.sources.isEmpty { parts.append("sources: " + n.sources.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// Days since the substance last changed; nil for a note whose day is unknown.
    public static func quietDays(_ n: Note, now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let d = NoteMeta.date(n.meta.updated, calendar.timeZone) else { return nil }
        return max(0, Int(now.timeIntervalSince(d) / 86400))
    }
}

/// Which note a `[[link]]` opens: by title, by file name, or by an alias from the note's front-matter, case-insensitively.
public struct LinkIndex: Sendable, Equatable {
    private var byKey: [String: String] = [:]
    public init(folders: [KnowledgeFolder]) {
        // titles win over aliases, so an alias that is someone else's title never steals the link
        for n in folders.flatMap(\.notes) { for a in n.meta.aliases { byKey[Self.key(a)] = n.relativePath } }
        for n in folders.flatMap(\.notes) {
            byKey[Self.key(n.title)] = n.relativePath
            byKey[Self.key(String(n.relativePath.split(separator: "/").last ?? "").replacingOccurrences(of: ".md", with: ""))] = n.relativePath
            byKey[Self.key(n.relativePath.replacingOccurrences(of: ".md", with: ""))] = n.relativePath
        }
    }
    public init() {}
    static func key(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased() }
    public func path(for target: String) -> String? { byKey[Self.key(target)] }
}

/// The editor's view of a note: the prose alone, the front-matter and the status block taken out and put back on
/// save so neither is ever lost to an edit. The store re-attaches the front-matter; the block is this enum's job.
public enum NoteEdit {
    /// What the editor shows: the body without the status block.
    public static func forEditing(_ body: String) -> String { NoteStatus.strip(body) }
    /// The edited prose with the original body's status block back where Brownie keeps it, byte for byte.
    public static func reattach(edited: String, original: String) -> String {
        let clean = NoteStatus.strip(edited)   // the user pasting a block back in must not double it
        guard let block = NoteStatus.extract(from: original) else { return clean }
        return NoteStatus.insert(block, into: clean)
    }
}
