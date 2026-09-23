import Foundation
import Domain
import Knowledge
import Support

/// A corpus for judging the note prompts: every note the user rated, with the words that were rated, the verdict and
/// the summaries the note was written from — one JSON file per rating under Application Support/Evals/notes. Written
/// the moment a note is rated and again at FINISH for every rating of the last thirty days, so the evidence beside a
/// rating grows as the nights go by. Nothing in the app reads it back: it is for a person, or an eval runner, to open.
public enum NoteEvalExport {
    public static let window: TimeInterval = SummaryRecord.evidenceWindow
    public static let cap = 60
    public static var folder: URL { Paths.ensure(Paths.applicationSupport.appendingPathComponent("Evals", isDirectory: true).appendingPathComponent("notes", isDirectory: true)) }
    private static let log = Log("evals")

    public struct Record: Codable, Equatable, Sendable {
        public var path: String, title: String, body: String, contentHash: String
        public var verdict: NoteFeedback.Verdict
        public var reason: String?
        public var at: Date
        public var summaries: [Summary]
        public init(path: String, title: String, body: String, contentHash: String, verdict: NoteFeedback.Verdict, reason: String?, at: Date, summaries: [Summary]) {
            self.path = path; self.title = title; self.body = body; self.contentHash = contentHash; self.verdict = verdict; self.reason = reason; self.at = at; self.summaries = summaries
        }
    }
    /// One summary as the corpus keeps it: the row's words and dates, its source and chat, without the store's ids for buckets and runs.
    public struct Summary: Codable, Equatable, Sendable {
        public let id: Int64, sid: String?, source: String, bucketName: String, kind: String, title: String, text: String
        public let itemDate: Date?, createdAt: Date, mergedAt: Date?
        public init(_ r: SummaryRecord) {
            id = r.id; sid = r.sid; source = r.source.rawValue; bucketName = r.bucketName; kind = r.kind.rawValue; title = r.title; text = r.text
            itemDate = r.itemDate; createdAt = r.createdAt; mergedAt = r.mergedAt
        }
    }

    // MARK: selection

    /// The evidence for one note: rows the notes absorbed in the last thirty days that name the note's title or one of
    /// its aliases — in the chat's name, the row's title or its text — newest merged first, at most sixty.
    public static func evidence(title: String, aliases: [String], in rows: [SummaryRecord], now: Date) -> [SummaryRecord] {
        let names = ([title] + aliases).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return [] }
        return rows
            .filter { r in r.mergedAt.map { now.timeIntervalSince($0) < window && now.timeIntervalSince($0) >= 0 } ?? false }
            .filter { r in names.contains { n in mentions(r.bucketName, n) || mentions(r.title, n) || mentions(r.text, n) } }
            .sorted { ($0.mergedAt ?? .distantPast, $0.id) > ($1.mergedAt ?? .distantPast, $1.id) }
            .prefix(cap).map { $0 }
    }
    /// Whether `text` names `name` as a whole word, whatever the case or accents: "Meera" is in "Meera's flight" and not in "Ameera".
    static func mentions(_ text: String, _ name: String) -> Bool {
        var from = text.startIndex
        while let r = text.range(of: name, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
            let before = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
            let after = r.upperBound == text.endIndex ? nil : text[r.upperBound]
            if !(before?.isLetter ?? false) && !(before?.isNumber ?? false) && !(after?.isLetter ?? false) && !(after?.isNumber ?? false) { return true }
            from = r.upperBound
        }
        return false
    }

    // MARK: the file

    /// `<day the rating was made>-<the note's path as a slug>.json`, so a second export of the same rating lands on the same file.
    public static func fileName(_ fb: NoteFeedback, timeZone: TimeZone) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd"
        return "\(f.string(from: fb.at))-\(slug(fb.path)).json"
    }
    /// Lower case, letters and digits kept, everything else one hyphen: "People/Meera Iyer.md" → "people-meera-iyer".
    static func slug(_ s: String) -> String {
        let stem = s.hasSuffix(".md") ? String(s.dropLast(3)) : s
        let folded = stem.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
        let parts = folded.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        return parts.isEmpty ? "note" : parts.joined(separator: "-")
    }

    /// The body kept is the one that was rated: the note on disk when it still hashes to the rated hash, else the file
    /// already on record when that does; when neither does, the note on disk — or, if the note is gone, the file.
    /// The evidence is always the fresh selection.
    static func merged(existing: Record?, fresh: Record) -> Record {
        guard let existing else { return fresh }
        var out = fresh
        if NoteMeta.hash(fresh.body) == fresh.contentHash { out.body = fresh.body }
        else if NoteMeta.hash(existing.body) == fresh.contentHash || fresh.body.isEmpty { out.body = existing.body }
        return out
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    /// One rating to its file: the note as it stands (nil when it is gone), the evidence picked from `rows`. Returns where
    /// it landed, or nil when there is no body to write — the note is gone and nothing was on record.
    @discardableResult
    public static func write(_ fb: NoteFeedback, note: Note?, rows: [SummaryRecord], people: [Person], folder: URL, now: Date, timeZone: TimeZone) throws -> URL? {
        let url = folder.appendingPathComponent(fileName(fb, timeZone: timeZone))
        let existing = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Record.self, from: $0) }
        guard note != nil || existing != nil else { return nil }
        let aliases = (note?.meta.aliases ?? []) + people.filter { $0.notePath == fb.path }.flatMap { [$0.name] + $0.aliases }
        let picked = evidence(title: note?.title ?? fb.title, aliases: aliases, in: rows, now: now)
        let fresh = Record(path: fb.path, title: note?.title ?? fb.title, body: note?.body ?? "", contentHash: fb.contentHash, verdict: fb.verdict, reason: fb.reason, at: fb.at, summaries: picked.map(Summary.init))
        let record = merged(existing: existing, fresh: fresh)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(record).write(to: url, options: .atomic)
        return url
    }

    /// FINISH: every rating of the last thirty days, each with its note read from the store and the evidence as the store
    /// holds it tonight. Returns how many files were written; one that fails is logged and does not stop the rest.
    public static func exportAll(_ list: NoteFeedbackList, knowledge: any KnowledgeStore, store: any RunStore, people: [Person], folder: URL, now: Date, timeZone: TimeZone) async -> Int {
        let recent = list.recent(within: window, now: now)
        guard !recent.isEmpty else { return 0 }
        let rows = (try? await store.summaries(since: nil)) ?? []
        var written = 0
        for fb in recent {
            let note = try? await knowledge.note(at: fb.path)
            do { if try write(fb, note: note, rows: rows, people: people, folder: folder, now: now, timeZone: timeZone) != nil { written += 1 } }
            catch { log.warn("eval export of \(fb.path): \(error)") }
        }
        if written > 0 { log.info("\(written) rated note(s) exported for evaluation") }
        return written
    }
}
