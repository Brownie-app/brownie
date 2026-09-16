import Foundation
import Domain
import Support

/// One person as the app knows them: every spelling a source has used, every stable handle, and the one
/// People note that is theirs. `notSame` lists people the user said are somebody else, so the merge
/// banner never asks twice.
public struct Person: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public var name: String
    public var aliases: [String]
    public var handles: [String]
    public var notePath: String?
    public var notSame: [String]
    public let firstSeen: Date
    public var lastSeen: Date

    public init(id: String, name: String, aliases: [String] = [], handles: [String] = [], notePath: String? = nil, notSame: [String] = [], firstSeen: Date, lastSeen: Date) {
        self.id = id; self.name = name; self.aliases = aliases; self.handles = handles; self.notePath = notePath; self.notSame = notSame; self.firstSeen = firstSeen; self.lastSeen = lastSeen
    }

    /// Every spelling's key, the name's first, without repeats or empties.
    public var keys: [String] {
        var out: [String] = []
        for k in ([name] + aliases).map(PersonKey.normalise) where !k.isEmpty && !out.contains(k) { out.append(k) }
        return out
    }
    /// The first words of every key: what a first-name-only label is matched against.
    var firstWords: Set<String> { Set(keys.compactMap { $0.split(separator: " ").first.map(String.init) }) }
}

/// The people registry: `<vault>/.brownie/people.json`, a hidden folder the note store and the brain's file
/// tools never list. Labels come in from chats and loops; handles tie a renamed chat to the same person;
/// the note builder is told who exists so it never opens a second file under another spelling.
public actor PersonRegistry {
    public static let directory = ".brownie"
    public static let file = "people.json"
    public nonisolated let fileURL: URL
    private var records: [Person] = []
    private let now: @Sendable () -> Date
    private let log = Log("people")

    private struct File: Codable { var version = 1; var people: [Person] }

    public init(vault: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        fileURL = vault.appendingPathComponent(Self.directory, isDirectory: true).appendingPathComponent(Self.file)
        self.now = now
    }

    // MARK: persistence

    /// Reads the file; a missing or unreadable file is an empty registry, never an error.
    public func load() {
        guard let d = try? Data(contentsOf: fileURL) else { records = []; return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let f = try? dec.decode(File.self, from: d) { records = f.people.sorted { ($0.firstSeen, $0.id) < ($1.firstSeen, $1.id) } }
        else { log.warn("people.json could not be read; starting empty"); records = [] }
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(File(people: records)).write(to: fileURL, options: .atomic)
    }

    public func people() -> [Person] { records }
    public func person(_ id: String) -> Person? { records.first { $0.id == id } }

    // MARK: seeding from the notes

    /// One person per existing People note, once: a note already owned by someone is left alone; a note whose
    /// title resolves to a person without a note becomes theirs; any other note starts a new person. Notes that
    /// vanished (renamed or deleted by the brain or the user) release their person's path so a new title can claim it.
    public func seed(from folders: [KnowledgeFolder]) {
        let present = Set(folders.flatMap { $0.notes.map(\.relativePath) })
        for i in records.indices where records[i].notePath.map({ !present.contains($0) }) ?? false { records[i].notePath = nil }
        guard let peopleFolder = folders.first(where: { $0.name == "People" }) else { return }
        for note in peopleFolder.notes.sorted(by: { $0.relativePath < $1.relativePath }) {
            if records.contains(where: { $0.notePath == note.relativePath }) { continue }
            if let id = resolve(label: note.title, handle: nil), let i = index(id), records[i].notePath == nil {
                records[i].notePath = note.relativePath
                learn(label: note.title, at: i)
                continue
            }
            records.append(Person(id: Self.newID(), name: PersonKey.displayName(note.title), aliases: [note.title], notePath: note.relativePath, firstSeen: now(), lastSeen: now()))
        }
    }

    // MARK: resolving and registering

    /// Who a label names: the handle decides when known; then any spelling with the same key; then a first
    /// name alone, but only when exactly one person carries it — two Arjuns and the answer is nobody.
    public func resolve(label: String, handle: String?) -> String? {
        if let h = handle, !h.isEmpty, let p = records.first(where: { $0.handles.contains(h) }) { return p.id }
        let key = PersonKey.normalise(label)
        guard !key.isEmpty else { return nil }
        if let p = records.first(where: { $0.keys.contains(key) }) { return p.id }
        guard !key.contains(" ") else { return nil }
        let byFirstName = records.filter { $0.firstWords.contains(key) }
        return byFirstName.count == 1 ? byFirstName[0].id : nil
    }

    /// The person for a label, created when unknown. The label is learned as an alias and the handle as theirs.
    @discardableResult
    public func register(label: String, handle: String?) -> String {
        let id = resolve(label: label, handle: handle) ?? {
            let p = Person(id: Self.newID(), name: PersonKey.displayName(label), aliases: [], firstSeen: now(), lastSeen: now())
            records.append(p); return p.id
        }()
        let i = index(id)!
        learn(label: label, at: i)
        if let h = handle, !h.isEmpty, !records[i].handles.contains(h) { records[i].handles.append(h) }
        records[i].lastSeen = now()
        return id
    }

    /// A new spelling joins the aliases; a fuller name than the one on file ("Kanika Pandey" after "Kanika") becomes the name.
    private func learn(label: String, at i: Int) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed != records[i].name, !records[i].aliases.contains(trimmed) { records[i].aliases.append(trimmed) }
        let shown = PersonKey.displayName(trimmed)
        if !PersonKey.normalise(records[i].name).contains(" "), PersonKey.normalise(shown).contains(" ") { records[i].name = shown }
    }

    public func notePath(for id: String) -> String? { person(id)?.notePath }
    public func setNotePath(_ path: String?, for id: String) { if let i = index(id) { records[i].notePath = path } }

    /// The note for a label: the registry's answer first; otherwise a title with exactly the same key.
    /// A first name alone never claims a note by title — that is how "Arjun" leaked into "Arjun Mehta".
    public func notePath(forLabel label: String, handle: String?, amongNotes notes: [Note]) -> String? {
        if let id = resolve(label: label, handle: handle), let p = notePath(for: id) { return p }
        return notes.first { PersonKey.sameKey($0.title, label) }?.relativePath
    }

    // MARK: merging and keeping apart

    /// Two records become one: the kept person takes every alias and handle, keeps their note (or takes the
    /// dropped one's when they had none), and the dropped person is gone from every `notSame` list too.
    @discardableResult
    public func merge(keep: String, drop: String) -> Person? {
        guard keep != drop, let k = index(keep), let d = index(drop) else { return person(keep) }
        let dropped = records[d]
        for a in [dropped.name] + dropped.aliases where a != records[k].name && !records[k].aliases.contains(a) { records[k].aliases.append(a) }
        for h in dropped.handles where !records[k].handles.contains(h) { records[k].handles.append(h) }
        if records[k].notePath == nil { records[k].notePath = dropped.notePath }
        records[k].notSame = (records[k].notSame + dropped.notSame).filter { $0 != keep && $0 != drop }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        records[k].lastSeen = max(records[k].lastSeen, dropped.lastSeen)
        records.remove(at: d)
        for i in records.indices { records[i].notSame.removeAll { $0 == drop } }
        return person(keep)
    }

    public func keepSeparate(_ a: String, _ b: String) {
        guard let i = index(a), let j = index(b), a != b else { return }
        if !records[i].notSame.contains(b) { records[i].notSame.append(b) }
        if !records[j].notSame.contains(a) { records[j].notSame.append(a) }
    }

    /// Pairs that look like one person: the same two-word key, or the same first word with one of them known by
    /// a first name alone — unless the user has said they are two. The first of each pair is the better one to keep:
    /// the one with a note, then the fuller name, then the older record.
    public func suspects() -> [(Person, Person)] {
        var out: [(Person, Person)] = []
        for i in records.indices {
            for j in records.indices where j > i {
                let a = records[i], b = records[j]
                if a.notSame.contains(b.id) || b.notSame.contains(a.id) { continue }
                guard a.keys.contains(where: { ka in b.keys.contains { kb in PersonKey.same(ka, kb) } }) else { continue }
                out.append(Self.keepFirst(a, b))
            }
        }
        return out
    }

    static func keepFirst(_ a: Person, _ b: Person) -> (Person, Person) {
        let ra = ((a.notePath == nil ? 0 : 1), a.name.split(separator: " ").count), rb = ((b.notePath == nil ? 0 : 1), b.name.split(separator: " ").count)
        return ra >= rb ? (a, b) : (b, a)
    }

    // MARK: the brain's roster

    /// The `PEOPLE:` lines of the note builder's header: who exists and where they are written, capped.
    public static func headerLines(_ people: [Person], cap: Int = 200) -> [String] {
        people.sorted { ($0.notePath == nil ? 1 : 0, $0.name.lowercased()) < ($1.notePath == nil ? 1 : 0, $1.name.lowercased()) }.prefix(cap).map { p in
            var also: [String] = []
            for a in p.aliases.map(PersonKey.displayName) where a.lowercased() != p.name.lowercased() && !also.contains(a) { also.append(a) }
            let alsoLine = also.isEmpty ? "" : " (also: " + also.prefix(4).joined(separator: ", ") + ")"
            return "\(p.name) — \(p.notePath ?? "no note yet")" + alsoLine
        }
    }

    // MARK: helpers

    private func index(_ id: String) -> Int? { records.firstIndex { $0.id == id } }
    static func newID() -> String { "p-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12) }
}

/// The text edits a merge makes to the notes, pure so they can be checked without a vault.
public enum PersonNotes {
    /// The kept note with the dropped one's body folded in under its own heading; the dropped title line is not repeated.
    public static func appendMerged(into keptBody: String, droppedBody: String, droppedName: String, date: Date) -> String {
        let lines = droppedBody.split(separator: "\n", omittingEmptySubsequences: false)
        let body = (lines.first?.hasPrefix("# ") == true ? lines.dropFirst() : lines[...]).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "d MMM yyyy"
        let head = "## Merged from \(droppedName) (\(f.string(from: date)))"
        return keptBody.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + head + "\n" + (body.isEmpty ? "_Nothing else was written there._" : body) + "\n"
    }

    /// `[[Old]]` and `[[Old|shown]]` become links to the kept note; other text is untouched. Nil when nothing changed.
    public static func rewriteLinks(in text: String, from old: String, to new: String) -> String? {
        guard old != new else { return nil }
        var out = text
        out = out.replacingOccurrences(of: "[[\(old)]]", with: "[[\(new)]]")
        out = out.replacingOccurrences(of: "[[\(old)|", with: "[[\(new)|")
        return out == text ? nil : out
    }
}
