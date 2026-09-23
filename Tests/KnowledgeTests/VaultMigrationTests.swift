import Testing
import Foundation
import Domain
import Platform
@testable import Knowledge

/// The one-time stamp on a live vault: every note gets the block once, and a second run finds nothing to do.
@Suite struct VaultMigrationTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let now = Date(timeIntervalSince1970: 1_789_560_000)   // 2026-09-16
    func fresh() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migrate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    /// `born` pins the file's birth date, which is where `created` comes from — never the clock of the machine running the test.
    func put(_ rel: String, _ text: String, in root: URL, born: Date? = nil) throws {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
        if let born { try FileManager.default.setAttributes([.creationDate: born], ofItemAtPath: u.path) }
    }
    func raw(_ rel: String, in root: URL) -> String? { try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) }

    @Test func stampsEveryBareNoteOnceAndLeavesTheRestAlone() async throws {
        let root = try fresh()
        try put("README.md", "# Me\nportrait\n", in: root, born: Date(timeIntervalSince1970: 1_788_000_000))   // 2026-08-29 UTC
        try put("People/Kanika Pandey.md", "# Kanika Pandey\nfriend\n", in: root)
        try put("Work/Loadmill.md", "---\nsources: gmail, slack\nupdated: 2026-09-10T03:00:00Z\nuser_edited: true\n---\n# Loadmill\n", in: root)
        try put("Groups/Founders.md", NoteMeta.fresh(path: "Groups/Founders.md", body: "# Founders\n", today: "2026-08-01").render() + "# Founders\n", in: root)
        try put("Today.md", "# Today\n", in: root)
        try put(".brownie/people.json", "{}", in: root)
        let registry = PersonRegistry(vault: root, now: { Self.now })
        let id = await registry.register(label: "Kanika Pandey Loadmill", handle: "whatsapp:+919")
        let done = await VaultMigration.addFrontMatter(root: root, registry: registry, now: Self.now, timeZone: Self.utc)
        #expect(done == 3, "the README, the person and the legacy topic; the owned group note and Today.md are not touched")
        let readme = try #require(NoteMeta.parse(raw("README.md", in: root)!, path: "README.md").meta)
        #expect(readme.brownie == "portrait" && readme.updated == "2026-09-16" && readme.created == "2026-08-29" && readme.contentHash == NoteMeta.hash("# Me\nportrait\n") && !readme.userEdited, "created is the file's birth day, updated is today")
        let kanika = try #require(NoteMeta.parse(raw("People/Kanika Pandey.md", in: root)!, path: "People/Kanika Pandey.md").meta)
        #expect(kanika.brownie == "person" && kanika.id == id && kanika.aliases == ["Kanika Pandey Loadmill"], "the registry's id and other spellings ride on the note")
        let loadmill = try #require(NoteMeta.parse(raw("Work/Loadmill.md", in: root)!, path: "Work/Loadmill.md").meta)
        #expect(loadmill.brownie == "topic" && loadmill.sources == ["gmail", "slack"] && loadmill.userEdited && loadmill.updated == "2026-09-16", "a legacy block keeps its sources and its edited flag")
        #expect(raw("Groups/Founders.md", in: root)!.contains("created: 2026-08-01\nupdated: 2026-08-01\n"), "already Brownie's: untouched")
        #expect(raw("Today.md", in: root) == "# Today\n")
        #expect(raw("Work/Loadmill.md", in: root)!.hasSuffix("---\n# Loadmill\n"), "the body is as it was")
    }

    /// An Obsidian user's own `aliases:` are what their [[Kani]] links resolve by; the registry's spellings join them, they do not replace them.
    @Test func theUsersOwnAliasesStayAndTheRegistrysJoinThem() async throws {
        let root = try fresh()
        try put("People/Kanika Pandey.md", "---\naliases:\n  - Kani\n  - KP\n---\n# Kanika Pandey\nfriend\n", in: root)
        try put(".brownie/people.json", "{}", in: root)
        let registry = PersonRegistry(vault: root, now: { Self.now })
        let id = await registry.register(label: "Kanika Pandey Loadmill", handle: "whatsapp:+919")
        _ = await registry.register(label: "kp", handle: "whatsapp:+919")   // the registry spells one of hers differently
        #expect(await VaultMigration.addFrontMatter(root: root, registry: registry, now: Self.now, timeZone: Self.utc) == 1)
        let kanika = try #require(NoteMeta.parse(raw("People/Kanika Pandey.md", in: root)!, path: "People/Kanika Pandey.md").meta)
        #expect(kanika.id == id && kanika.aliases == ["Kani", "KP", "Kanika Pandey Loadmill"], "hers first, the registry's after, none twice")
    }

    @Test func aSecondRunDoesNothing() async throws {
        let root = try fresh()
        try put("People/A.md", "# A\n", in: root); try put("Work/B.md", "# B\n", in: root)
        #expect(await VaultMigration.addFrontMatter(root: root, registry: nil, now: Self.now, timeZone: Self.utc) == 2)
        let before = (raw("People/A.md", in: root), raw("Work/B.md", in: root))
        #expect(await VaultMigration.addFrontMatter(root: root, registry: nil, now: Self.now.addingTimeInterval(86400), timeZone: Self.utc) == 0)
        #expect(raw("People/A.md", in: root) == before.0 && raw("Work/B.md", in: root) == before.1)
    }

    @Test func aMissingVaultIsNothingToDo() async {
        #expect(await VaultMigration.addFrontMatter(root: URL(fileURLWithPath: "/nonexistent/brownie-\(UUID().uuidString)"), registry: nil, now: Self.now) == 0)
    }

    // MARK: the user is never a person

    /// The vault as the user found it: a People note titled after them, a registry record for it, and a loop that
    /// names them as the other party. After the pass the note is a topic under Life/, the record and the loop are gone,
    /// and the real people are untouched.
    @Test func aPeopleNoteAboutTheUserMovesToLifeAndTheirRecordAndLoopsGo() async throws {
        let root = try fresh()
        let title = "Vivek Upreti — Career Materials (Jul–Aug 2026)"
        try put("People/\(title).md", "# \(title)\n\n<!-- brownie:status -->\n## Between you\n- ⏳ you promised (18 Sep): Close one more deal after SBI\n<!-- /brownie:status -->\n\n## About\n- Placeholder\n\n## Now\n- CV sent to SBI (2026-08-20)\n", in: root)
        try put("People/Vivek.md", "---\naliases:\n  - VU\n  - Vivek Upreti\n---\n# Vivek\nThe user, by mistake.\n", in: root)
        try put("People/Kanika Pandey.md", "# Kanika Pandey\nfriend\n", in: root)
        try put("Life/Career Materials (Jul–Aug 2026).md", "# Career Materials (Jul–Aug 2026)\nthe user's own note\n", in: root)
        // The registry as an older Brownie left it: a record for the user, with the note as its path, beside Kanika's.
        let stale = PersonRegistry(vault: root, now: { Self.now })
        let kanika = await stale.register(label: "Kanika Pandey", handle: "whatsapp:+919")
        let vivek = await stale.register(label: title, handle: nil)
        await stale.setNotePath("People/\(title).md", for: vivek)
        try await stale.save()
        let names = ["Vivek Upreti", "vivek"]
        let registry = PersonRegistry(vault: root, now: { Self.now }, selfNames: names)
        await registry.load()
        #expect(await registry.person(vivek) != nil)
        _ = await VaultMigration.addFrontMatter(root: root, registry: registry, now: Self.now, timeZone: Self.utc)
        let store = try SQLiteRunStore.inMemory()
        let loops = [Loop(id: "SELF", direction: .mine, person: "Vivek Upreti", what: "Close one more deal after SBI", quote: "q", sourceLabel: "WhatsApp · Fri", due: nil, openedAt: Self.now),
                     Loop(id: "KEEP", direction: .mine, person: "Kanika Pandey", what: "Send the proposal", quote: "q", sourceLabel: "WhatsApp · Fri", due: nil, openedAt: Self.now)]
        try await store.setValue(SettingKey.loops, String(data: try JSONEncoder().encode(loops), encoding: .utf8))

        let moved = await VaultMigration.moveSelfNotes(root: root, registry: registry, store: store, selfNames: names, now: Self.now, timeZone: Self.utc)
        #expect(moved == 2, "the dashed title and the bare name both move")
        #expect(raw("People/\(title).md", in: root) == nil && raw("People/Vivek.md", in: root) == nil)
        let life = try #require(raw("Life/Career Materials (Jul–Aug 2026) 2.md", in: root), "never over the note already there: ' 2' is added")
        let meta = try #require(NoteMeta.parse(life, path: "Life/Career Materials (Jul–Aug 2026) 2.md").meta)
        #expect(meta.brownie == "topic" && meta.id == nil && meta.aliases.isEmpty, "a topic's block now, with no person id")
        #expect(life.hasSuffix("# Career Materials (Jul–Aug 2026)\n\n## About\n- Placeholder\n\n## Now\n- CV sent to SBI (2026-08-20)\n"), "the title loses the name and the status block goes; the body is kept")
        #expect(!life.contains("brownie:status"), "a topic note carries no ledger")
        #expect(meta.contentHash == NoteMeta.hash("# Career Materials (Jul–Aug 2026)\n\n## About\n- Placeholder\n\n## Now\n- CV sent to SBI (2026-08-20)\n") && !meta.userEdited, "the hash follows the retitle, so the move is not an edit")
        #expect(raw("Life/Career Materials (Jul–Aug 2026).md", in: root)!.hasSuffix("the user's own note\n"), "the user's own note is untouched")
        let bare = try #require(raw("Life/Vivek.md", in: root), "a note that is only the name keeps it as its title")
        #expect(bare.contains("aliases: [VU]\n") && bare.hasSuffix("# Vivek\nThe user, by mistake.\n"), "the user's own alias stays; the self spellings go")
        #expect(raw("People/Kanika Pandey.md", in: root)!.hasSuffix("# Kanika Pandey\nfriend\n"))
        let gone = await registry.person(vivek), stays = await registry.person(kanika)
        #expect(gone == nil && stays != nil, "the user's record is gone, Kanika's stays")
        let onDisk = PersonRegistry(vault: root, now: { Self.now }); await onDisk.load()
        #expect(await onDisk.person(vivek) == nil, "and gone from the file")
        let ledger = try JSONDecoder().decode([Loop].self, from: Data((try await store.value(SettingKey.loops) ?? "").utf8))
        #expect(ledger.map(\.id) == ["KEEP"], "the loop with the user as the other party is dropped")
        #expect(await VaultMigration.moveSelfNotes(root: root, registry: registry, store: store, selfNames: names, now: Self.now, timeZone: Self.utc) == 0, "a second run finds nothing")
        #expect(await VaultMigration.moveSelfNotes(root: root, registry: registry, store: store, selfNames: [], now: Self.now, timeZone: Self.utc) == 0, "no names, nothing to do")
    }
}
