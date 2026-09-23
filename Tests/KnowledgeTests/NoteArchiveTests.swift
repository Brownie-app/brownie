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
        #expect(!due("People/A.md", "2025-01-01", settled), "a settled line's dates are life between you: replied 3 Sep, not quiet yet")
        let settledRaw: String = { var m = NoteMeta.fresh(path: "People/A.md", body: settled, today: "2025-01-01"); m.updated = "2025-01-01"; return m.render() + settled }()
        #expect(NoteArchive.isDue(path: "People/A.md", raw: settledRaw, mtime: Self.now, now: Self.now.addingTimeInterval(180 * 86400), timeZone: Self.utc), "a settled line does not bar the move once its dates are quiet")
        #expect(!due("Work/Tideline.md", "2020-01-01") && !due("People/Archive/A.md", "2020-01-01"), "topics and what is already archived are not the rule's")
        #expect(NoteArchive.isDue(path: "People/B.md", raw: quiet, mtime: Self.now.addingTimeInterval(-200 * 86400), now: Self.now, timeZone: Self.utc) == true, "no front-matter: the file's date decides")
        #expect(NoteArchive.isDue(path: "People/B.md", raw: quiet, mtime: Self.now.addingTimeInterval(-100 * 86400), now: Self.now, timeZone: Self.utc) == false)
    }

    @Test func archivingMovesTheFileAndTheRegistryFollows() async throws {
        let root = try fresh()
        try put("People/Old Friend.md", updated: "2026-01-10", body: "# Old Friend\n\n## About\n- x\n", in: root)
        try put("People/Lalita Pathak.md", updated: "2026-09-10", body: "# Lalita Pathak\n\n## About\n- y\n", in: root)
        try put("Groups/Quiet Group.md", updated: "2026-04-01", body: "# Quiet Group\n\n## About\n- z\n", in: root)
        try put("Groups/Live Group.md", updated: "2026-08-01", body: "# Live Group\n", in: root)
        let registry = PersonRegistry(vault: root, now: { Self.now })
        let id = await registry.register(label: "Old Friend", handle: "whatsapp:+1")
        await registry.setNotePath("People/Old Friend.md", for: id)
        let moved = await NoteArchive.archive(root: root, registry: registry, now: Self.now, timeZone: Self.utc)
        #expect(moved == ["People/Old Friend.md", "Groups/Quiet Group.md"], "People first, then Groups, each folder in name order")
        #expect(exists("People/Archive/Old Friend.md", in: root) && !exists("People/Old Friend.md", in: root))
        #expect(exists("Groups/Archive/Quiet Group.md", in: root) && exists("Groups/Live Group.md", in: root) && exists("People/Lalita Pathak.md", in: root))
        #expect(await registry.notePath(for: id) == "People/Archive/Old Friend.md")
        let saved = PersonRegistry(vault: root, now: { Self.now }); await saved.load()
        #expect(await saved.notePath(for: id) == "People/Archive/Old Friend.md", "the move is saved")
        #expect(await NoteArchive.archive(root: root, registry: registry, now: Self.now, timeZone: Self.utc).isEmpty, "a second pass finds nothing")
    }

    @Test func aMentionBringsANoteBack() async throws {
        let root = try fresh()
        try put("People/Archive/Kiran Bose.md", updated: "2026-01-10", body: "# Kiran Bose\n\n## About\n- x\n", in: root)
        try put("People/Archive/Tanvi.md", updated: "2026-01-10", body: "# Tanvi\n", in: root)
        try put("Groups/Archive/MPL Days.md", updated: "2026-01-10", body: "# MPL Days\n", in: root)
        let registry = PersonRegistry(vault: root, now: { Self.now })
        let id = await registry.register(label: "Kiran Bose", handle: "whatsapp:+2")
        await registry.setNotePath("People/Archive/Kiran Bose.md", for: id)
        #expect(await NoteArchive.unarchive(root: root, registry: registry, mentioned: ["Nobody Here"], now: Self.now, timeZone: Self.utc).isEmpty)
        let back = await NoteArchive.unarchive(root: root, registry: registry, mentioned: ["Kiran", "MPL Days"], now: Self.now, timeZone: Self.utc)
        #expect(back == ["People/Kiran Bose.md", "Groups/MPL Days.md"], "a first name names him; the group by its title")
        #expect(exists("People/Kiran Bose.md", in: root) && !exists("People/Archive/Kiran Bose.md", in: root) && exists("People/Archive/Tanvi.md", in: root))
        #expect(await registry.notePath(for: id) == "People/Kiran Bose.md")
    }

    @Test func aRegistryHandleNamesAnArchivedNoteUnderAnotherSpelling() async throws {
        let root = try fresh()
        try put("People/Archive/Lalita Pathak.md", updated: "2026-01-10", body: "# Lalita Pathak\n", in: root)
        let registry = PersonRegistry(vault: root, now: { Self.now })
        let id = await registry.register(label: "Lalita Pathak", handle: "whatsapp:+3")
        await registry.register(label: "KP Tideline", handle: "whatsapp:+3")
        await registry.setNotePath("People/Archive/Lalita Pathak.md", for: id)
        #expect(await NoteArchive.unarchive(root: root, registry: registry, mentioned: ["KP Tideline"], now: Self.now, timeZone: Self.utc) == ["People/Lalita Pathak.md"], "the alias resolves through the registry")
    }

    @Test func nothingIsEverOverwritten() async throws {
        let root = try fresh()
        try put("People/Archive/Kiran.md", updated: "2026-01-10", body: "# Kiran\n", in: root)
        try put("People/Kiran.md", updated: "2026-09-10", body: "# Kiran\n\n## About\n- new note\n", in: root)
        #expect(await NoteArchive.unarchive(root: root, registry: nil, mentioned: ["Kiran"], now: Self.now, timeZone: Self.utc).isEmpty)
        #expect(exists("People/Archive/Kiran.md", in: root), "both stay; a person can be told about it")
    }

    @Test func pathsRoundTrip() {
        #expect(NoteArchive.archivedPath("People/Kiran Bose.md") == "People/Archive/Kiran Bose.md" && NoteArchive.activePath("Groups/Archive/MPL Days.md") == "Groups/MPL Days.md")
        #expect(NoteArchive.isArchived("People/Archive/X.md") && !NoteArchive.isArchived("People/X.md") && !NoteArchive.isArchived("Archive/X.md"))
        #expect(NoteArchive.archivedPath("People/Archive/X.md") == "People/Archive/X.md", "never twice")
    }

    /// Obsidian moves the file's date and nothing else; `updated` is Brownie's and stays. The gardener's own rewrite keeps
    /// the hash in step, so it is not life — only a body that no longer hashes to what Brownie wrote (or a block with no hash) is.
    @Test func aHandEditTodayIsActivityButCodesRewriteIsNot() {
        let rel = "People/Old Friend.md", written = "# Old Friend\n\n## About\n- x\n"
        var m = NoteMeta.fresh(path: rel, body: written, today: "2026-01-10"); m.updated = "2026-01-10"
        let edited = m.render() + "# Old Friend\n\n## About\n- x\n- and a line I added this afternoon\n"
        #expect(!NoteArchive.isDue(path: rel, raw: edited, mtime: Self.now.addingTimeInterval(-6 * 3600), now: Self.now, timeZone: Self.utc), "written in six hours ago: not quiet")
        #expect(NoteArchive.isDue(path: rel, raw: edited, mtime: Self.now.addingTimeInterval(-181 * 86400), now: Self.now, timeZone: Self.utc), "an edit from long ago is as quiet as the block says")
        #expect(NoteArchive.isDue(path: rel, raw: m.render() + written, mtime: Self.now, now: Self.now, timeZone: Self.utc), "the file's date alone, on a body Brownie wrote, is code's tidying — not life")
        m.contentHash = ""
        #expect(!NoteArchive.isDue(path: rel, raw: m.render() + written, mtime: Self.now, now: Self.now, timeZone: Self.utc), "no hash to judge by: the file's date decides")
    }

    /// A promise from March closed yesterday sits on the block as a settled line: the newest date on the block is life.
    @Test func theStatusBlocksNewestDateIsActivity() {
        let rel = "People/Devan.md"
        func note(_ block: String) -> String {
            let body = "# Devan\n\n<!-- brownie:status -->\n\(block)\n<!-- /brownie:status -->\n\n## About\n- x\n"
            var m = NoteMeta.fresh(path: rel, body: body, today: "2025-01-01"); m.updated = "2025-01-01"; return m.render() + body
        }
        let old = Self.now.addingTimeInterval(-300 * 86400)
        #expect(!NoteArchive.isDue(path: rel, raw: note("- ✅ you promised (1 Mar): the villa share — done 15 Sep (you replied)"), mtime: old, now: Self.now, timeZone: Self.utc), "done yesterday")
        #expect(NoteArchive.isDue(path: rel, raw: note("- ⌛ you promised (1 Jan): the villa share — no news in 90 days; no longer tracked (lapsed 1 Mar)"), mtime: old, now: Self.now, timeZone: Self.utc), "every date on it is past the term")
        #expect(NoteArchive.isDue(path: rel, raw: note("- ✅ 20 Dec — they asked: “x” — you replied 21 Dec 10:00"), mtime: old, now: Self.now, timeZone: Self.utc), "a December date read in September is last December's")
    }

    /// A WhatsApp contact never saved: the chat is a bare number, which has no name to match, but the registry knows the handle.
    @Test func aHandleBringsBackANoteWhoseLabelIsNoName() async throws {
        let root = try fresh()
        try put("People/Archive/Lokesh.md", updated: "2026-01-10", body: "# Lokesh\n", in: root)
        let registry = PersonRegistry(vault: root, now: { Self.now })
        let id = await registry.register(label: "+91 90000 00666", handle: "whatsapp:+919000000666")
        await registry.setNotePath("People/Archive/Lokesh.md", for: id)
        #expect(await NoteArchive.unarchive(root: root, registry: registry, mentioned: ["+91 90000 00666"], now: Self.now, timeZone: Self.utc).isEmpty, "the number alone names nobody")
        let back = await NoteArchive.unarchive(root: root, registry: registry, mentioned: [NoteArchive.Mention("+91 90000 00666", handle: "whatsapp:+919000000666")], now: Self.now, timeZone: Self.utc)
        #expect(back == ["People/Lokesh.md"] && exists("People/Lokesh.md", in: root), "the handle does, whatever the chat is called")
        #expect(await registry.notePath(for: id) == "People/Lokesh.md")
    }

    /// The household's shared group notes are kept out of Archive/: the sync would take an archived one off the shared folder for everyone.
    @Test func aKeptNoteIsNeverArchived() async throws {
        let root = try fresh()
        try put("Groups/Building Chat.md", updated: "2026-03-01", body: "# Building Chat\n", in: root)
        try put("Groups/Old Club.md", updated: "2026-03-01", body: "# Old Club\n", in: root)
        let shared: Set<String> = ["Groups/Building Chat.md"]
        let keep = Set(["Groups/Building Chat.md", "Groups/Old Club.md"].filter { HouseholdVault.isShared($0, sharedGroupNotes: shared) })
        #expect(await NoteArchive.archive(root: root, registry: nil, now: Self.now, timeZone: Self.utc, keep: keep) == ["Groups/Old Club.md"])
        #expect(exists("Groups/Building Chat.md", in: root) && !exists("Groups/Archive/Building Chat.md", in: root), "shared: stays however quiet")
    }

    /// A chat read every night whose note the brain leaves as it was: the night it comes back is stamped on it, so the
    /// same pass — and the next 120 days — do not send it away again.
    @Test func aNoteBroughtBackTonightIsNotSentAwayAgain() async throws {
        let root = try fresh()
        try put("Groups/Archive/Building Chat.md", updated: "2026-05-01", body: "# Building Chat\n\n## About\n- the building\n", in: root)
        #expect(await NoteArchive.unarchive(root: root, registry: nil, mentioned: ["Building Chat"], now: Self.now, timeZone: Self.utc) == ["Groups/Building Chat.md"])
        let raw = try #require(try? String(contentsOf: root.appendingPathComponent("Groups/Building Chat.md"), encoding: .utf8))
        let (meta, body) = NoteMeta.parse(raw, path: "Groups/Building Chat.md")
        #expect(meta?.extra[NoteArchive.unarchivedKey]?.trimmingCharacters(in: .whitespaces) == "2026-09-16" && meta?.updated == "2026-05-01" && meta?.bodyDiffers(body) == false, "stamped as code's own change: updated and the hash stand")
        #expect(await NoteArchive.archive(root: root, registry: nil, now: Self.now, timeZone: Self.utc).isEmpty, "the same night: it stays")
        #expect(exists("Groups/Building Chat.md", in: root))
        #expect(!NoteArchive.isDue(path: "Groups/Building Chat.md", raw: raw, mtime: Self.now, now: Self.now.addingTimeInterval(119 * 86400), timeZone: Self.utc))
        #expect(NoteArchive.isDue(path: "Groups/Building Chat.md", raw: raw, mtime: Self.now, now: Self.now.addingTimeInterval(120 * 86400), timeZone: Self.utc), "the clock restarts from the night it came back")
    }
}
