import Testing
import Foundation
import Domain
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
}
