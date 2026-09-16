import Testing
import Foundation
import Domain
@testable import Knowledge

/// Quiet notes go to Archive/ and come back when named: the 180/120-day rules, an open line as a bar, the registry following.
@Suite struct NoteArchiveTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let now = Date(timeIntervalSince1970: 1_789_560_000)   // 2026-09-16; 180 days back is 2026-03-20, 120 is 2026-05-19
    func fresh() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func put(_ rel: String, updated: String, body: String, in root: URL) throws {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        var m = NoteMeta.fresh(path: rel, body: body, today: updated); m.updated = updated
        try (m.render() + body).write(to: u, atomically: true, encoding: .utf8)
    }
    func exists(_ rel: String, in root: URL) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path) }

    @Test func theRulesByFolderAndTheOpenLine() {
        let quiet = "# Q\n\n## About\n- x\n", open = "# Q\n\n<!-- brownie:status -->\n- ⏳ 2 Sep — they asked: “x” — no reply yet\n<!-- /brownie:status -->\n\n## About\n- x\n"
        let settled = "# Q\n\n<!-- brownie:status -->\n- ✅ 2 Sep — they asked: “x” — you replied 3 Sep 10:00\n<!-- /brownie:status -->\n"
        func due(_ rel: String, _ updated: String, _ body: String = quiet) -> Bool {
            var m = NoteMeta.fresh(path: rel, body: body, today: updated); m.updated = updated
            return NoteArchive.isDue(path: rel, raw: m.render() + body, mtime: Self.now, now: Self.now, timeZone: Self.utc)
        }
        #expect(due("People/A.md", "2026-03-20") && !due("People/A.md", "2026-03-21"), "180 days for a person")
        #expect(due("Groups/G.md", "2026-05-19") && !due("Groups/G.md", "2026-05-20"), "120 days for a group")
        #expect(!due("People/A.md", "2025-01-01", open), "an open line keeps a note in the working set")
        #expect(due("People/A.md", "2025-01-01", settled), "a settled line does not")
        #expect(!due("Work/Loadmill.md", "2020-01-01") && !due("People/Archive/A.md", "2020-01-01"), "topics and what is already archived are not the rule's")
        #expect(NoteArchive.isDue(path: "People/B.md", raw: quiet, mtime: Self.now.addingTimeInterval(-200 * 86400), now: Self.now, timeZone: Self.utc) == true, "no front-matter: the file's date decides")
        #expect(NoteArchive.isDue(path: "People/B.md", raw: quiet, mtime: Self.now.addingTimeInterval(-100 * 86400), now: Self.now, timeZone: Self.utc) == false)
    }

    @Test func archivingMovesTheFileAndTheRegistryFollows() async throws {
        let root = try fresh()
        try put("People/Old Friend.md", updated: "2026-01-10", body: "# Old Friend\n\n## About\n- x\n", in: root)
        try put("People/Kanika Pandey.md", updated: "2026-09-10", body: "# Kanika Pandey\n\n## About\n- y\n", in: root)
        try put("Groups/Quiet Group.md", updated: "2026-04-01", body: "# Quiet Group\n\n## About\n- z\n", in: root)
        try put("Groups/Live Group.md", updated: "2026-08-01", body: "# Live Group\n", in: root)
        let registry = PersonRegistry(vault: root, now: { Self.now })
        let id = await registry.register(label: "Old Friend", handle: "whatsapp:+1")
        await registry.setNotePath("People/Old Friend.md", for: id)
        let moved = await NoteArchive.archive(root: root, registry: registry, now: Self.now, timeZone: Self.utc)
        #expect(moved == ["People/Old Friend.md", "Groups/Quiet Group.md"], "People first, then Groups, each folder in name order")
        #expect(exists("People/Archive/Old Friend.md", in: root) && !exists("People/Old Friend.md", in: root))
        #expect(exists("Groups/Archive/Quiet Group.md", in: root) && exists("Groups/Live Group.md", in: root) && exists("People/Kanika Pandey.md", in: root))
        #expect(await registry.notePath(for: id) == "People/Archive/Old Friend.md")
        let saved = PersonRegistry(vault: root, now: { Self.now }); await saved.load()
        #expect(await saved.notePath(for: id) == "People/Archive/Old Friend.md", "the move is saved")
        #expect(await NoteArchive.archive(root: root, registry: registry, now: Self.now, timeZone: Self.utc).isEmpty, "a second pass finds nothing")
    }

    @Test func aMentionBringsANoteBack() async throws {
        let root = try fresh()
        try put("People/Archive/Arjun Mehta.md", updated: "2026-01-10", body: "# Arjun Mehta\n\n## About\n- x\n", in: root)
        try put("People/Archive/Priya.md", updated: "2026-01-10", body: "# Priya\n", in: root)
        try put("Groups/Archive/MPL Days.md", updated: "2026-01-10", body: "# MPL Days\n", in: root)
        let registry = PersonRegistry(vault: root, now: { Self.now })
        let id = await registry.register(label: "Arjun Mehta", handle: "whatsapp:+2")
        await registry.setNotePath("People/Archive/Arjun Mehta.md", for: id)
        #expect(await NoteArchive.unarchive(root: root, registry: registry, mentioned: ["Nobody Here"]).isEmpty)
        let back = await NoteArchive.unarchive(root: root, registry: registry, mentioned: ["Arjun", "MPL Days"])
        #expect(back == ["People/Arjun Mehta.md", "Groups/MPL Days.md"], "a first name names him; the group by its title")
        #expect(exists("People/Arjun Mehta.md", in: root) && !exists("People/Archive/Arjun Mehta.md", in: root) && exists("People/Archive/Priya.md", in: root))
        #expect(await registry.notePath(for: id) == "People/Arjun Mehta.md")
    }

    @Test func aRegistryHandleNamesAnArchivedNoteUnderAnotherSpelling() async throws {
        let root = try fresh()
        try put("People/Archive/Kanika Pandey.md", updated: "2026-01-10", body: "# Kanika Pandey\n", in: root)
        let registry = PersonRegistry(vault: root, now: { Self.now })
        let id = await registry.register(label: "Kanika Pandey", handle: "whatsapp:+3")
        await registry.register(label: "KP Loadmill", handle: "whatsapp:+3")
        await registry.setNotePath("People/Archive/Kanika Pandey.md", for: id)
        #expect(await NoteArchive.unarchive(root: root, registry: registry, mentioned: ["KP Loadmill"]) == ["People/Kanika Pandey.md"], "the alias resolves through the registry")
    }

    @Test func nothingIsEverOverwritten() async throws {
        let root = try fresh()
        try put("People/Archive/Arjun.md", updated: "2026-01-10", body: "# Arjun\n", in: root)
        try put("People/Arjun.md", updated: "2026-09-10", body: "# Arjun\n\n## About\n- new note\n", in: root)
        #expect(await NoteArchive.unarchive(root: root, registry: nil, mentioned: ["Arjun"]).isEmpty)
        #expect(exists("People/Archive/Arjun.md", in: root), "both stay; a person can be told about it")
    }

    @Test func pathsRoundTrip() {
        #expect(NoteArchive.archivedPath("People/Arjun Mehta.md") == "People/Archive/Arjun Mehta.md" && NoteArchive.activePath("Groups/Archive/MPL Days.md") == "Groups/MPL Days.md")
        #expect(NoteArchive.isArchived("People/Archive/X.md") && !NoteArchive.isArchived("People/X.md") && !NoteArchive.isArchived("Archive/X.md"))
        #expect(NoteArchive.archivedPath("People/Archive/X.md") == "People/Archive/X.md", "never twice")
    }
}
