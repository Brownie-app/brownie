import Testing
import Foundation
@testable import Knowledge
import Domain
import Platform

/// The vault measured: every rule against one small vault, then the sentence, then the history it is kept in.
@Suite struct VaultHealthTests {
    // 2026-09-16 11:20 UTC.
    static let now = Date(timeIntervalSince1970: 1_789_560_000)
    static let utc = TimeZone(identifier: "UTC")!
    static func words(_ n: Int, _ w: String = "word") -> String { Array(repeating: w, count: n).joined(separator: " ") }

    /// Eight notes plus the ones the measure must not see.
    static func vault() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)", isDirectory: true)
        func put(_ path: String, _ body: String, modified: Date? = nil) throws {
            let u = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: u, atomically: true, encoding: .utf8)
            if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: u.path) }
        }
        let fresh = now.addingTimeInterval(-86400)
        try put("README.md", "# Brownie Knowledge Base\n\n" + words(400), modified: fresh)                                   // over the README budget
        try put("People/Arjun Mehta.md", "---\nbrownie: person\naliases: []\nsources: [whatsapp]\ncreated: 2026-01-10\nupdated: 2026-01-10\nuser_edited: false\ncontent_hash: \n---\n# Arjun Mehta\n\nOld friend. See [[Priya Sharma]] and [[Nobody]].\n\n<!-- brownie:status -->\n- ⏳ 2 Aug — they asked: “dinner?” — no reply yet\n- ✅ 1 Jan — you promised (1 Jan): a thing — done 3 Jan\n- ⏳ 20 Dec — you promised (20 Dec): the book\n<!-- /brownie:status -->\n", modified: fresh)   // quiet by front matter; 20 Dec is last year's
        try put("People/Arjun.md", "# Arjun\n\nA single word, so may be Arjun Mehta.", modified: fresh)
        try put("People/Priya Sharma.md", "# Priya Sharma\n\n" + words(1600) + "\n\n[[priya sharma]] links to herself; [[Nobody|him]] and [[nobody#Pending]] are the same missing note; [[Arjun Mehta#Pending]] resolves.", modified: fresh)   // over the person budget
        try put("People/Kanika Pandey Loadmill.md", "# Kanika Pandey Loadmill\n\nquiet by mtime", modified: now.addingTimeInterval(-91 * 86400))
        try put("Groups/Upreti Family.md", "# Upreti Family\n\n[[Kanika Pandey Loadmill]] and [[Lost Group]].", modified: fresh)
        try put("Notes/Trip.md", "# Goa trip\n\n" + words(2600) + " [[Goa Trip]]", modified: fresh)                    // over the note budget; its title resolves a link
        try put("Notes/Short.md", "# Short\n\none two three", modified: fresh)
        // Not part of the measure.
        try put("Today.md", "# Today\n\n" + words(5000), modified: fresh)
        try put("Archive/Old.md", "# Old\n\n" + words(5000) + " [[Never]]", modified: fresh)
        try put("Notes/Archive/Older.md", "# Older\n\n" + words(5000), modified: fresh)
        try put(".obsidian/hidden.md", "# Hidden\n\n" + words(5000), modified: fresh)
        try put("Notes/image.png", "not markdown", modified: fresh)
        return root
    }

    @Test func countsFoldersWordsMedianAndTheLargest() throws {
        let h = VaultHealth.compute(root: try Self.vault(), now: Self.now, timeZone: Self.utc)
        #expect(h.notes == 8 && h.notesPerFolder == [".": 1, "People": 4, "Groups": 1, "Notes": 2])
        #expect(h.readmeWords == 404, "the heading counts")
        #expect(h.largest.map(\.path) == ["Notes/Trip.md", "People/Priya Sharma.md", "README.md", "People/Arjun Mehta.md", "People/Arjun.md"])
        #expect(h.largest.map(\.words) == [2605, 1619, 404, 54, 10])
        #expect(h.words == 4713, "the five largest and the three small notes: 9, 7 and 5 words")
        #expect(h.medianWords == (10 + 54) / 2, "an even count averages the two middle notes")
    }

    @Test func budgetsDependOnWhereTheNoteLives() throws {
        let h = VaultHealth.compute(root: try Self.vault(), now: Self.now, timeZone: Self.utc)
        #expect(h.overBudget.map(\.path) == ["Notes/Trip.md", "People/Priya Sharma.md", "README.md"])
        #expect(VaultHealth.readmeBudget == 350 && VaultHealth.personBudget == 1500 && VaultHealth.noteBudget == 2500)
    }

    @Test func quietPeopleByFrontMatterOrElseByMtime() throws {
        let h = VaultHealth.compute(root: try Self.vault(), now: Self.now, timeZone: Self.utc)
        #expect(h.quietPeople == ["People/Arjun Mehta.md", "People/Kanika Pandey Loadmill.md"], "an old `updated:` day counts even on a fresh file; no front matter falls back to the file's date")
    }

    /// `updated:` is the day Brownie stamps (`YYYY-MM-DD`), never the file's clock: the status block moving, a link
    /// rename after a merge or the migration touching every file leave a person as quiet as their substance is.
    @Test func quietReadsTheDayBrownieStampsNotTheTimestampALegacyBlockCarried() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("People"), withIntermediateDirectories: true)
        let fresh = Self.now.addingTimeInterval(-3600), old = Self.now.addingTimeInterval(-100 * 86400)
        func put(_ name: String, _ text: String, modified: Date) throws {
            let u = root.appendingPathComponent("People/\(name).md"); try text.write(to: u, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: u.path)
        }
        try put("Quiet", NoteMeta.fresh(path: "People/Quiet.md", body: "", today: "2026-05-01").render() + "# Quiet\n\nrewritten last night, nothing new since May\n", modified: fresh)
        try put("Fresh", NoteMeta.fresh(path: "People/Fresh.md", body: "", today: "2026-09-15").render() + "# Fresh\n\nnew two days ago, on a file the phone has not touched\n", modified: old)
        try put("Edge", NoteMeta.fresh(path: "People/Edge.md", body: "", today: "2026-06-19").render() + "# Edge\n\neighty-nine days is not yet quiet\n", modified: old)
        try put("Legacy", "---\nsources: whatsapp\nupdated: 2026-01-10T08:00:00Z\nuser_edited: false\n---\n# Legacy\n\na block from before `brownie:`; its timestamp was a save time, so the file's date decides\n", modified: fresh)
        let h = VaultHealth.compute(root: root, now: Self.now, timeZone: Self.utc)
        #expect(h.quietPeople == ["People/Quiet.md"], "the day in the block wins over the file's clock both ways; a legacy timestamp is not a day and falls back to mtime")
    }

    @Test func danglingLinksAreNamesNoNoteAnswersTo() throws {
        let h = VaultHealth.compute(root: try Self.vault(), now: Self.now, timeZone: Self.utc)
        #expect(h.danglingLinks.map(\.name) == ["Lost Group", "Nobody"], "alias and heading forms fold into one name; title and file name both resolve, case-insensitively")
        #expect(h.danglingLinks.map(\.path) == ["Groups/Upreti Family.md", "People/Arjun Mehta.md"], "the first note it was found in")
    }

    /// A link resolves the way Obsidian resolves it: by title, file name, an alias in the note's front-matter, a note
    /// that has been archived, or a spelling the registry ties to a note. Only a name nothing answers to is dangling.
    @Test func linksResolveByAliasArchivedNoteAndRegistrySpelling() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)", isDirectory: true)
        func put(_ path: String, _ text: String) throws {
            let u = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        try put("People/Kanika Pandey Loadmill.md", NoteMeta.fresh(path: "People/Kanika Pandey Loadmill.md", body: "", today: "2026-09-01", aliases: ["Kanika Pandey", "Pandey, Kanika"]).render() + "# Kanika Pandey Loadmill\n\nhas aliases\n")
        try put("People/Nitesh Kumar.md", "# Nitesh Kumar\n\nthe registry knows him as Nitesh\n")
        try put("People/Archive/Old Friend.md", "# Old Friend\n\narchived, still a note\n")
        try put("Notes/Trip.md", "# Trip\n\n[[Kanika Pandey]], [[pandey, kanika|her]], [[Old Friend#Now]], [[Nitesh]] resolve; [[Ghost]] and [[Nobody]] do not.\n")
        let people = [
            Person(id: "p1", name: "Nitesh Kumar", aliases: ["Nitesh", "Nitesh (+919540752593)"], notePath: "People/Nitesh Kumar.md", firstSeen: Self.now, lastSeen: Self.now),
            Person(id: "p2", name: "Ghost", aliases: [], notePath: nil, firstSeen: Self.now, lastSeen: Self.now),   // known, but no note: the link still leads nowhere
        ]
        let h = VaultHealth.compute(root: root, now: Self.now, timeZone: Self.utc, people: people)
        #expect(h.danglingLinks.map(\.name) == ["Ghost", "Nobody"])
        #expect(h.notes == 3 && h.notesPerFolder["People"] == 2, "the archived note answers to its link but is not counted")
        #expect(VaultHealth.compute(root: root, now: Self.now, timeZone: Self.utc).danglingLinks.map(\.name) == ["Ghost", "Nitesh", "Nobody"], "without the registry, only the notes' own spellings resolve")
    }

    @Test func duplicateSuspectsAreTheSamePersonKeyOrAFirstNameAlone() throws {
        let h = VaultHealth.compute(root: try Self.vault(), now: Self.now, timeZone: Self.utc)
        #expect(h.duplicateSuspects == [.init(a: "People/Arjun Mehta.md", b: "People/Arjun.md")])
    }

    /// "Keep separate" is kept: a pair the registry holds in each other's `notSame` is not a suspect — through
    /// `compute` given the people, and through `nightly`, which reads the registry from the vault itself.
    @Test func aPairTheUserKeptSeparateIsNotASuspect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("People"), withIntermediateDirectories: true)
        for n in ["Arjun", "Arjun Mehta", "Priya", "Priya Sharma"] { try "# \(n)\n\nsomeone\n".write(to: root.appendingPathComponent("People/\(n).md"), atomically: true, encoding: .utf8) }
        let people = [
            Person(id: "p1", name: "Arjun", notePath: "People/Arjun.md", notSame: ["p2"], firstSeen: Self.now, lastSeen: Self.now),
            Person(id: "p2", name: "Arjun Mehta", notePath: "People/Arjun Mehta.md", notSame: ["p1"], firstSeen: Self.now, lastSeen: Self.now),
            Person(id: "p3", name: "Priya", notePath: "People/Priya.md", firstSeen: Self.now, lastSeen: Self.now),
            Person(id: "p4", name: "Priya Sharma", notePath: "People/Priya Sharma.md", firstSeen: Self.now, lastSeen: Self.now),
        ]
        let priya = VaultHealth.Pair(a: "People/Priya Sharma.md", b: "People/Priya.md"), arjun = VaultHealth.Pair(a: "People/Arjun Mehta.md", b: "People/Arjun.md")
        #expect(VaultHealth.compute(root: root, now: Self.now, timeZone: Self.utc).duplicateSuspects == [arjun, priya], "without the registry both pairs look like one person")
        #expect(VaultHealth.compute(root: root, now: Self.now, timeZone: Self.utc, people: people).duplicateSuspects == [priya])
        // The same answer from the vault's own people.json, the way the night reads it.
        struct File: Codable { var version = 1; var people: [Person] }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: root.appendingPathComponent(PersonRegistry.directory), withIntermediateDirectories: true)
        try enc.encode(File(people: people)).write(to: root.appendingPathComponent(PersonRegistry.directory).appendingPathComponent(PersonRegistry.file))
        let night = await VaultHealth.nightly(root: root, now: Self.now, store: try SQLiteRunStore.inMemory(), timeZone: Self.utc)
        #expect(night.duplicateSuspects == [priya] && night.line.hasSuffix("1 pair that may be one person"))
    }

    /// The scan normalises each title once and compares only notes that share a first word, so a vault of hundreds of
    /// people is measured in milliseconds, not seconds — and finds exactly the pairs the pairwise rule would.
    @Test func duplicateScanIsLinearInThePeople() {
        var notes: [VaultHealth.Measured] = []
        func note(_ title: String) { notes.append(.init(path: "People/\(title).md", folder: "People", title: title, aliases: [], words: 3, body: "# \(title)\n", updated: Self.now, archived: false)) }
        // Keys keep letters only, so every name is spelt in letters: "Pab", "Sab".
        func w(_ prefix: String, _ i: Int) -> String { prefix + String(UnicodeScalar(97 + i / 26)!) + String(UnicodeScalar(97 + i % 26)!) }
        for i in 0..<200 { note("\(w("P", i)) \(w("S", i))") }                     // 200 people, all distinct
        for i in 0..<100 { note(w("P", i)); note("\(w("P", i)) \(w("T", i))") }    // 100 first names alone: each pairs with two fuller names, which do not pair with each other
        for i in 0..<50 { note("Zoë\(w("", i)) Müller"); note("Zoe\(w("", i)) Muller (+91 98\(i))") }   // 50 pairs one diacritic and a phone number apart
        #expect(notes.count == 500)
        var pairs: [VaultHealth.Pair] = []
        let took = ContinuousClock().measure { pairs = VaultHealth.duplicates(in: notes.sorted { $0.path < $1.path }) }
        #expect(pairs.count == 200 + 50, "each lone first name with its two fuller names; each accented pair; nothing else")
        #expect(pairs == pairs.sorted { ($0.a, $0.b) < ($1.a, $1.b) } && pairs.allSatisfy { $0.a < $0.b }, "sorted by path, a before b")
        #expect(took < .seconds(1), "500 people took \(took)")
    }

    @Test func oldestPendingReadsTheStatusBlockAgainstThisYear() throws {
        let h = VaultHealth.compute(root: try Self.vault(), now: Self.now, timeZone: Self.utc)
        #expect(h.oldestPendingDays == 270, "20 Dec cannot be this year, so it is last year's; 2 Aug is 45 days; the ✅ line is not pending")
        #expect(VaultHealth.oldestPending(in: "# X\n- ⏳ 2 Aug — no reply yet\n", now: Self.now, timeZone: Self.utc) == nil, "outside a block, nothing counts")
        #expect(VaultHealth.oldestPending(in: "<!-- brownie:between-you -->\n- ⏳ 2 Aug — no reply yet\n<!-- /brownie:between-you -->", now: Self.now, timeZone: Self.utc) == 45, "the old markers still read")
    }

    @Test func netWordsComesFromTheRecordAWeekAgo() throws {
        let root = try Self.vault()
        let fresh = VaultHealth.compute(root: root, now: Self.now, timeZone: Self.utc)
        #expect(fresh.netWordsPerWeek == nil, "no history, no trend")
        let weekAgo = VaultHealth(at: Self.now.addingTimeInterval(-7 * 86400), words: fresh.words - 120)
        let twoDaysAgo = VaultHealth(at: Self.now.addingTimeInterval(-2 * 86400), words: fresh.words - 5)
        #expect(VaultHealth.compute(root: root, now: Self.now, history: [twoDaysAgo, weekAgo], timeZone: Self.utc).netWordsPerWeek == 120, "the newest record at least a week old, not the newest record")
        #expect(VaultHealth.compute(root: root, now: Self.now, history: [twoDaysAgo], timeZone: Self.utc).netWordsPerWeek == nil)
    }

    @Test func theSentence() {
        var h = VaultHealth(at: Self.now, notes: 33, words: 16900)
        #expect(h.line == "33 notes · 16,900 words · nothing to tidy")
        h.overBudget = [.init(path: "a", words: 1), .init(path: "b", words: 1)]
        h.quietPeople = ["People/X.md"]
        h.danglingLinks = [.init(name: "a", path: "p"), .init(name: "b", path: "p"), .init(name: "c", path: "p")]
        h.duplicateSuspects = [.init(a: "x", b: "y")]
        #expect(h.line == "33 notes · 16,900 words · 2 over budget · 1 quiet person · 3 dangling links · 1 pair that may be one person")
        #expect(VaultHealth(at: Self.now, notes: 1, words: 1).line == "1 note · 1 word · nothing to tidy")
    }

    @Test func anEmptyOrMissingVaultMeasuresAsNothing() {
        let h = VaultHealth.compute(root: FileManager.default.temporaryDirectory.appendingPathComponent("no-such-vault-\(UUID().uuidString)"), now: Self.now, timeZone: Self.utc)
        #expect(h.notes == 0 && h.words == 0 && h.medianWords == 0 && h.largest.isEmpty && h.oldestPendingDays == nil && h.line == "0 notes · 0 words · nothing to tidy")
    }

    @Test func historyKeepsOnePerDayNinetyAtMostNewestFirst() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = Self.utc
        func rec(_ daysAgo: Double, words: Int) -> VaultHealth { VaultHealth(at: Self.now.addingTimeInterval(-daysAgo * 86400), words: words) }
        let older = (1...120).map { rec(Double($0), words: $0) }
        let h = VaultHealth.append(rec(0, words: 500), to: older, calendar: cal)
        #expect(h.count == 90 && h[0].words == 500 && h[1].words == 1 && h.last?.words == 89, "nothing older than 90 days, at most 90 records")
        let again = VaultHealth.append(rec(0.1, words: 501), to: h, calendar: cal)
        #expect(again.count == 90 && again[0].words == 501 && again[1].words == 1, "a second run on the same day replaces the first")
        #expect(VaultHealth.latest(from: again)?.words == 501)
        let json = VaultHealth.json(again)
        #expect(VaultHealth.history(from: json) == again && VaultHealth.latest(from: json)?.words == 501, "round-trips through the store's JSON")
        #expect(VaultHealth.history(from: nil).isEmpty && VaultHealth.history(from: "not json").isEmpty && VaultHealth.latest(from: nil) == nil)
    }

    /// Only the newest record keeps its lists; the nights behind it keep their counts, so the row grows with the days,
    /// not with the vault — and a record written before counts existed still reads its counts from its lists.
    @Test func olderRecordsKeepCountsNotLists() throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = Self.utc
        func full(_ daysAgo: Double) -> VaultHealth {
            VaultHealth(at: Self.now.addingTimeInterval(-daysAgo * 86400), notes: 30, words: 1000, largest: [.init(path: "a", words: 900)], overBudget: [.init(path: "a", words: 900), .init(path: "b", words: 800)],
                        quietPeople: ["People/X.md"], danglingLinks: [.init(name: "n", path: "p"), .init(name: "o", path: "p"), .init(name: "q", path: "p")], duplicateSuspects: [.init(a: "x", b: "y")])
        }
        let h = VaultHealth.append(full(0), to: [full(1), full(2)], calendar: cal)
        #expect(h[0] == full(0), "the newest record is whole")
        #expect(h[1].largest.isEmpty && h[1].overBudget.isEmpty && h[1].quietPeople.isEmpty && h[1].danglingLinks.isEmpty && h[1].duplicateSuspects.isEmpty)
        #expect(h[1].overBudgetCount == 2 && h[1].quietPeopleCount == 1 && h[1].danglingLinksCount == 3 && h[1].duplicateSuspectsCount == 1 && h[1].words == 1000 && h[1].at == full(1).at)
        #expect(h[1].line == full(1).line, "the sentence still reads from the counts")
        #expect(h[1].trimmed == h[1], "trimming again changes nothing")
        let again = VaultHealth.append(full(-1), to: h, calendar: cal)
        #expect(again[0] == full(-1) && again[1] == full(0).trimmed && again[2] == h[1], "last night's lists go the night after")
        let json = try #require(VaultHealth.json(again))
        #expect(json.components(separatedBy: "X.md").count == 2, "the quiet list is stored once, on the newest record")
        #expect(VaultHealth.history(from: json) == again)
        // A record from before `counts` — every list present, no counts key — decodes and counts from its lists.
        let legacy = try #require(VaultHealth.json([full(3)])).replacingOccurrences(of: ",\"counts\":null", with: "").replacingOccurrences(of: "\"counts\":null,", with: "")
        #expect(!legacy.contains("counts"))
        let old = try #require(VaultHealth.history(from: legacy).first)
        #expect(old.overBudgetCount == 2 && old.danglingLinksCount == 3 && old.trimmed.overBudgetCount == 2 && old.trimmed.overBudget.isEmpty)
    }

    @Test func nightlyComputesAppendsAndSaves() async throws {
        let store = try SQLiteRunStore.inMemory()
        let root = try Self.vault()
        let first = await VaultHealth.nightly(root: root, now: Self.now.addingTimeInterval(-8 * 86400), store: store, timeZone: Self.utc)
        #expect(first.notes == 8 && first.netWordsPerWeek == nil)
        try ("# New\n\n" + Self.words(50) + "\n").write(to: root.appendingPathComponent("Notes/New.md"), atomically: true, encoding: .utf8)
        let second = await VaultHealth.nightly(root: root, now: Self.now, store: store, timeZone: Self.utc)
        #expect(second.notes == 9 && second.netWordsPerWeek == 52, "measured against last week's record")
        let saved = VaultHealth.history(from: try await store.value(SettingKey.vaultHealth))
        #expect(saved.count == 2 && saved[0] == second && saved[1] == first.trimmed, "the older night keeps its counts, not its lists")
    }
}
