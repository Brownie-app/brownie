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
        try put("People/Arjun Mehta.md", "---\nsources: whatsapp\nupdated: 2026-01-10T08:00:00Z\nuser_edited: false\n---\n# Arjun Mehta\n\nOld friend. See [[Priya Sharma]] and [[Nobody]].\n\n<!-- brownie:status -->\n- ⏳ 2 Aug — they asked: “dinner?” — no reply yet\n- ✅ 1 Jan — you promised (1 Jan): a thing — done 3 Jan\n- ⏳ 20 Dec — you promised (20 Dec): the book\n<!-- /brownie:status -->\n", modified: fresh)   // quiet by front matter; 20 Dec is last year's
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
        #expect(h.quietPeople == ["People/Arjun Mehta.md", "People/Kanika Pandey Loadmill.md"], "an old `updated:` counts even on a fresh file; no front matter falls back to the file's date")
    }

    @Test func danglingLinksAreNamesNoNoteAnswersTo() throws {
        let h = VaultHealth.compute(root: try Self.vault(), now: Self.now, timeZone: Self.utc)
        #expect(h.danglingLinks.map(\.name) == ["Lost Group", "Nobody"], "alias and heading forms fold into one name; title and file name both resolve, case-insensitively")
        #expect(h.danglingLinks.map(\.path) == ["Groups/Upreti Family.md", "People/Arjun Mehta.md"], "the first note it was found in")
    }

    @Test func duplicateSuspectsAreTheSamePersonKeyOrAFirstNameAlone() throws {
        let h = VaultHealth.compute(root: try Self.vault(), now: Self.now, timeZone: Self.utc)
        #expect(h.duplicateSuspects == [.init(a: "People/Arjun Mehta.md", b: "People/Arjun.md")])
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

    @Test func nightlyComputesAppendsAndSaves() async throws {
        let store = try SQLiteRunStore.inMemory()
        let root = try Self.vault()
        let first = await VaultHealth.nightly(root: root, now: Self.now.addingTimeInterval(-8 * 86400), store: store, timeZone: Self.utc)
        #expect(first.notes == 8 && first.netWordsPerWeek == nil)
        try ("# New\n\n" + Self.words(50) + "\n").write(to: root.appendingPathComponent("Notes/New.md"), atomically: true, encoding: .utf8)
        let second = await VaultHealth.nightly(root: root, now: Self.now, store: store, timeZone: Self.utc)
        #expect(second.notes == 9 && second.netWordsPerWeek == 52, "measured against last week's record")
        let saved = VaultHealth.history(from: try await store.value(SettingKey.vaultHealth))
        #expect(saved.count == 2 && saved[0] == second && saved[1] == first)
    }
}
