import Foundation
import Domain
import Support

/// One person as the app knows them: every spelling a source has used, every stable handle, and the one
/// People note that is theirs. `notSame` lists people the user said are somebody else, so the merge
/// banner never asks twice. `proofs` is what shows two chats are one person beyond a name — a phone, an
/// email (`PersonProof`) — and `pending` lists the people this one may be, a question Brownie raised when a
/// chat arrived under a name already on file and nothing but the name said they were the same.
public struct Person: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public var name: String
    public var aliases: [String]
    public var handles: [String]
    public var notePath: String?
    public var notSame: [String]
    public var proofs: [String]
    public var pending: [String]
    public let firstSeen: Date
    public var lastSeen: Date

    public init(id: String, name: String, aliases: [String] = [], handles: [String] = [], notePath: String? = nil, notSame: [String] = [], proofs: [String] = [], pending: [String] = [], firstSeen: Date, lastSeen: Date) {
        self.id = id; self.name = name; self.aliases = aliases; self.handles = handles; self.notePath = notePath; self.notSame = notSame
        self.proofs = proofs; self.pending = pending; self.firstSeen = firstSeen; self.lastSeen = lastSeen
    }

    enum CodingKeys: String, CodingKey { case id, name, aliases, handles, notePath, notSame, proofs, pending, firstSeen, lastSeen }
    /// A people.json written before proofs and pending existed decodes with both empty: the records it joined by name
    /// stay joined — there is no evidence either way — and only what arrives from now on is held to the new rule.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  aliases: try c.decodeIfPresent([String].self, forKey: .aliases) ?? [], handles: try c.decodeIfPresent([String].self, forKey: .handles) ?? [],
                  notePath: try c.decodeIfPresent(String.self, forKey: .notePath), notSame: try c.decodeIfPresent([String].self, forKey: .notSame) ?? [],
                  proofs: try c.decodeIfPresent([String].self, forKey: .proofs) ?? [], pending: try c.decodeIfPresent([String].self, forKey: .pending) ?? [],
                  firstSeen: try c.decode(Date.self, forKey: .firstSeen), lastSeen: try c.decode(Date.self, forKey: .lastSeen))
    }

    /// Every spelling's key, the name's first, without repeats or empties.
    public var keys: [String] {
        var out: [String] = []
        for k in ([name] + aliases).map(PersonKey.normalise) where !k.isEmpty && !out.contains(k) { out.append(k) }
        return out
    }
    /// The first words of every key: what a first-name-only label is matched against.
    var firstWords: Set<String> { Set(keys.compactMap { $0.split(separator: " ").first.map(String.init) }) }
    /// What proves who this is: the proofs on file and what each handle proves by itself (a WhatsApp handle is a phone),
    /// so a record written before proofs existed still meets a Contacts card or an iMessage chat by its number.
    public var allProofs: [String] {
        var out = proofs
        for p in handles.compactMap(PersonProof.fromHandle) where !out.contains(p) { out.append(p) }
        return out
    }
    /// Where this person has been seen, from the handles: "WhatsApp", "Slack", "Teams", "iMessage", "Telegram" — what the
    /// banner says when it asks whether the Nitesh Kumar on Slack is the one on WhatsApp.
    public var sources: [String] {
        var out: [String] = []
        for h in handles {
            let scheme = h.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
            let name: String
            switch scheme {
            case "whatsapp": name = "WhatsApp"
            case "slack": name = "Slack"
            case "teams": name = "Teams"
            case "imessage": name = "iMessage"
            case "telegram": name = "Telegram"
            case "": continue
            default: name = scheme.prefix(1).uppercased() + scheme.dropFirst()
            }
            if !out.contains(name) { out.append(name) }
        }
        return out
    }
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
        for j in records.indices { records[j].notSame.removeAll { $0 == id }; records[j].pending.removeAll { $0 == id } }
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
            for p in m.proofs where !out[t].proofs.contains(p) { out[t].proofs.append(p) }
            for p in m.pending where !out[t].pending.contains(p) { out[t].pending.append(p) }
            out[t].lastSeen = max(out[t].lastSeen, m.lastSeen)
        }
        // Lists name only people who still exist; a pair the user answered meanwhile (merged away, or kept separate) is no longer pending.
        let ids = Set(out.map(\.id))
        for i in out.indices {
            let me = out[i].id, notSame = out[i].notSame
            out[i].notSame.removeAll { !ids.contains($0) || $0 == me }
            out[i].pending.removeAll { !ids.contains($0) || $0 == me || notSame.contains($0) }
        }
        return out
    }

    public func people() -> [Person] { records }
    public func person(_ id: String) -> Person? { records.first { $0.id == id } }

    // MARK: seeding from the notes

    /// One person per existing People note, once: a note already owned by someone is left alone; a note whose
    /// title is a spelling of a person without a note becomes theirs, exact spellings before same-key ones (so
    /// "Kanika Pandey.md" goes to the Kanika Pandey on file even when "Kanika Pandey Loadmill.md" sorts first);
    /// any other note starts a new person. A note whose front-matter carries a record's id is that record's first of
    /// all — that is how "People/Nitesh Kumar (Slack).md", written for the Nitesh Kumar Brownie is not sure about,
    /// reaches him and not the Nitesh Kumar of "People/Nitesh Kumar.md"; a note titled the way such a record was told to be
    /// written reaches him too. Notes that vanished (renamed or deleted by the brain or the user)
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
        func owned(_ note: Note) -> Bool { records.contains { $0.notePath == note.relativePath } }
        for note in notes where !owned(note) {
            if let id = note.meta.id, let i = index(id), records[i].notePath == nil { records[i].notePath = note.relativePath }
        }
        for note in notes where !owned(note) {
            if let i = exactIndex(label: note.title), records[i].notePath == nil { records[i].notePath = note.relativePath }
        }
        for note in notes where !owned(note) {
            if let id = Self.resolveTitle(note.title, among: records), let i = index(id), records[i].notePath == nil {
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
    /// file; when the two spelled alike are a pending pair (the same name on two chats, not yet answered) the one
    /// with a note, and nobody when both or neither have one; then a first name alone, but only when exactly one
    /// person carries it — two Arjuns and the answer is nobody.
    public func resolve(label: String, handle: String?) -> String? { Self.resolve(label: label, handle: handle, among: records) }
    /// The same rule over a roster handed out by `people()`, for callers that hold the list rather than the registry (the brain's file tools).
    public nonisolated static func resolve(label: String, handle: String?, among records: [Person]) -> String? {
        if let h = handle, !h.isEmpty, let p = records.first(where: { $0.handles.contains(h) }) { return p.id }
        let key = PersonKey.normalise(label)
        guard !key.isEmpty else { return nil }
        let byKey = records.filter { $0.keys.contains(key) }
        if byKey.count == 1 { return byKey[0].id }
        if byKey.count > 1 {
            let (hit, tied) = Self.exactMatch(label: label, among: byKey)
            if let hit { return byKey[hit].id }
            // Spelled the same by several: only a pending pair can be told apart, by which of them has the note.
            let pair = tied.map { byKey[$0] }
            guard pair.count > 1, pair.allSatisfy({ a in pair.allSatisfy { b in a.id == b.id || a.pending.contains(b.id) } }) else { return nil }
            let noted = pair.filter { $0.notePath != nil }
            return noted.count == 1 ? noted[0].id : nil
        }
        guard !key.contains(" ") else { return nil }
        let byFirstName = records.filter { $0.firstWords.contains(key) }
        return byFirstName.count == 1 ? byFirstName[0].id : nil
    }

    /// Who a People note's title names, for the file tools and the seed: first a record without a note that was told to be
    /// written under exactly this title ("Nitesh Kumar (Slack)" for the Nitesh Kumar Brownie is not sure about, "Nitesh
    /// Kumar" for the one it already knew), then whoever the title resolves to as a label.
    public nonisolated static func resolveTitle(_ title: String, among records: [Person]) -> String? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = records.first(where: { $0.notePath == nil && !$0.pending.isEmpty && Self.spellsAlike(Self.suggestedTitle(for: $0, among: records), t) }) { return p.id }
        if let p = records.first(where: { $0.notePath == nil && !$0.notSame.isEmpty && Self.spellsAlike(Self.suggestedTitle(for: $0, among: records), t) }) { return p.id }
        return resolve(label: t, handle: nil, among: records)
    }

    /// The file a person is written in: theirs when they have one; otherwise their name — unless someone they may be, or
    /// were kept apart from, is spelled the same and comes first (has the note, or was on file earlier), in which case the
    /// name with the chat this one was seen on, "People/Nitesh Kumar (Slack).md", so the two are told apart on disk until
    /// the user says. A path another record already holds is stepped past with a count.
    public nonisolated static func suggestedNotePath(for p: Person, among records: [Person]) -> String {
        p.notePath ?? "People/" + suggestedTitle(for: p, among: records) + ".md"
    }
    nonisolated static func suggestedTitle(for p: Person, among records: [Person]) -> String {
        if let path = p.notePath { return Self.fileTitle(path) }
        // The plain name is taken when someone else's note is titled so, or when a namesake this one may be (or was kept
        // apart from) has no note either and was on file first — a namesake already written under another title takes nothing.
        let plainTaken = records.contains { o in o.id != p.id && o.notePath.map { spellsAlike(Self.fileTitle($0), p.name) } ?? false }
        let olderNamesake = records.contains { o in o.id != p.id && o.notePath == nil && (p.pending.contains(o.id) || p.notSame.contains(o.id)) && spellsAlike(o.name, p.name) && precedes(o, p) }
        let base = plainTaken || olderNamesake ? p.name + " (" + (p.sources.first ?? "another chat") + ")" : p.name
        let taken = Set(records.filter { $0.id != p.id }.compactMap { $0.notePath.map { Self.fileTitle($0).lowercased() } })
        var title = base, n = 2
        while taken.contains(title.lowercased()) { title = base + " \(n)"; n += 1 }
        return title
    }
    /// Which of two records was on file first: the older, then the smaller id — the order the file is read back in, so
    /// the answer is the same before and after a save.
    nonisolated static func precedes(_ a: Person, _ b: Person) -> Bool { (a.firstSeen, a.id) < (b.firstSeen, b.id) }

    /// The person for a label, created when unknown, with only what the handle itself proves (a WhatsApp handle is a phone).
    @discardableResult
    public func register(label: String, handle: String?) -> String { register(label: label, handle: handle, proofs: []) }

    /// The person for a label, created when unknown. The label is learned as an alias, the handle and proofs as theirs.
    /// Proof joins, a name alone asks. In order: a handle on file is that person; a proof on file (the same phone or
    /// email, on a record or in what its handles prove) is that person, and the new handle joins them; a name that
    /// resolves to someone never seen on a chat — known from a note, or from loops by name — is them, since there is
    /// no second chat to confuse; a name that resolves to someone already on another chat is NOT taken to be them:
    /// a new record opens for this handle and the two are marked pending toward each other, for the banner to ask.
    /// Anything else is a new record. Without a handle, the label resolves as a name and joins what it resolves to;
    /// one that could be either of two people sharing its key, and spells neither exactly, is nobody's to learn: nothing
    /// is attached and no third record is opened, and the likelier of the two is returned.
    /// The user's own name opens no record and learns nothing: it comes back as the empty id, which names nobody.
    @discardableResult
    public func register(label: String, handle: String?, proofs: [String]) -> String {
        guard !isSelf(label) else { return "" }
        let handle = handle.flatMap { $0.isEmpty ? nil : $0 }
        var proofs = proofs
        if let h = handle, let own = PersonProof.fromHandle(h), !proofs.contains(own) { proofs.append(own) }
        func join(_ i: Int) -> String {
            Self.learn(label: label, into: &records[i])
            if let h = handle, !records[i].handles.contains(h) { records[i].handles.append(h) }
            for p in proofs where !records[i].proofs.contains(p) { records[i].proofs.append(p) }
            records[i].lastSeen = now()
            return records[i].id
        }
        if let h = handle, let i = records.firstIndex(where: { $0.handles.contains(h) }) { return join(i) }
        let proven = records.filter { r in r.allProofs.contains { proofs.contains($0) } }
        if let first = proven.first, let i = index(proven.dropFirst().reduce(first) { Self.keepFirst($0, $1).0 }.id) {
            if let h = handle { log.info("\(label) (\(h)) joined \(records[i].name) by proof") }
            return join(i)
        }
        func open(pendingToward ids: [String]) -> String {
            var p = Person(id: Self.newID(), name: PersonKey.displayName(label), aliases: [], handles: handle.map { [$0] } ?? [], proofs: proofs, pending: ids, firstSeen: now(), lastSeen: now())
            Self.learn(label: label, into: &p)
            for id in ids { if let i = index(id) { records[i].pending.append(p.id) } }
            records.append(p)
            if let first = ids.first, let i = index(first) { log.info("\(label) on \(p.sources.first ?? "a chat") may be \(records[i].name) of \(records[i].sources.joined(separator: ", ")) — the banner asks") }
            return p.id
        }
        let key = PersonKey.normalise(label), shared = records.filter { $0.keys.contains(key) }
        // A chat under a name that two records already spell exactly (a pending pair, or namesakes the user keeps apart)
        // may be either: its own record, pending toward each — a handle left unattached would route its asks nowhere and ask nobody.
        if handle != nil, shared.count > 1, case let tied = Self.exactMatch(label: label, among: shared).tied, tied.count > 1 { return open(pendingToward: tied.map { shared[$0].id }) }
        if let id = resolve(label: label, handle: nil), let i = index(id) {
            guard handle != nil, !records[i].handles.isEmpty else { return join(i) }
            return open(pendingToward: [id])
        }
        if shared.count > 1 { return shared.dropFirst().reduce(shared[0]) { Self.keepFirst($0, $1).0 }.id }
        return open(pendingToward: [])
    }
    /// "People/Nitesh Kumar (Slack).md" → "Nitesh Kumar (Slack)".
    nonisolated static func fileTitle(_ path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name.hasSuffix(".md") ? String(name.dropLast(3)) : name
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
    /// one whose shown name or own note's title is the label; nil when none or several are — "Kanika Pandey" spelled by
    /// two records decides nothing, and the several are handed back as `tied` for the one rule that can tell a pending pair apart.
    private func exactIndex(label: String) -> Int? { Self.exactMatch(label: label, among: records).hit }
    private static func exactMatch(label: String, among pool: [Person]) -> (hit: Int?, tied: [Int]) {
        for spellings in [{ (p: Person) in p.aliases }, { (p: Person) in [p.name] + (p.notePath.map { [fileTitle($0)] } ?? []) }] {
            let hits = pool.indices.filter { i in spellings(pool[i]).contains { spellsAlike($0, label) } }
            if hits.count == 1 { return (hits[0], []) }
            if hits.count > 1 { return (nil, hits) }
        }
        return (nil, [])
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

    /// The kept person takes the dropped one's proofs too, and the question between the two is answered: neither is
    /// pending toward the other any more. A third person who was pending toward the dropped one is now pending toward
    /// the kept one — the question was about the person, and the person is still here.
    static func merge(keep: String, drop: String, in records: inout [Person]) {
        guard keep != drop, let k = records.firstIndex(where: { $0.id == keep }), let d = records.firstIndex(where: { $0.id == drop }) else { return }
        let dropped = records[d]
        for a in [dropped.name] + dropped.aliases where a != records[k].name && !records[k].aliases.contains(a) { records[k].aliases.append(a) }
        for h in dropped.handles where !records[k].handles.contains(h) { records[k].handles.append(h) }
        for p in dropped.proofs where !records[k].proofs.contains(p) { records[k].proofs.append(p) }
        if records[k].notePath == nil { records[k].notePath = dropped.notePath }
        func united(_ a: [String], _ b: [String]) -> [String] { (a + b).filter { $0 != keep && $0 != drop }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } }
        records[k].notSame = united(records[k].notSame, dropped.notSame)
        records[k].pending = united(records[k].pending, dropped.pending).filter { !records[k].notSame.contains($0) }
        records[k].lastSeen = max(records[k].lastSeen, dropped.lastSeen)
        records.remove(at: d)
        for i in records.indices {
            records[i].notSame.removeAll { $0 == drop }
            if records[i].pending.contains(drop) {
                records[i].pending.removeAll { $0 == drop || $0 == keep }
                if i != k, !records[i].notSame.contains(keep), !records[k].notSame.contains(records[i].id) { records[i].pending.append(keep) }
            }
        }
    }

    /// The user's word that two are two: remembered both ways, and no longer a question.
    public func keepSeparate(_ a: String, _ b: String) {
        guard let i = index(a), let j = index(b), a != b else { return }
        if !records[i].notSame.contains(b) { records[i].notSame.append(b) }
        if !records[j].notSame.contains(a) { records[j].notSame.append(a) }
        records[i].pending.removeAll { $0 == b }
        records[j].pending.removeAll { $0 == a }
    }

    /// Pairs the banner asks about. First the questions Brownie itself raised — a pending pair, the same name arriving on a
    /// second chat with nothing but the name to join them — then the pairs that merely look like one person: the same
    /// two-word key, or the same first word with one of them known by a first name alone — unless the user has said they
    /// are two. The first of each pair is the better one to keep: the one with a note, then the fuller name, then the older record.
    public func suspects() -> [(Person, Person)] {
        var pending: [(Person, Person)] = [], alike: [(Person, Person)] = []
        for i in records.indices {
            for j in records.indices where j > i {
                let a = records[i], b = records[j]
                if a.notSame.contains(b.id) || b.notSame.contains(a.id) { continue }
                if a.pending.contains(b.id) || b.pending.contains(a.id) { pending.append(Self.keepFirst(a, b)); continue }
                guard a.keys.contains(where: { ka in b.keys.contains { kb in PersonKey.same(ka, kb) } }) else { continue }
                alike.append(Self.keepFirst(a, b))
            }
        }
        return pending + alike
    }

    // MARK: the Mac's Contacts

    /// What the address book proves. For every card, each person who carries one of its phones or emails (on the record,
    /// or in what a handle proves by itself) learns the card's other proofs and its name and nickname as spellings; two
    /// people who fall on one card are one person and are merged, the one with a note kept — a pending pair among them
    /// is thereby answered. Two who both have a note are not merged here, where the notes cannot be folded: they are
    /// left pending, and the banner's one click folds them. A pending pair whose two fall on two different cards, under
    /// two different names, is answered the other way: kept separate. Two cards under one name (a work card and a home
    /// card) prove nothing about a pair and leave the question to the user. Returns how many people were merged away.
    @discardableResult
    public func link(contacts cards: [ContactCard]) -> Int {
        var merged = 0, cardsOf: [String: Set<Int>] = [:]
        for (n, card) in cards.enumerated() where !card.proofs.isEmpty && !isSelf(card.name) {
            let hits = records.filter { r in r.allProofs.contains { card.proofs.contains($0) } }
            guard let first = hits.first else { continue }
            let kept = hits.dropFirst().reduce(first) { Self.keepFirst($0, $1).0 }
            for other in hits where other.id != kept.id {
                if other.notePath != nil, kept.notePath != nil {
                    guard let k = index(kept.id), let o = index(other.id), !records[k].notSame.contains(other.id) else { continue }
                    if !records[k].pending.contains(other.id) { records[k].pending.append(other.id) }
                    if !records[o].pending.contains(kept.id) { records[o].pending.append(kept.id) }
                    log.info("\(other.name) and \(kept.name) are one card in Contacts (\(card.name)) with a note each: the banner asks, and folds them")
                    continue
                }
                log.info("\(other.name) and \(kept.name) are one card in Contacts (\(card.name)): merged")
                merge(keep: kept.id, drop: other.id); merged += 1
                cardsOf[kept.id, default: []].formUnion(cardsOf.removeValue(forKey: other.id) ?? [])
            }
            for id in [kept.id] + hits.map(\.id) {
                guard let i = index(id) else { continue }
                for p in card.proofs where !records[i].proofs.contains(p) { records[i].proofs.append(p) }
                Self.learn(label: card.name, into: &records[i])
                if let nick = card.nickname { Self.learn(label: nick, into: &records[i]) }
                cardsOf[id, default: []].insert(n)
            }
        }
        for r in records where !r.pending.isEmpty {
            for other in r.pending {
                guard let mine = cardsOf[r.id], let theirs = cardsOf[other], mine.isDisjoint(with: theirs),
                      !mine.contains(where: { m in theirs.contains { PersonKey.same(cards[m].name, cards[$0].name) } }) else { continue }
                let names = (mine.map { cards[$0].name } + theirs.map { cards[$0].name }).joined(separator: ", ")
                log.info("\(r.name) and \(person(other)?.name ?? other) are two cards in Contacts (\(names)): kept separate")
                keepSeparate(r.id, other)
            }
        }
        return merged
    }

    /// What a source's profile proves about a chat the registry already knows: the record holding `handle` learns the
    /// proofs, and if another record now shares one, the two are one person — merged, or put to the user through the
    /// banner when both already have a note. A handle nobody holds teaches nothing; `register` does that when an ask
    /// or a loop first names the chat.
    @discardableResult
    public func learn(proofs: [String], forHandle handle: String) -> Bool {
        guard !proofs.isEmpty, let i = records.firstIndex(where: { $0.handles.contains(handle) }) else { return false }
        var changed = false
        for p in proofs where !records[i].proofs.contains(p) { records[i].proofs.append(p); changed = true }
        guard changed else { return false }
        let me = records[i]
        for other in records where other.id != me.id && !other.notSame.contains(me.id) && other.allProofs.contains(where: { me.allProofs.contains($0) }) {
            let (kept, dropped) = Self.keepFirst(me, other)
            if kept.notePath != nil, dropped.notePath != nil {
                if let k = index(kept.id), !records[k].pending.contains(dropped.id) { records[k].pending.append(dropped.id) }
                if let d = index(dropped.id), !records[d].pending.contains(kept.id) { records[d].pending.append(kept.id) }
                log.info("\(dropped.name) and \(kept.name) share a phone or an email with a note each: the banner asks, and folds them")
            } else {
                log.info("\(dropped.name) and \(kept.name) share a phone or an email: merged")
                merge(keep: kept.id, drop: dropped.id)
            }
        }
        return true
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

    /// The `PEOPLE:` lines of the note builder's header: who exists and where they are written, capped. Someone Brownie is
    /// not sure about — the same name on a second chat — is listed on their own line with the file to write them in,
    /// "People/Nitesh Kumar (Slack).md", and told apart from the one they may be, so the brain never folds the two.
    public static let unsureLine = "Brownie is not sure these are one person; write each in their own file until the user says"
    public static func headerLines(_ people: [Person], cap: Int = 200) -> [String] {
        people.sorted { ($0.notePath == nil ? 1 : 0, $0.name.lowercased()) < ($1.notePath == nil ? 1 : 0, $1.name.lowercased()) }.prefix(cap).map { p in
            var also: [String] = []
            for a in p.aliases.map(PersonKey.displayName) where a.lowercased() != p.name.lowercased() && !also.contains(a) { also.append(a) }
            let alsoLine = also.isEmpty ? "" : " (also: " + also.prefix(4).joined(separator: ", ") + ")"
            let seen = p.sources.isEmpty ? "" : " (seen on " + p.sources.joined(separator: ", ") + ")"
            let suggested = suggestedNotePath(for: p, among: people)
            let file = p.notePath ?? (p.pending.isEmpty && suggested == "People/\(p.name).md" ? "no note yet" : "no note yet; write them in " + suggested)
            let unsure = p.pending.compactMap { id in people.first { $0.id == id } }.map { o in "may be the \(o.name) of \(suggestedNotePath(for: o, among: people))" }
            let unsureLine = unsure.isEmpty ? "" : " — " + unsure.joined(separator: "; ") + " — " + Self.unsureLine
            return "\(p.name) — \(file)" + alsoLine + (unsure.isEmpty ? "" : seen) + unsureLine
        }
    }

    // MARK: helpers

    private func index(_ id: String) -> Int? { records.firstIndex { $0.id == id } }
    static func newID() -> String { "p-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12) }
}

/// The banner's words for a suspect pair, pure so they can be checked without a window. A pending pair — the same name
/// on a second chat, with nothing but the name to join them — is Brownie's own question, and is answered Same person or
/// Different people; a pair that merely looks alike is offered Merge or Keep separate, as before.
public enum PeopleQuestion {
    public static func isPending(_ pair: (Person, Person)) -> Bool { pair.0.pending.contains(pair.1.id) || pair.1.pending.contains(pair.0.id) }

    /// "Is Nitesh Kumar on Slack the same Nitesh Kumar as on WhatsApp?" — the newcomer (the second of the pair, the one
    /// without the note) first. When both were seen on the same app, two chats under one name, the question says so
    /// rather than naming the app twice; with no chat known for either, it asks plainly.
    public static func title(_ pair: (Person, Person)) -> String {
        let (kept, newcomer) = pair
        guard isPending(pair) else { return "These two look like one person: \(kept.name) · \(newcomer.name)" }
        let keptOn = kept.sources.first, newOn = newcomer.sources.first
        if let a = newOn, let b = keptOn, a != b { return "Is \(newcomer.name) on \(a) the same \(kept.name) as on \(b)?" }
        if let a = newOn ?? keptOn { return "Are the two \(newcomer.name)s on \(a) the same person?" }
        return "Is this \(newcomer.name) the same person as \(kept.name)?"
    }
    public static func yes(_ pair: (Person, Person)) -> String { isPending(pair) ? "Same person" : "Merge" }
    public static func no(_ pair: (Person, Person)) -> String { isPending(pair) ? "Different people" : "Keep separate" }
    /// What a yes does: which record stays, and what becomes of the other's note.
    public static func consequence(_ pair: (Person, Person)) -> String {
        var s = "\(yes(pair)) keeps \(pair.0.name)"
        if let p = pair.0.notePath { s += pair.1.notePath == nil ? " and their note \(p)" : " and folds the other note into \(p)" }
        return s
    }
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
