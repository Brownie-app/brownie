import Foundation

/// The front-matter Brownie owns on every note. The brain never sees it and never writes it; code attaches it,
/// keeps `created` from the first write, moves `updated` only on the night the substance changed (the body with
/// the status block stripped hashes differently), and records the hash it last wrote so an edit made anywhere —
/// the app, Obsidian, the phone, the household — shows up as `user_edited` the next time the note is read.
/// Keys Brownie does not own (a user's `tags:`, `aliases` Obsidian adds, anything) ride along verbatim, in order.
public struct NoteMeta: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable { case person, group, topic, portrait }
    public var brownie: String
    public var id: String?
    public var aliases: [String]
    public var sources: [String]
    public var created: String
    public var updated: String
    public var userEdited: Bool
    public var contentHash: String
    public var extra: [String: String]
    /// The order the unknown keys appeared in on disk, so a save leaves them as the user wrote them.
    public var extraOrder: [String]

    public init(brownie: String, id: String? = nil, aliases: [String] = [], sources: [String] = [], created: String, updated: String,
                userEdited: Bool = false, contentHash: String = "", extra: [String: String] = [:], extraOrder: [String] = []) {
        self.brownie = brownie; self.id = id; self.aliases = aliases; self.sources = sources; self.created = created; self.updated = updated
        self.userEdited = userEdited; self.contentHash = contentHash; self.extra = extra
        self.extraOrder = extraOrder.filter { extra[$0] != nil } + extra.keys.filter { !extraOrder.contains($0) }.sorted()
    }

    public static let owned: Set<String> = ["brownie", "id", "aliases", "sources", "created", "updated", "user_edited", "content_hash"]

    /// What a note is, by where it lives: `People/` holds people, `Groups/` groups, the root README is the portrait, the rest are topics.
    public static func kind(forPath rel: String) -> String {
        if rel.hasPrefix("People/") { return Kind.person.rawValue }
        if rel.hasPrefix("Groups/") { return Kind.group.rawValue }
        if rel == "README.md" { return Kind.portrait.rawValue }
        return Kind.topic.rawValue
    }

    /// A fresh block for a note written today at `rel`, hashing `body`.
    public static func fresh(path rel: String, body: String, today: String, id: String? = nil, aliases: [String] = [], sources: [String] = []) -> NoteMeta {
        NoteMeta(brownie: kind(forPath: rel), id: id, aliases: aliases, sources: sources, created: today, updated: today, userEdited: false, contentHash: hash(body))
    }

    /// The hash `updated` and `user_edited` are judged by: the body without the status block, with runs of blank
    /// lines folded and the ends trimmed, so the block coming and going and a trailing newline change nothing.
    public static func hash(_ body: String) -> String {
        var s = NoteStatus.strip(body).trimmingCharacters(in: .whitespacesAndNewlines)
        while s.contains("\n\n\n") { s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return ContentHash.of(s)
    }
    /// Whether `body` on disk is not what Brownie last wrote. Unknown (no hash on record) is not an edit.
    public func bodyDiffers(_ body: String) -> Bool { !contentHash.isEmpty && Self.hash(body) != contentHash }

    /// A body rewrite that is code's, not the user's (a `[[link]]` rename after a merge): the file with the new body
    /// and the hash moved along with it, so the change is never later read as an edit. `updated` stays — the substance
    /// did not change — and a body the user had already edited keeps its old hash, so that edit is still noticed.
    /// Nil when `transform` has nothing to change.
    public static func restamp(_ raw: String, path rel: String, body transform: (String) -> String?) -> String? {
        let (meta, body) = parse(raw, path: rel)
        guard let new = transform(body) else { return nil }
        guard var m = meta else { return new }
        if !m.contentHash.isEmpty, !m.bodyDiffers(body) { m.contentHash = hash(new) }
        return m.render() + new
    }

    // MARK: parsing and rendering

    /// Splits a file into its front-matter and body. No front-matter → (nil, whole text). A legacy block (the
    /// old three keys, no `brownie:`) becomes a block whose kind comes from the path and whose dates are unknown (empty).
    public static func parse(_ raw: String, path rel: String) -> (meta: NoteMeta?, body: String) {
        guard raw.hasPrefix("---\n"), let end = raw.range(of: "\n---\n", range: raw.index(raw.startIndex, offsetBy: 4)..<raw.endIndex) else { return (nil, raw) }
        let block = String(raw[raw.index(raw.startIndex, offsetBy: 4)..<end.lowerBound]), body = String(raw[end.upperBound...])
        // key → raw value, continuation lines (indented or "- item") folded into the key before them
        var order: [String] = [], values: [String: String] = [:]
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            if let last = order.last, line.first == " " || line.first == "\t" || line.hasPrefix("- ") { values[last, default: ""] += "\n" + line; continue }
            guard let c = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<c]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if !order.contains(key) { order.append(key) }
            values[key] = String(line[line.index(after: c)...])
        }
        func scalar(_ k: String) -> String { (values[k] ?? "").trimmingCharacters(in: .whitespaces) }
        func list(_ k: String) -> [String] {
            let v = scalar(k)
            if v.hasPrefix("[") { return splitList(String(v.dropFirst().dropLast(v.hasSuffix("]") ? 1 : 0))) }
            if v.hasPrefix("\n") || v.isEmpty, let raw = values[k], raw.contains("\n- ") || raw.contains("\n  - ") {
                return raw.split(separator: "\n").compactMap { l in let t = l.trimmingCharacters(in: .whitespaces); return t.hasPrefix("- ") ? unquote(String(t.dropFirst(2))) : nil }.filter { !$0.isEmpty }
            }
            return splitList(v)
        }
        let extraKeys = order.filter { !owned.contains($0) }
        var extra: [String: String] = [:]
        for k in extraKeys { extra[k] = values[k] ?? "" }
        // A legacy block has no `brownie:`; its `updated:` was a timestamp of the last save, not a day the substance changed, so it is dropped.
        let isOwned = values["brownie"] != nil
        let id = scalar("id")
        return (NoteMeta(brownie: isOwned ? scalar("brownie") : kind(forPath: rel), id: id.isEmpty ? nil : id, aliases: list("aliases"), sources: list("sources"),
                         created: isOwned ? scalar("created") : "", updated: isOwned ? scalar("updated") : "",
                         userEdited: scalar("user_edited") == "true", contentHash: scalar("content_hash"), extra: extra, extraOrder: extraKeys), body)
    }

    /// The block as it goes on disk, front-matter fences included, ready to prefix a body.
    public func render() -> String {
        var lines = ["brownie: \(brownie)"]
        if let id, !id.isEmpty { lines.append("id: \(id)") }
        lines.append("aliases: [\(aliases.map(Self.quote).joined(separator: ", "))]")
        lines.append("sources: [\(sources.map(Self.quote).joined(separator: ", "))]")
        lines.append("created: \(created)"); lines.append("updated: \(updated)")
        lines.append("user_edited: \(userEdited)"); lines.append("content_hash: \(contentHash)")
        for k in extraOrder { if let v = extra[k] { lines.append("\(k):\(v)") } }
        return "---\n" + lines.joined(separator: "\n") + "\n---\n"
    }

    /// Comma-separated items, a comma inside quotes being part of its item ("Pandey, Kanika").
    static func splitList(_ s: String) -> [String] {
        var items: [String] = [], cur = "", quoted = false
        for ch in s {
            if ch == "\"" { quoted.toggle(); cur.append(ch) }
            else if ch == ",", !quoted { items.append(cur); cur = "" }
            else { cur.append(ch) }
        }
        items.append(cur)
        return items.map(unquote).filter { !$0.isEmpty }
    }
    static func quote(_ s: String) -> String {
        s.contains(where: { ",:[]\"#".contains($0) }) || s != s.trimmingCharacters(in: .whitespaces) ? "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\"" : s
    }
    static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") { return String(t.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"") }
        if t.count >= 2, t.hasPrefix("'"), t.hasSuffix("'") { return String(t.dropFirst().dropLast()) }
        return t
    }

    /// `YYYY-MM-DD` for a moment in a zone, the shape every dated field takes.
    public static func day(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
    /// The moment a `YYYY-MM-DD` names (its midnight in the zone), nil for an empty or malformed field.
    public static func date(_ day: String, _ tz: TimeZone) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)
    }
}

/// The status block's place in a note, shared by everything that must leave it alone: the brain's file tools strip it
/// before the brain reads and put it back after it writes; the hash ignores it. The block's contents are Proactive's.
public enum NoteStatus {
    public static let open = "<!-- brownie:status -->", close = "<!-- /brownie:status -->"
    public static let legacyOpen = "<!-- brownie:between-you -->", legacyClose = "<!-- /brownie:between-you -->"

    static func range(in body: String) -> Range<String.Index>? {
        for (o, c) in [(open, close), (legacyOpen, legacyClose)] {
            if let s = body.range(of: o), let e = body.range(of: c), s.lowerBound < e.lowerBound { return s.lowerBound..<e.upperBound }
        }
        return nil
    }
    /// The block, markers included, or nil when the note has none.
    public static func extract(from body: String) -> String? { range(in: body).map { String(body[$0]) } }
    /// The body without the block and the blank line that followed it.
    public static func strip(_ body: String) -> String {
        guard let r = range(in: body) else { return body }
        var end = r.upperBound
        while end < body.endIndex, body[end] == "\n", body.distance(from: r.upperBound, to: end) < 2 { end = body.index(after: end) }
        var b = body; b.removeSubrange(r.lowerBound..<end); return b
    }
    /// The block put back where Brownie keeps it: right after the title line, else at the top.
    public static func insert(_ block: String, into body: String) -> String {
        let trimmed = block.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return body }
        if body.hasPrefix("# "), let nl = body.firstIndex(of: "\n") {
            var b = body; b.insert(contentsOf: "\n" + trimmed + "\n", at: body.index(after: nl)); return b
        }
        return trimmed + "\n\n" + body
    }
}

/// FNV-1a 64 folded twice: CryptoKit-free, stable across runs, good enough to tell one text from another.
public enum ContentHash {
    public static func of(_ s: String) -> String {
        var h1: UInt64 = 0xcbf29ce484222325, h2: UInt64 = 0x84222325cbf29ce4
        for b in s.utf8 { h1 = (h1 ^ UInt64(b)) &* 0x100000001b3; h2 = (h2 &+ UInt64(b)) &* 0x100000001b3 }
        return String(format: "%016llx%016llx", h1, h2)
    }
}

public struct Note: Sendable, Identifiable, Equatable {
    public var id: String { relativePath }
    public let relativePath: String
    public let title: String
    public let body: String
    public let meta: NoteMeta
    /// The day the substance last changed (`meta.updated`), or the file's mtime for a note with no front-matter yet.
    public let updatedAt: Date
    public var sources: [String] { meta.sources }
    public var userEdited: Bool { meta.userEdited }
    public init(relativePath: String, title: String, body: String, meta: NoteMeta, updatedAt: Date) {
        self.relativePath = relativePath; self.title = title; self.body = body; self.meta = meta; self.updatedAt = updatedAt
    }
    /// A note with a block made up on the spot; the store fills in what the file already carries when it saves.
    public init(relativePath: String, title: String, body: String, sources: [String], updatedAt: Date, userEdited: Bool) {
        let day = NoteMeta.day(updatedAt, .current)
        self.init(relativePath: relativePath, title: title, body: body,
                  meta: NoteMeta(brownie: NoteMeta.kind(forPath: relativePath), sources: sources, created: day, updated: day, userEdited: userEdited, contentHash: NoteMeta.hash(body)), updatedAt: updatedAt)
    }
    public var folder: String { relativePath.contains("/") ? String(relativePath.split(separator: "/").first!) : "" }
}

public struct KnowledgeFolder: Sendable, Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let notes: [Note]
    public init(name: String, notes: [Note]) { self.name = name; self.notes = notes }
}

public protocol KnowledgeStore: Sendable {
    var rootURL: URL { get }
    func exists() async -> Bool
    func folders() async throws -> [KnowledgeFolder]
    func note(at relativePath: String) async throws -> Note?
    func save(_ note: Note) async throws
    func delete(relativePath: String) async throws
    func search(_ query: String, limit: Int) async throws -> [Note]
    func fingerprint() async throws -> String
    func noteCount() async throws -> Int
}
