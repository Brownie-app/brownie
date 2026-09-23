import Foundation
import Domain
import Platform
import Support

/// The knowledge base is plain Markdown on disk. This store reads/writes those files and keeps an
/// FTS5 index beside the app store. Every note carries the code-owned front-matter (`NoteMeta`); the
/// store is where it is read, where an outside edit is noticed (the body no longer hashes to what
/// Brownie last wrote) and where it is written back on the next save.
public actor FileKnowledgeStore: KnowledgeStore {
    public nonisolated let rootURL: URL
    private let index: SQLite
    private let log = Log("knowledge")
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone

    /// The index's shape; an index file built to an older one is dropped and `reindex()` fills it again from the
    /// files. 2: the text column is the note as drawn (`NoteBlocks.plainText`) and the tokenizer is plain unicode61,
    /// so a typed prefix is a prefix of what is stored.
    static let schemaVersion: Int64 = 2

    public init(root: URL, indexPath: String, now: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .current) throws {
        rootURL = root
        self.now = now; self.timeZone = timeZone
        index = try SQLite(path: indexPath)
        if (try index.query("PRAGMA user_version").first?["user_version"].int ?? 0) != Self.schemaVersion {
            try index.exec("DROP TABLE IF EXISTS note_fts; DROP TABLE IF EXISTS note_meta; PRAGMA user_version=\(Self.schemaVersion)")
        }
        // No stemmer: the rail searches as you type, and "wedd" must keep finding "wedding" on the way to it, which a
        // stored stem ("wed") cannot; the last term is a prefix anyway, so "meet" still finds "meeting".
        try index.exec("CREATE VIRTUAL TABLE IF NOT EXISTS note_fts USING fts5(path UNINDEXED, title, plain, tokenize='unicode61')")
        try index.exec("CREATE TABLE IF NOT EXISTS note_meta(path TEXT PRIMARY KEY, mtime REAL NOT NULL)")
    }

    public func exists() async -> Bool { (try? noteCount()) ?? 0 > 0 }

    public func noteCount() throws -> Int { try allFiles().count }

    public func folders() throws -> [KnowledgeFolder] {
        var groups: [String: [Note]] = [:]
        for url in try allFiles() {
            let note = try read(url)
            groups[note.folder, default: []].append(note)
        }
        return groups.keys.sorted { a, b in a.isEmpty ? true : (b.isEmpty ? false : a < b) }.map { KnowledgeFolder(name: $0.isEmpty ? "Home" : $0, notes: groups[$0]!.sorted { $0.title < $1.title }) }
    }

    public func note(at relativePath: String) throws -> Note? {
        // Only paths inside the vault: an MCP client or a link can name anything, and ".." must not walk out.
        guard Self.isInsideVault(relativePath), Vault.isNote(relativePath) else { return nil }
        let url = rootURL.appendingPathComponent(relativePath)
        guard url.standardizedFileURL.path.hasPrefix(rootURL.standardizedFileURL.path + "/"), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try read(url)
    }
    /// A relative Markdown path with no way out: no leading slash, no "..", no hidden segments.
    public nonisolated static func isInsideVault(_ rel: String) -> Bool {
        let parts = rel.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !rel.isEmpty, !rel.hasPrefix("/"), !rel.hasPrefix("~"), rel.lowercased().hasSuffix(".md") else { return false }
        return !parts.contains { $0 == ".." || $0.hasPrefix(".") || $0.isEmpty }
    }

    /// A save from the app is the user's: the block on disk (its `created`, its unknown keys) is kept, `user_edited`
    /// becomes true, the hash is the new body's and `updated` moves only when that hash changed.
    public func save(_ note: Note) throws {
        let url = rootURL.appendingPathComponent(note.relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let onDisk = (try? String(contentsOf: url, encoding: .utf8)).map { NoteMeta.parse($0, path: note.relativePath) }
        let today = NoteMeta.day(now(), timeZone)
        var meta = onDisk?.meta ?? note.meta
        if meta.created.isEmpty { meta.created = today }
        meta.sources = note.meta.sources
        meta.userEdited = true
        let hash = NoteMeta.hash(note.body)
        if hash != meta.contentHash || meta.updated.isEmpty { meta.updated = today }
        meta.contentHash = hash
        try (meta.render() + note.body).write(to: url, atomically: true, encoding: .utf8)
        try reindex()
    }

    public func delete(relativePath: String) throws {
        try FileManager.default.removeItem(at: rootURL.appendingPathComponent(relativePath))
        try index.run("DELETE FROM note_fts WHERE path=?", [.text(relativePath)])
        try index.run("DELETE FROM note_meta WHERE path=?", [.text(relativePath)])
        linkMap = nil
    }

    /// Notes for a question: every term must match (the last as a prefix); when nothing does — a question
    /// carries words no note has — its content words are OR-ed, so "who is nayan?" still finds Nayan and
    /// "who is Ravi?" finds nothing rather than every note with a "whoever" in it.
    public func search(_ query: String, limit: Int) throws -> [Note] {
        try reindex()
        for q in [KnowledgeQuery.fts(query), KnowledgeQuery.loose(query)] where q != "\"\"" {
            let rows = try index.query("SELECT path FROM note_fts WHERE note_fts MATCH ? ORDER BY rank LIMIT ?", [.text(q), .init(limit)])
            let notes = try rows.compactMap { r in try r["path"].text.flatMap { try note(at: $0) } }
            if !notes.isEmpty { return notes }
        }
        return []
    }

    /// One hit on the Notes screen: the note, and a snippet of its body around the match with the matched words
    /// between `SearchHit.mark` and `SearchHit.unmark`.
    public struct SearchHit: Sendable, Equatable, Identifiable {
        public static let mark = "\u{E000}", unmark = "\u{E001}"
        public var id: String { note.relativePath }
        public let note: Note
        public let snippet: String
        public init(note: Note, snippet: String) { self.note = note; self.snippet = snippet }
    }
    public struct SearchResults: Sendable, Equatable {
        public let query: String
        public let hits: [SearchHit]
        /// How many notes match in all; more than `hits` when the limit cut the list.
        public let total: Int
        public init(query: String, hits: [SearchHit], total: Int) { self.query = query; self.hits = hits; self.total = total }
    }
    /// Search as the Notes screen shows it: strict (every term), with a snippet and the full count. An empty
    /// query is an empty result, not everything. The snippet is cut from the note as drawn — no comment markers,
    /// no heading or bullet syntax — because that is the text the index holds.
    public func find(_ query: String, limit: Int = 50) throws -> SearchResults {
        try reindex()
        let q = KnowledgeQuery.fts(query)
        guard q != "\"\"" else { return SearchResults(query: query, hits: [], total: 0) }
        let total = Int((try index.query("SELECT count(*) AS n FROM note_fts WHERE note_fts MATCH ?", [.text(q)]).first?["n"].int) ?? 0)
        let rows = try index.query("SELECT path, snippet(note_fts, 2, ?, ?, '…', 14) AS snip FROM note_fts WHERE note_fts MATCH ? ORDER BY rank LIMIT ?", [.text(SearchHit.mark), .text(SearchHit.unmark), .text(q), .init(limit)])
        let hits = try rows.compactMap { r -> SearchHit? in
            guard let p = r["path"].text, let n = try note(at: p) else { return nil }
            return SearchHit(note: n, snippet: (r["snip"].text ?? "").replacingOccurrences(of: "\n", with: " "))
        }
        return SearchResults(query: query, hits: hits, total: total)
    }

    // MARK: backlinks

    /// Every note whose body links to the note at `relativePath` — `[[Title]]`, `[[Title|shown]]`, `[[Title#heading]]`,
    /// any case, and by its file name, its path or a front-matter alias just as a click resolves them — except the
    /// note itself. The link map is built once and kept until a file changes.
    public func backlinks(to relativePath: String) throws -> [Note] {
        try reindex()
        if linkMap == nil { linkMap = try buildLinkMap() }
        return try (linkMap?[relativePath] ?? []).sorted().compactMap { try note(at: $0) }
    }
    /// resolved note path → the notes that link to it.
    private var linkMap: [String: Set<String>]?
    static let linkPattern = try! NSRegularExpression(pattern: #"\[\[([^\]\[|#]+)(?:[#|][^\]]*)?\]\]"#)
    private func buildLinkMap() throws -> [String: Set<String>] {
        let notes = try allFiles().map(read)
        // the index the screen resolves a click with, so "Mentioned in" lists exactly the links that open this note
        let links = LinkIndex(folders: [KnowledgeFolder(name: "", notes: notes)])
        var map: [String: Set<String>] = [:]
        for n in notes {
            let s = n.body as NSString
            for m in Self.linkPattern.matches(in: n.body, range: NSRange(location: 0, length: s.length)) {
                guard let target = links.path(for: s.substring(with: m.range(at: 1))), target != n.relativePath else { continue }
                map[target, default: []].insert(n.relativePath)
            }
        }
        return map
    }

    /// sha256 over `relpath|size|mtime` of every .md — cheap and sensitive to any edit.
    public func fingerprint() throws -> String {
        var s = ""
        for url in try allFiles().sorted(by: { $0.path < $1.path }) {
            let a = try FileManager.default.attributesOfItem(atPath: url.path)
            s += "\(relative(url))|\(a[.size] ?? 0)|\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)\n"
        }
        return Fingerprint.sha256(s)
    }

    // MARK: files

    nonisolated func relative(_ url: URL) -> String { String(url.standardizedFileURL.path.dropFirst(rootURL.standardizedFileURL.path.count + 1)) }

    /// Every note: Markdown that `Vault.isNote` accepts, so Today.md and hidden files are never knowledge.
    func allFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        let e = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        var out: [URL] = []
        for case let u as URL in e ?? FileManager.default.enumerator(atPath: "/dev/null")! where Vault.isNote(relative(u)) { out.append(u) }
        return out
    }

    /// The note as the app sees it. `user_edited` is true when the block says so or when the body on disk no longer
    /// hashes to what Brownie last wrote — an edit in Obsidian, on the phone or from the household counts the same.
    /// Such an edit changed the substance on the day the file was last written, so that day is `updated` until the
    /// next code write stamps one; a note whose body still hashes keeps the day its block records.
    func read(_ url: URL) throws -> Note {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let rel = relative(url)
        let (parsed, body) = NoteMeta.parse(raw, path: rel)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
        let title = body.split(separator: "\n").first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) } ?? url.deletingPathExtension().lastPathComponent
        var meta = parsed ?? NoteMeta(brownie: NoteMeta.kind(forPath: rel), created: "", updated: "")
        var updatedAt = NoteMeta.date(meta.updated, timeZone) ?? mtime
        if meta.bodyDiffers(body) { meta.userEdited = true; meta.updated = NoteMeta.day(mtime, timeZone); updatedAt = mtime }
        return Note(relativePath: rel, title: title, body: body, meta: meta, updatedAt: updatedAt)
    }

    func reindex() throws {
        let files = try allFiles()
        let known = Dictionary(uniqueKeysWithValues: try index.query("SELECT path, mtime FROM note_meta").compactMap { r in r["path"].text.map { ($0, r["mtime"].real ?? 0) } })
        var seen = Set<String>()
        for url in files {
            let rel = relative(url); seen.insert(rel)
            let mtime = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970
            if known[rel] == mtime { continue }
            let note = try read(url); linkMap = nil
            try index.run("DELETE FROM note_fts WHERE path=?", [.text(rel)])
            try index.run("INSERT INTO note_fts(path, title, plain) VALUES(?,?,?)", [.text(rel), .text(note.title), .text(NoteBlocks.plainText(note.body))])
            try index.run("INSERT INTO note_meta(path, mtime) VALUES(?,?) ON CONFLICT(path) DO UPDATE SET mtime=excluded.mtime", [.text(rel), .real(mtime)])
        }
        for gone in Set(known.keys).subtracting(seen) {
            linkMap = nil
            try index.run("DELETE FROM note_fts WHERE path=?", [.text(gone)]); try index.run("DELETE FROM note_meta WHERE path=?", [.text(gone)])
        }
    }
}

enum Fingerprint {
    static func sha256(_ s: String) -> String { ContentHash.of(s) }
}

/// Turns what was typed into an FTS5 query. `fts` is strict: every term must match, the last one as a prefix
/// (so the word still being typed finds "Nayan's"), a "quoted phrase" passes through whole, and only pure function
/// words are dropped — "open", "promise", "ask" and "last" are words a note can be found by. `loose` is the
/// fallback for questions: the content words alone, OR-ed, so "who is Ravi?" is a search for Ravi and not for
/// every note that says "whoever" — and nothing at all when the question has no content word.
public enum KnowledgeQuery {
    static let stop: Set<String> = ["the", "a", "an", "of", "to", "and", "or", "in", "on", "at", "is", "are", "was", "were", "i", "me", "my", "you", "your", "we", "our", "it", "this", "that"]
    /// The words a question is made of that name nothing: findable by `fts` (a note can say "ask"), dropped by `loose`.
    static let questionWords: Set<String> = ["who", "what", "when", "where", "why", "how", "which", "did", "does", "do", "done", "still", "anything", "about", "with", "for", "from", "have", "has", "had", "be", "been", "can", "could", "should", "would", "will", "not", "no", "yes", "get", "got", "last", "next", "ask", "asked", "tell", "told", "say", "said", "know", "think"]

    /// The quoted phrases and the bare words of a query, in order; phrases keep their words as typed.
    static func terms(_ query: String) -> (phrases: [String], words: [String]) {
        var phrases: [String] = [], rest = "", cur = "", inQuote = false
        for ch in query {
            if ch == "\"" || ch == "“" || ch == "”" {
                if inQuote { let p = cur.trimmingCharacters(in: .whitespaces); if !p.isEmpty { phrases.append(p) }; cur = "" }
                inQuote.toggle(); continue
            }
            if inQuote { cur.append(ch) } else { rest.append(ch) }
        }
        if inQuote { rest += " " + cur }   // an unclosed quote is just words
        // Split where the unicode61 tokenizer splits — on anything that is not a letter or a digit, the apostrophe
        // included — so "D'Souza" asks for the stored "souza" and "Nitesh's" for "nitesh"; the one-letter leftovers go.
        let words = rest.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var kept = words.filter { !stop.contains($0) && $0.count > 1 }
        if kept.isEmpty, phrases.isEmpty { kept = words.filter { $0.count > 1 } }
        var seen = Set<String>(); kept = kept.filter { seen.insert($0).inserted }
        return (phrases, Array(kept.prefix(12)))
    }
    static func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    public static func fts(_ query: String) -> String {
        let (phrases, words) = terms(query)
        var parts = phrases.map { quoted($0.lowercased()) }
        for (i, w) in words.enumerated() { parts.append(quoted(w) + (i == words.count - 1 ? "*" : "")) }
        guard !parts.isEmpty else { return "\"\"" }
        return parts.joined(separator: " AND ")
    }
    /// The content words OR-ed; a short one is asked for whole, since "who"* would take in "whoever" and "WhatsApp".
    public static func loose(_ query: String) -> String {
        let (phrases, words) = terms(query)
        let content = words.filter { !stop.contains($0) && !questionWords.contains($0) }
        let parts = phrases.map { quoted($0.lowercased()) } + content.map { quoted($0) + ($0.count < 4 ? "" : "*") }
        guard !parts.isEmpty else { return "\"\"" }
        return parts.joined(separator: " OR ")
    }
}
