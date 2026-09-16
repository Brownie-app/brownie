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

    public init(root: URL, indexPath: String, now: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .current) throws {
        rootURL = root
        self.now = now; self.timeZone = timeZone
        index = try SQLite(path: indexPath)
        try index.exec("CREATE VIRTUAL TABLE IF NOT EXISTS note_fts USING fts5(path UNINDEXED, title, body, tokenize='porter unicode61')")
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
    }

    public func search(_ query: String, limit: Int) throws -> [Note] {
        try reindex()
        let q = KnowledgeQuery.fts(query)
        let rows = try index.query("SELECT path FROM note_fts WHERE note_fts MATCH ? ORDER BY rank LIMIT ?", [.text(q), .init(limit)])
        return try rows.compactMap { r in try r["path"].text.flatMap { try note(at: $0) } }
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
    func read(_ url: URL) throws -> Note {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let rel = relative(url)
        let (parsed, body) = NoteMeta.parse(raw, path: rel)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
        let title = body.split(separator: "\n").first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) } ?? url.deletingPathExtension().lastPathComponent
        var meta = parsed ?? NoteMeta(brownie: NoteMeta.kind(forPath: rel), created: "", updated: "")
        if meta.bodyDiffers(body) { meta.userEdited = true }
        return Note(relativePath: rel, title: title, body: body, meta: meta, updatedAt: NoteMeta.date(meta.updated, timeZone) ?? mtime)
    }

    func reindex() throws {
        let files = try allFiles()
        let known = Dictionary(uniqueKeysWithValues: try index.query("SELECT path, mtime FROM note_meta").compactMap { r in r["path"].text.map { ($0, r["mtime"].real ?? 0) } })
        var seen = Set<String>()
        for url in files {
            let rel = relative(url); seen.insert(rel)
            let mtime = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970
            if known[rel] == mtime { continue }
            let note = try read(url)
            try index.run("DELETE FROM note_fts WHERE path=?", [.text(rel)])
            try index.run("INSERT INTO note_fts(path, title, body) VALUES(?,?,?)", [.text(rel), .text(note.title), .text(note.body)])
            try index.run("INSERT INTO note_meta(path, mtime) VALUES(?,?) ON CONFLICT(path) DO UPDATE SET mtime=excluded.mtime", [.text(rel), .real(mtime)])
        }
        for gone in Set(known.keys).subtracting(seen) {
            try index.run("DELETE FROM note_fts WHERE path=?", [.text(gone)]); try index.run("DELETE FROM note_meta WHERE path=?", [.text(gone)])
        }
    }
}

enum Fingerprint {
    static func sha256(_ s: String) -> String { ContentHash.of(s) }
}

/// Turns a question into an FTS5 query that finds notes instead of demanding every word:
/// filler words go, punctuation goes, the rest is OR-ed with prefix matching so "nayan" finds "Nayan's".
public enum KnowledgeQuery {
    static let stop: Set<String> = ["a", "an", "the", "is", "are", "am", "was", "were", "be", "been", "do", "does", "did", "have", "has", "had", "i", "me", "my", "you", "your", "we", "our", "he", "she", "it", "they", "them", "his", "her", "their",
                                    "who", "whom", "whose", "what", "when", "where", "why", "how", "which", "that", "this", "these", "those", "to", "of", "in", "on", "at", "for", "with", "about", "from", "by", "and", "or", "not", "no",
                                    "any", "anything", "still", "yet", "there", "here", "up", "so", "if", "can", "could", "should", "would", "will", "shall", "may", "might", "promise", "promised", "say", "said", "tell", "told", "ask", "asked", "get", "got", "last", "open", "again"]
    public static func fts(_ query: String) -> String {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map { String($0).replacingOccurrences(of: "'s", with: "").replacingOccurrences(of: "'", with: "") }.filter { !$0.isEmpty }
        var terms = words.filter { !stop.contains($0) && $0.count > 1 }
        if terms.isEmpty { terms = words.filter { $0.count > 1 } }
        guard !terms.isEmpty else { return "\"\"" }
        // longer words are more likely the name that matters; keep the query short
        return Array(Set(terms)).sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }.prefix(8).map { "\"\($0)\"*" }.joined(separator: " OR ")
    }
}
