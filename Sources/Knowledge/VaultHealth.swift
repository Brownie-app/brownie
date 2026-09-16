import Foundation
import Domain

/// The vault, measured: bounded growth is only real once something counts it. Computed every night at FINISH over
/// the Markdown files (hidden folders, Today.md and any Archive/ folder left out), kept one record per day under
/// `SettingKey.vaultHealth`, and read on Settings → Knowledge as one sentence plus the lists behind it.
public struct VaultHealth: Codable, Sendable, Equatable {
    /// A note and its word count — the largest notes and the ones over budget.
    public struct NoteSize: Codable, Sendable, Equatable { public let path: String; public let words: Int; public init(path: String, words: Int) { self.path = path; self.words = words } }
    /// A `[[Name]]` that no note answers to, with the first note it was found in.
    public struct Dangling: Codable, Sendable, Equatable { public let name: String; public let path: String; public init(name: String, path: String) { self.name = name; self.path = path } }
    /// Two People (or Groups) notes that may be one person.
    public struct Pair: Codable, Sendable, Equatable { public let a: String; public let b: String; public init(a: String, b: String) { self.a = a; self.b = b } }

    public var at: Date
    public var notes: Int
    /// Notes per top-level folder; notes at the root sit under ".".
    public var notesPerFolder: [String: Int]
    public var words: Int
    public var medianWords: Int
    public var largest: [NoteSize]
    public var readmeWords: Int
    public var overBudget: [NoteSize]
    public var quietPeople: [String]
    public var danglingLinks: [Dangling]
    public var duplicateSuspects: [Pair]
    public var oldestPendingDays: Int?
    public var netWordsPerWeek: Int?

    // The budgets: the README is a page, a person or group a long page, anything else a chapter.
    public static let readmeBudget = 350, personBudget = 1500, noteBudget = 2500
    public static let quietAfterDays = 90, keep = 90

    public init(at: Date, notes: Int = 0, notesPerFolder: [String: Int] = [:], words: Int = 0, medianWords: Int = 0, largest: [NoteSize] = [], readmeWords: Int = 0,
                overBudget: [NoteSize] = [], quietPeople: [String] = [], danglingLinks: [Dangling] = [], duplicateSuspects: [Pair] = [], oldestPendingDays: Int? = nil, netWordsPerWeek: Int? = nil) {
        self.at = at; self.notes = notes; self.notesPerFolder = notesPerFolder; self.words = words; self.medianWords = medianWords; self.largest = largest; self.readmeWords = readmeWords
        self.overBudget = overBudget; self.quietPeople = quietPeople; self.danglingLinks = danglingLinks; self.duplicateSuspects = duplicateSuspects; self.oldestPendingDays = oldestPendingDays; self.netWordsPerWeek = netWordsPerWeek
    }

    // MARK: compute

    /// One note as the measure sees it.
    struct Measured {
        let path: String, folder: String, title: String, words: Int, body: String, updated: Date
        var fileName: String { String(path.split(separator: "/").last ?? "").replacingOccurrences(of: ".md", with: "") }
    }

    /// Every rule at once over the vault at `root`. `history` (newest first) gives the week-ago record behind `netWordsPerWeek`.
    public static func compute(root: URL, now: Date, history: [VaultHealth] = [], timeZone: TimeZone = .current) -> VaultHealth {
        let all = measure(root: root)
        var h = VaultHealth(at: now)
        h.notes = all.count
        h.notesPerFolder = Dictionary(all.map { ($0.folder, 1) }, uniquingKeysWith: +)
        h.words = all.reduce(0) { $0 + $1.words }
        let sorted = all.map(\.words).sorted()
        h.medianWords = sorted.isEmpty ? 0 : (sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2)
        h.largest = all.sorted { ($1.words, $1.path) < ($0.words, $0.path) }.prefix(5).map { NoteSize(path: $0.path, words: $0.words) }
        h.readmeWords = all.first { $0.path == "README.md" }?.words ?? 0
        h.overBudget = all.filter { $0.words > budget(for: $0) }.sorted { $0.path < $1.path }.map { NoteSize(path: $0.path, words: $0.words) }
        let quietBefore = now.addingTimeInterval(-Double(quietAfterDays) * 86400)
        h.quietPeople = all.filter { $0.folder == "People" && $0.updated < quietBefore }.map(\.path).sorted()
        h.danglingLinks = dangling(in: all)
        h.duplicateSuspects = duplicates(in: all)
        h.oldestPendingDays = all.compactMap { oldestPending(in: $0.body, now: now, timeZone: timeZone) }.max()
        h.netWordsPerWeek = netWords(now: h.words, at: now, history: history)
        return h
    }

    /// The vault's notes, read: hidden folders, Today.md and any Archive/ folder are not part of the measure.
    static func measure(root: URL) -> [Measured] {
        let base = root.standardizedFileURL
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [Measured] = []
        for case let url as URL in e where url.pathExtension == "md" {
            let rel = String(url.standardizedFileURL.path.dropFirst(base.path.count + 1))
            let parts = rel.split(separator: "/").map(String.init)
            if rel == TodayNote.path || parts.dropLast().contains("Archive") { continue }
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let (meta, body) = frontMatter(raw)
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let updated = meta["updated"].flatMap { ISO8601DateFormatter().date(from: $0) ?? ISO8601DateFormatter.fractional.date(from: $0) } ?? mtime
            let title = body.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) } ?? String(parts.last!.dropLast(3))
            out.append(Measured(path: rel, folder: parts.count > 1 ? parts[0] : ".", title: title, words: wordCount(body), body: body, updated: updated))
        }
        return out.sorted { $0.path < $1.path }
    }

    static func frontMatter(_ s: String) -> ([String: String], String) {
        guard s.hasPrefix("---\n"), let end = s.range(of: "\n---\n", range: s.index(s.startIndex, offsetBy: 4)..<s.endIndex) else { return ([:], s) }
        var meta: [String: String] = [:]
        for line in s[s.index(s.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
            if let c = line.firstIndex(of: ":") { meta[String(line[..<c]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces) }
        }
        return (meta, String(s[end.upperBound...]))
    }

    static func wordCount(_ body: String) -> Int { body.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }

    static func budget(for n: Measured) -> Int {
        if n.path == "README.md" { return readmeBudget }
        return n.folder == "People" || n.folder == "Groups" ? personBudget : noteBudget
    }

    /// `[[Name]]`, `[[Name|alias]]`, `[[Name#heading]]`: the name must match a note's title or file name, case-insensitively.
    static let linkPattern = try! NSRegularExpression(pattern: #"\[\[([^\]\[|#]+)(?:[#|][^\]]*)?\]\]"#)
    static func dangling(in all: [Measured]) -> [Dangling] {
        var known = Set<String>()
        for n in all { known.insert(n.title.lowercased()); known.insert(n.fileName.lowercased()) }
        var seen = Set<String>(), out: [Dangling] = []
        for n in all {
            let s = n.body as NSString
            for m in linkPattern.matches(in: n.body, range: NSRange(location: 0, length: s.length)) {
                let name = s.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let key = name.lowercased()
                guard !name.isEmpty, !known.contains(key), !seen.contains(key) else { continue }
                seen.insert(key); out.append(Dangling(name: name, path: n.path))
            }
        }
        return out.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Two notes in the same folder (People, or Groups) whose titles share a PersonKey, or whose first word matches when
    /// one title is a single word: "Arjun" and "Arjun Mehta" may be one person; "Arjun Mehta" and "Arjun Rao" are two.
    static func duplicates(in all: [Measured]) -> [Pair] {
        var out: [Pair] = []
        for folder in ["People", "Groups"] {
            let notes = all.filter { $0.folder == folder }
            for i in notes.indices { for j in notes.indices where j > i && PersonKey.same(notes[i].title, notes[j].title) { out.append(Pair(a: notes[i].path, b: notes[j].path)) } }
        }
        return out
    }

    /// The oldest "⏳" line inside the status block, in days: its first "d MMM" read against now's year, and the year
    /// before when that would put it in the future.
    static let markers = [("<!-- brownie:status -->", "<!-- /brownie:status -->"), ("<!-- brownie:between-you -->", "<!-- /brownie:between-you -->")]
    static let dayPattern = try! NSRegularExpression(pattern: #"\b(\d{1,2}) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\b"#)
    static func oldestPending(in body: String, now: Date, timeZone: TimeZone) -> Int? {
        var block: Substring?
        for (o, c) in markers { if let s = body.range(of: o), let e = body.range(of: c, range: s.upperBound..<body.endIndex) { block = body[s.upperBound..<e.lowerBound]; break } }
        guard let block else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let year = cal.component(.year, from: now)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "d MMM yyyy"
        var oldest: Int?
        for line in block.split(separator: "\n") where line.contains("⏳") {
            let s = String(line) as NSString
            guard let m = dayPattern.firstMatch(in: String(line), range: NSRange(location: 0, length: s.length)) else { continue }
            guard var date = f.date(from: s.substring(with: m.range) + " \(year)") else { continue }
            if date > now, let back = cal.date(byAdding: .year, value: -1, to: date) { date = back }
            let days = Int(now.timeIntervalSince(date) / 86400)
            oldest = max(oldest ?? 0, days)
        }
        return oldest
    }

    /// Words now against the newest record that is at least a week old (a little slack, since nights are never exactly 24 h apart).
    static func netWords(now words: Int, at: Date, history: [VaultHealth]) -> Int? {
        let cutoff = at.addingTimeInterval(-6.5 * 86400)
        guard let then = history.filter({ $0.at <= cutoff }).max(by: { $0.at < $1.at }) else { return nil }
        return words - then.words
    }

    // MARK: the sentence

    /// "33 notes · 16,900 words · 2 over budget · 1 quiet person · 3 dangling links · 1 pair that may be one person".
    /// Only what is there: a tidy vault reads "33 notes · 16,900 words · nothing to tidy".
    public var line: String {
        func n(_ v: Int, _ one: String, _ many: String) -> String { "\(Self.grouped(v)) \(v == 1 ? one : many)" }
        var parts = [n(notes, "note", "notes"), n(words, "word", "words")]
        if !overBudget.isEmpty { parts.append("\(overBudget.count) over budget") }
        if !quietPeople.isEmpty { parts.append(n(quietPeople.count, "quiet person", "quiet people")) }
        if !danglingLinks.isEmpty { parts.append(n(danglingLinks.count, "dangling link", "dangling links")) }
        if !duplicateSuspects.isEmpty { parts.append(n(duplicateSuspects.count, "pair that may be one person", "pairs that may be one person")) }
        if parts.count == 2 { parts.append("nothing to tidy") }
        return parts.joined(separator: " · ")
    }
    static func grouped(_ v: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US_POSIX"); f.groupingSeparator = ","; f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    // MARK: history

    /// The record joins the history newest first: one per calendar day (a second run on the same day replaces the
    /// first), at most `keep`, and nothing older than `keep` days — the vault-health half of the store's retention.
    public static func append(_ h: VaultHealth, to history: [VaultHealth], keep: Int = VaultHealth.keep, calendar: Calendar = .current) -> [VaultHealth] {
        let floor = h.at.addingTimeInterval(-Double(keep) * 86400)
        let rest = history.filter { !calendar.isDate($0.at, inSameDayAs: h.at) && $0.at >= floor }
        return Array(([h] + rest).sorted { $0.at > $1.at }.prefix(keep))
    }
    /// The newest record.
    public static func latest(from history: [VaultHealth]) -> VaultHealth? { history.max { $0.at < $1.at } }
    public static func latest(from json: String?) -> VaultHealth? { latest(from: history(from: json)) }

    public static func history(from json: String?) -> [VaultHealth] {
        guard let j = json, let d = j.data(using: .utf8) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode([VaultHealth].self, from: d)) ?? []
    }
    public static func json(_ history: [VaultHealth]) -> String? {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        return (try? enc.encode(history)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The nightly measure: compute against the stored history, append, save, return. Never throws — a store that
    /// will not answer leaves last night's record standing.
    @discardableResult
    public static func nightly(root: URL, now: Date, store: any RunStore, timeZone: TimeZone = .current) async -> VaultHealth {
        let history = history(from: try? await store.value(SettingKey.vaultHealth))
        let h = compute(root: root, now: now, history: history, timeZone: timeZone)
        var cal = Calendar.current; cal.timeZone = timeZone
        try? await store.setValue(SettingKey.vaultHealth, json(append(h, to: history, calendar: cal)))
        return h
    }
}

extension ISO8601DateFormatter {
    /// `updated:` written by hand or by another tool may carry fractional seconds.
    static let fractional: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
}
