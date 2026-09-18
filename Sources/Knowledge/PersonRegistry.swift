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
    /// The vault's People directory — asked, when the listing shows no People folder, whether it holds any note at all.
    private nonisolated let peopleURL: URL
    private var records: [Person] = []
    /// What the file held when it was read, and the merges made here since: `save` reconciles against both, so a
    /// merge or "keep separate" the app made while a run held its own copy is not written over.
    private var loaded: [Person] = []
    private var mergesSinceLoad: [(keep: String, drop: String)] = []
    private var removedSinceLoad: [String] = []
    private let now: @Sendable () -> Date
    /// The user's own names: never a person here, whatever a note is titled or a loop says.
    public nonisolated let selfNames: [String]
    private let log = Log("people")

    private struct File: Codable { var version = 1; var people: [Person] }

    public init(vault: URL, now: @escaping @Sendable () -> Date = { Date() }, selfNames: [String] = []) {
        fileURL = vault.appendingPathComponent(Self.directory, isDirectory: true).appendingPathComponent(Self.file)
        peopleURL = vault.appendingPathComponent("People", isDirectory: true)
        self.now = now; self.selfNames = SelfNames.clean(selfNames)
    }
    nonisolated func isSelf(_ label: String) -> Bool { SelfNames.isSelf(label, among: selfNames) }

    // MARK: persistence

    /// Reads the file; a missing or unreadable file is an empty registry, never an error.
    public func load() {
        if let d = try? Data(contentsOf: fileURL) {
            if let people = Self.decode(d) { records = people } else { log.warn("people.json could not be read; starting empty"); records = [] }
        } else { records = [] }
        loaded = records; mergesSinceLoad = []
    }

    /// Writes the registry — on top of whatever reached the file since `load`, not over it. The run holds its
    /// copy for the length of a sync; a merge or "keep separate" the user made in the app meanwhile is taken
    /// from the file, and this instance's own merges, spellings, handles and note paths are applied to that.
    public func save() throws {
        if let d = try? Data(contentsOf: fileURL), let disk = Self.decode(d), disk != loaded {
            records = Self.reconcile(disk: disk, mine: records, loaded: loaded, merges: mergesSinceLoad)
            records.removeAll { removedSinceLoad.contains($0.id) }   // a record this instance removed stays removed
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(File(people: records)).write(to: fileURL, options: .atomic)
        loaded = records; mergesSinceLoad = []; removedSinceLoad = []
    }

    /// A record that should never have existed — the user's own, found by the migration — is gone, from every
    /// `notSame` list too. Nothing else removes a person: a merge folds, an archive keeps.
    /// Records whose name is nobody in particular ("another contact", "someone"), opened by a loop written around a
    /// missing name: gone, with their note path released. Returns how many went.
    @discardableResult
    public func removeNobodies(_ isNobody: (String) -> Bool) -> Int {
        let gone = records.filter { isNobody($0.name) }
        for g in gone { remove(g.id) }
        return gone.count
    }
    public func remove(_ id: String) {
        guard let i = index(id) else { return }
        records.remove(at: i); removedSinceLoad.append(id)
        for j in records.indices { records[j].notSame.removeAll { $0 == id } }
    }

    private static func decode(_ d: Data) -> [Person]? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(File.self, from: d))?.people.sorted { ($0.firstSeen, $0.id) < ($1.firstSeen, $1.id) }
    }

    /// The file's people with this instance's work replayed on them: its merges first, then each of its records
    /// onto the file's record with the same id — or, when the app merged that id away, onto whichever record now
    /// carries one of its handles or spellings. A record born here is appended; one the app deleted stays deleted.
    /// A note path is taken only when the file's record has none, and released only when this instance saw that
    /// same file vanish. `notSame` lists are united, then pruned to people who still exist.
    static func reconcile(disk: [Person], mine: [Person], loaded: [Person], merges: [(keep: String, drop: String)]) -> [Person] {
        var out = disk
        for m in merges { Self.merge(keep: m.keep, drop: m.drop, in: &out) }
        for m in mine {
            let spellings = [m.name] + m.aliases
            let t = out.firstIndex { $0.id == m.id }
                ?? out.firstIndex { p in p.handles.contains { m.handles.contains($0) } }
                ?? out.firstIndex { p in ([p.name] + p.aliases).contains { s in spellings.contains { Self.spellsAlike($0, s) } } }
            guard let t else {
                if !loaded.contains(where: { $0.id == m.id }) { out.append(m) }
                continue
            }
            for s in spellings { Self.learn(label: s, into: &out[t]) }
            for h in m.handles where !out[t].handles.contains(h) { out[t].handles.append(h) }
            if out[t].notePath == nil, let p = m.notePath, !out.contains(where: { $0.notePath == p }) { out[t].notePath = p }
            if m.notePath == nil, let was = loaded.first(where: { $0.id == m.id })?.notePath, out[t].notePath == was { out[t].notePath = nil }
            for n in m.notSame where !out[t].notSame.contains(n) { out[t].notSame.append(n) }
            out[t].lastSeen = max(out[t].lastSeen, m.lastSeen)
        }
        let ids = Set(out.map(\.id))
        for i in out.indices { let me = out[i].id; out[i].notSame.removeAll { !ids.contains($0) || $0 == me } }
        return out
    }

    public func people() -> [Person] { records }
    public func person(_ id: String) -> Person? { records.first { $0.id == id } }

    // MARK: seeding from the notes

    /// One person per existing People note, once: a note already owned by someone is left alone; a note whose
    /// title is a spelling of a person without a note becomes theirs, exact spellings before same-key ones (so
    /// "Kanika Pandey.md" goes to the Kanika Pandey on file even when "Kanika Pandey Loadmill.md" sorts first);
    /// any other note starts a new person. Notes that vanished (renamed or deleted by the brain or the user)
    /// release their person's path so a new title can claim it. A listing with no People folder is one of two
    /// things: the folder holds no note (every path into it is dead, and is released), or the listing failed on one
    /// unreadable file and arrived empty — the directory itself tells which, and a failed listing strips nothing.
    public func seed(from folders: [KnowledgeFolder]) {
        let present = Set(folders.flatMap { $0.notes.map(\.relativePath) })
        let peopleFolder = folders.first(where: { $0.name == "People" })
        guard peopleFolder != nil || peopleDirectoryHoldsNoNote() else { return }
        for i in records.indices where records[i].notePath.map({ !present.contains($0) }) ?? false { records[i].notePath = nil }
        guard let peopleFolder else { return }
        // A note titled after the user is nobody's: the migration moves it out of People/; until then it claims no record.
        let notes = peopleFolder.notes.filter { !isSelf($0.title) }.sorted(by: { $0.relativePath < $1.relativePath })
        for note in notes where !records.contains(where: { $0.notePath == note.relativePath }) {
            if let i = exactIndex(label: note.title), records[i].notePath == nil { records[i].notePath = note.relativePath }
        }
        for note in notes {
            if records.contains(where: { $0.notePath == note.relativePath }) { continue }
            if let id = resolve(label: note.title, handle: nil), let i = index(id), records[i].notePath == nil {
                records[i].notePath = note.relativePath
                Self.learn(label: note.title, into: &records[i])
                continue
            }
            records.append(Person(id: Self.newID(), name: PersonKey.displayName(note.title), aliases: [note.title], notePath: note.relativePath, firstSeen: now(), lastSeen: now()))
        }
    }

    /// True when the People directory is missing or has no Markdown note anywhere beneath it (Archive/ included).
    private func peopleDirectoryHoldsNoNote() -> Bool {
        guard let e = FileManager.default.enumerator(at: peopleURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return true }
        for case let u as URL in e where u.pathExtension == "md" && (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { return false }
        return true
    }

    // MARK: resolving and registering

    /// Who a label names: the handle decides when known; then the one person with a spelling of the same key;
    /// when two people share the key ("Kanika Pandey" and "Kanika Pandey Loadmill", kept apart by the user or
    /// not yet merged) the one spelled exactly like the label, and nobody when neither is — never the first on
    /// file; then a first name alone, but only when exactly one person carries it — two Arjuns and the answer is nobody.
    public func resolve(label: String, handle: String?) -> String? { Self.resolve(label: label, handle: handle, among: records) }
    /// The same rule over a roster handed out by `people()`, for callers that hold the list rather than the registry (the brain's file tools).
    public nonisolated static func resolve(label: String, handle: String?, among records: [Person]) -> String? {
        if let h = handle, !h.isEmpty, let p = records.first(where: { $0.handles.contains(h) }) { return p.id }
        let key = PersonKey.normalise(label)
        guard !key.isEmpty else { return nil }
        let byKey = records.filter { $0.keys.contains(key) }
        if byKey.count == 1 { return byKey[0].id }
        if byKey.count > 1 { return Self.exactIndex(label: label, among: byKey).map { byKey[$0].id } }
        guard !key.contains(" ") else { return nil }
        let byFirstName = records.filter { $0.firstWords.contains(key) }
        return byFirstName.count == 1 ? byFirstName[0].id : nil
    }

    /// The person for a label, created when unknown. The label is learned as an alias and the handle as theirs.
    /// A label that could be either of two people sharing its key, and spells neither exactly, is nobody's to
    /// learn: nothing is attached (a handle attached by a guess would route every later ask to the wrong note,
    /// and no "keep separate" could undo it) and no third record is opened; the likelier of the two is returned.
    /// The user's own name opens no record and learns nothing: it comes back as the empty id, which names nobody.
    @discardableResult
    public func register(label: String, handle: String?) -> String {
        guard !isSelf(label) else { return "" }
        if let id = resolve(label: label, handle: handle) {
            let i = index(id)!
            Self.learn(label: label, into: &records[i])
            if let h = handle, !h.isEmpty, !records[i].handles.contains(h) { records[i].handles.append(h) }
            records[i].lastSeen = now()
            return id
        }
        let key = PersonKey.normalise(label), shared = records.filter { $0.keys.contains(key) }
        if shared.count > 1 { return shared.dropFirst().reduce(shared[0]) { Self.keepFirst($0, $1).0 }.id }
        var p = Person(id: Self.newID(), name: PersonKey.displayName(label), aliases: [], firstSeen: now(), lastSeen: now())
        Self.learn(label: label, into: &p)
        if let h = handle, !h.isEmpty { p.handles.append(h) }
        records.append(p)
        return p.id
    }

    /// A new spelling joins the aliases — every spelling a source used, the name's own included, so an exact
    /// match can tell "Arjun Mehta" from the "Arjun Mehta (Landlord)" whose shown name is the same; a fuller
    /// name than the one on file ("Kanika Pandey" after "Kanika") becomes the name.
    private static func learn(label: String, into p: inout Person) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !p.aliases.contains(trimmed) { p.aliases.append(trimmed) }
        let shown = PersonKey.displayName(trimmed)
        if !PersonKey.normalise(p.name).contains(" "), PersonKey.normalise(shown).contains(" ") { p.name = shown }
    }

    /// The one record that was seen spelled as the label (case and surrounding space aside), or failing that the
    /// one whose shown name is the label; nil when none or several are — "Kanika Pandey" spelled by two records
    /// decides nothing.
    private func exactIndex(label: String) -> Int? { Self.exactIndex(label: label, among: records) }
    private static func exactIndex(label: String, among pool: [Person]) -> Int? {
        for spellings in [{ (p: Person) in p.aliases }, { (p: Person) in [p.name] }] {
            let hits = pool.indices.filter { i in spellings(pool[i]).contains { spellsAlike($0, label) } }
            if hits.count == 1 { return hits[0] }
            if hits.count > 1 { return nil }
        }
        return nil
    }
    static func spellsAlike(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    public func notePath(for id: String) -> String? { person(id)?.notePath }
    public func setNotePath(_ path: String?, for id: String) { if let i = index(id) { records[i].notePath = path } }

    /// The note for a label: the registry's answer, and nothing else once the registry knows who the label is —
    /// a known person with no note of their own gets no note, because every same-key title on file is somebody
    /// else's (a namesake the user keeps separate, once the person's own note was deleted or renamed), and
    /// nobody's note is better than the wrong person's. When the registry knows nobody by the label, and nobody by
    /// its key either, the one title with exactly the same key answers, or among several the one that is the label
    /// itself — none of them when the label spells neither.
    /// A first name alone never claims a note by title — that is how "Arjun" leaked into "Arjun Mehta".
    public func notePath(forLabel label: String, handle: String?, amongNotes notes: [Note]) -> String? {
        if let id = resolve(label: label, handle: handle) { return notePath(for: id) }
        let key = PersonKey.normalise(label)
        guard !key.isEmpty, !records.contains(where: { $0.keys.contains(key) }) else { return nil }
        let same = notes.filter { PersonKey.sameKey($0.title, label) }
        if same.count == 1 { return same[0].relativePath }
        return same.first { Self.spellsAlike($0.title, label) }?.relativePath
    }

    // MARK: merging and keeping apart

    /// Two records become one: the kept person takes every alias and handle, keeps their note (or takes the
    /// dropped one's when they had none), and the dropped person is gone from every `notSame` list too.
    @discardableResult
    public func merge(keep: String, drop: String) -> Person? {
        guard keep != drop, index(keep) != nil, index(drop) != nil else { return person(keep) }
        Self.merge(keep: keep, drop: drop, in: &records)
        mergesSinceLoad.append((keep, drop))
        return person(keep)
    }

    static func merge(keep: String, drop: String, in records: inout [Person]) {
        guard keep != drop, let k = records.firstIndex(where: { $0.id == keep }), let d = records.firstIndex(where: { $0.id == drop }) else { return }
        let dropped = records[d]
        for a in [dropped.name] + dropped.aliases where a != records[k].name && !records[k].aliases.contains(a) { records[k].aliases.append(a) }
        for h in dropped.handles where !records[k].handles.contains(h) { records[k].handles.append(h) }
        if records[k].notePath == nil { records[k].notePath = dropped.notePath }
        records[k].notSame = (records[k].notSame + dropped.notSame).filter { $0 != keep && $0 != drop }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        records[k].lastSeen = max(records[k].lastSeen, dropped.lastSeen)
        records.remove(at: d)
        for i in records.indices { records[i].notSame.removeAll { $0 == drop } }
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

    /// After a merge, whether a ledger row under `label` (and `handle`) was the dropped person's — by the roster as it
    /// stood before the merge, so the row is renamed only when it resolved to them: never merely because it shares
    /// their key, which a third person the user keeps apart ("Kanika Pandey Loadmill" beside "Kanika Pandey") does too.
    public nonisolated static func belonged(label: String, handle: String?, to dropped: String, among before: [Person]) -> Bool {
        resolve(label: label, handle: handle, among: before) == dropped
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
    /// The kept note with the dropped one's body folded in under its own heading; the dropped title line is not
    /// repeated, and neither is any block between the given markers — the status block Brownie keeps is rebuilt
    /// in the kept note's own block on the next run, and a second copy under "Merged from" would never be updated again.
    public static func appendMerged(into keptBody: String, droppedBody: String, droppedName: String, date: Date, stripping blocks: [(open: String, close: String)] = []) -> String {
        let lines = removingBlocks(droppedBody, blocks).split(separator: "\n", omittingEmptySubsequences: false)
        let body = (lines.first?.hasPrefix("# ") == true ? lines.dropFirst() : lines[...]).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "d MMM yyyy"
        let head = "## Merged from \(droppedName) (\(f.string(from: date)))"
        return keptBody.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + head + "\n" + (body.isEmpty ? "_Nothing else was written there._" : body) + "\n"
    }

    /// The text without every span from an opening marker to its closing one (and the line break after it); an
    /// opener with no closer after it is left alone.
    static func removingBlocks(_ text: String, _ blocks: [(open: String, close: String)]) -> String {
        var out = text
        for b in blocks {
            while let s = out.range(of: b.open), let e = out.range(of: b.close, range: s.upperBound..<out.endIndex) {
                var end = e.upperBound
                if end < out.endIndex, out[end] == "\n" { end = out.index(after: end) }
                out.removeSubrange(s.lowerBound..<end)
            }
        }
        return out
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

// MARK: - a merge renames the ledgers' rows

/// `person` is fixed at creation, so a loop or ask under the kept name is rebuilt around it — every other field
/// carried across, `lapsedAt` and `closedBy` included: a let-go ask that lost its lapse date would be open again.
public extension Loop {
    func renamed(to person: String) -> Loop {
        var n = Loop(id: id, direction: direction, person: person, what: what, quote: quote, sourceLabel: sourceLabel, due: due, dueDate: dueDate, status: status,
                     openedAt: openedAt, noticedAt: noticedAt, closedAt: closedAt, closedHow: closedHow, closedBy: closedBy, lapsedAt: lapsedAt, firedCardIDs: firedCardIDs, cameBackCount: cameBackCount)
        n.nudgedForDue = nudgedForDue; n.owner = owner
        return n
    }
}
public extension Ask {
    func renamed(to person: String) -> Ask {
        var a = self; a.person = person; return a
    }
}
