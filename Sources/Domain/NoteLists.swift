import Foundation

/// The notes opened most recently on the Notes screen: newest first, no repeats, at most eight. Kept in
/// UserDefaults by the app; the rules live here so they can be checked without it.
public struct RecentNotes: Sendable, Equatable, Codable {
    public static let cap = 8
    public private(set) var paths: [String]
    public init(paths: [String] = []) { self.paths = Array(paths.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(Self.cap)) }

    /// A note opened: to the front, its earlier place dropped, the list trimmed to the cap.
    public mutating func open(_ path: String) {
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > Self.cap { paths.removeLast(paths.count - Self.cap) }
    }
    public mutating func remove(_ path: String) { paths.removeAll { $0 == path } }
    /// The list with notes that no longer exist taken out (a rename, a delete, an archive move).
    public func pruned(existing: Set<String>) -> RecentNotes { RecentNotes(paths: paths.filter { existing.contains($0) }) }
    /// The list after the vault changed: a note that moved is followed, one that is gone is dropped (`NoteLists.settle`).
    public func settled(existing: Set<String>, moved: (String) -> String?) -> RecentNotes { RecentNotes(paths: NoteLists.settle(paths, existing: existing, moved: moved)) }
}

/// The notes the user pinned to the top of the rail, in the order they were pinned.
public struct PinnedNotes: Sendable, Equatable, Codable {
    public private(set) var paths: [String]
    public init(paths: [String] = []) { self.paths = paths.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } }
    public func contains(_ path: String) -> Bool { paths.contains(path) }
    public mutating func toggle(_ path: String) { if let i = paths.firstIndex(of: path) { paths.remove(at: i) } else { paths.append(path) } }
    public mutating func remove(_ path: String) { paths.removeAll { $0 == path } }
    public func pruned(existing: Set<String>) -> PinnedNotes { PinnedNotes(paths: paths.filter { existing.contains($0) }) }
    public func settled(existing: Set<String>, moved: (String) -> String?) -> PinnedNotes { PinnedNotes(paths: NoteLists.settle(paths, existing: existing, moved: moved)) }
}

/// What the two lists share once the vault has changed under them, and the words the screen uses for where a note went.
public enum NoteLists {
    /// Each path kept when its note is still there, replaced by where the note went when `moved` knows (the gardener's
    /// `People/X.md` → `People/Archive/X.md` and the way back), dropped only when the note is nowhere. Order kept; a
    /// note that ends up listed twice — pinned under both spellings — is one entry.
    public static func settle(_ paths: [String], existing: Set<String>, moved: (String) -> String?) -> [String] {
        var out: [String] = []
        for p in paths {
            guard let q = existing.contains(p) ? p : moved(p), !out.contains(q) else { continue }
            out.append(q)
        }
        return out
    }

    /// Where a note lives, in words for a sheet: "in People", "in the People archive", "in Work › 2025", "at the top of the vault".
    public static func placeWords(_ path: String) -> String {
        let folders = path.split(separator: "/").dropLast().map(String.init)
        guard let first = folders.first else { return "at the top of the vault" }
        if folders.count == 2, folders[1] == "Archive" { return "in the \(first) archive" }
        return "in " + folders.joined(separator: " › ")
    }

    /// What the screen says when the note it was sent to has moved since: into the archive, or back out of it.
    public static func movedLine(title: String, intoArchive: Bool, quietDays: Int?) -> String {
        guard intoArchive else { return "\(title) is back from the archive." }
        guard let d = quietDays, d > 0 else { return "\(title) is in the archive now." }
        let months = d / 30
        let span = months >= 2 ? "\(months) months" : (months == 1 ? "a month" : "\(d) day\(d == 1 ? "" : "s")")
        return "\(title) is in the archive now — quiet for \(span)."
    }
}

/// The ⌘K palette's ranking: titles that fuzzily match the query, best first; with no query, the recent notes
/// first and the rest by title. Pure, so the order can be checked in a test.
public enum QuickOpen {
    public struct Entry: Sendable, Equatable { public let path: String; public let title: String; public init(path: String, title: String) { self.path = path; self.title = title } }

    /// Subsequence match, scored: a prefix match beats a word-start match beats a scattered one; nil when a
    /// character of the query is missing from the title. Case-insensitive.
    public static func score(_ query: String, in title: String) -> Int? {
        let q = Array(query.lowercased()), t = Array(title.lowercased())
        guard !q.isEmpty else { return 0 }
        if t.starts(with: q) { return 1000 - t.count }
        var score = 0, ti = 0, qi = 0, lastHit = -2
        while qi < q.count {
            guard ti < t.count else { return nil }
            if t[ti] == q[qi] {
                let wordStart = ti == 0 || t[ti - 1] == " " || t[ti - 1] == "-" || t[ti - 1] == "/"
                score += (wordStart ? 20 : 5) + (lastHit == ti - 1 ? 10 : 0)
                lastHit = ti; qi += 1
            }
            ti += 1
        }
        return score - t.count / 4
    }

    public static func rank(_ query: String, entries: [Entry], recent: [String], limit: Int = 12) -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            let byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            let first = recent.compactMap { byPath[$0] }
            let rest = entries.filter { !recent.contains($0.path) }.sorted { $0.title.lowercased() < $1.title.lowercased() }
            return Array((first + rest).prefix(limit))
        }
        let recentRank = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return entries.compactMap { e in score(q, in: e.title).map { (e, $0 + (recentRank[e.path].map { 50 - $0 } ?? 0)) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title.lowercased() < $1.0.title.lowercased() }
            .prefix(limit).map(\.0)
    }
}
