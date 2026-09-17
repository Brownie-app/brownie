import Testing
import Foundation
import Domain
@testable import Knowledge

/// The nightly pass on a temp vault: what changes is rewritten as code's, what is in shape is not touched, and the line says what happened.
@Suite struct VaultGardenerTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let now = Date(timeIntervalSince1970: 1_789_560_000)   // 2026-09-16
    func fresh() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gardener-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func put(_ rel: String, _ text: String, in root: URL) throws {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }
    func raw(_ rel: String, in root: URL) -> String? { try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) }
    func stamped(_ rel: String, _ body: String, updated: String = "2026-09-01") -> String { var m = NoteMeta.fresh(path: rel, body: body, today: updated); m.updated = updated; return m.render() + body }

    @Test func changedNotesAreRestampedAndUnchangedOnesUntouched() async throws {
        let root = try fresh()
        let messy = "# Arjun Mehta\n\nOld friend.\n\n## Pending\n- Asked about the flat (2026-07-01)\n- Wants the photos (2026-09-10)\n"
        try put("People/Arjun Mehta.md", stamped("People/Arjun Mehta.md", messy), in: root)
        let tidy = "# Priya\n\n## About\n- Sister-in-law.\n\n## Now\n- Flight dates (2026-09-12)\n"
        try put("People/Priya.md", stamped("People/Priya.md", tidy), in: root)
        try put("Groups/MPL Days.md", stamped("Groups/MPL Days.md", "# MPL Days\n\nThe college group.\n"), in: root)
        try put("Work/Loadmill.md", stamped("Work/Loadmill.md", "# Loadmill\n\n## Pending\n- untouched\n"), in: root)
        try put("People/Archive/Old.md", stamped("People/Archive/Old.md", "# Old\n\n## Pending\n- untouched\n"), in: root)
        let before = (raw("People/Priya.md", in: root), raw("Work/Loadmill.md", in: root), raw("People/Archive/Old.md", in: root))
        let s = await VaultGardener.run(root: root, registry: nil, now: Self.now, timeZone: Self.utc, retiredLines: { $0 == "People/Arjun Mehta.md" ? ["- ✅ 20 Aug — they asked: “dinner?” — you replied 2 Sep 14:00"] : [] }, archive: false)
        #expect(s.notes == 3 && s.tidied == 2 && s.movedToEarlier == 1 && s.retired == 1 && s.archived == 0)
        #expect(s.changed == ["People/Arjun Mehta.md", "Groups/MPL Days.md"])
        #expect(s.line == "gardener: 2 notes tidied, 1 bullet moved to Earlier, 1 retired line kept, 0 archived")
        let (meta, body) = NoteMeta.parse(raw("People/Arjun Mehta.md", in: root)!, path: "People/Arjun Mehta.md")
        #expect(body == "# Arjun Mehta\n\n## About\n- Old friend.\n\n## Now\n- Wants the photos (2026-09-10)\n\n## Earlier\n- 2026-09 — they asked: “dinner?” — you replied 2 Sep 14:00\n- 2026-07 — Asked about the flat\n")
        #expect(meta?.updated == "2026-09-01" && meta?.contentHash == NoteMeta.hash(body) && meta?.userEdited == false, "the hash moves with the rewrite; updated does not; nobody edited anything")
        #expect(raw("People/Priya.md", in: root) == before.0 && raw("Work/Loadmill.md", in: root) == before.1 && raw("People/Archive/Old.md", in: root) == before.2, "in shape, a topic, archived: byte for byte")
        let again = await VaultGardener.run(root: root, registry: nil, now: Self.now, timeZone: Self.utc, archive: false)
        #expect(again.tidied == 0, "a second night with nothing new changes nothing")
    }

    @Test func aUsersEditIsStillNoticedAfterTheGardener() async throws {
        let root = try fresh()
        // Brownie wrote one thing; the user changed the body in Obsidian; the hash on disk no longer matches.
        var m = NoteMeta.fresh(path: "People/A.md", body: "# A\n\nwhat Brownie wrote\n", today: "2026-09-01")
        m.updated = "2026-09-01"
        try put("People/A.md", m.render() + "# A\n\nwhat the user wrote\n\n## Pending\n- thing (2026-09-10)\n", in: root)
        await VaultGardener.run(root: root, registry: nil, now: Self.now, timeZone: Self.utc, archive: false)
        let (meta, body) = NoteMeta.parse(raw("People/A.md", in: root)!, path: "People/A.md")
        #expect(body == "# A\n\n## About\n- what the user wrote\n\n## Now\n- thing (2026-09-10)\n")
        #expect(meta?.bodyDiffers(body) == true, "the old hash stays, so the edit still reads as the user's")
    }

    @Test func quietNotesAreArchivedInTheSamePass() async throws {
        let root = try fresh()
        try put("People/Quiet.md", stamped("People/Quiet.md", "# Quiet\n\n## About\n- x\n", updated: "2026-01-01"), in: root)
        try put("People/Loud.md", stamped("People/Loud.md", "# Loud\n\n## About\n- y\n", updated: "2026-09-10"), in: root)
        let registry = PersonRegistry(vault: root, now: { Self.now })
        let id = await registry.register(label: "Quiet", handle: nil); await registry.setNotePath("People/Quiet.md", for: id)
        let s = await VaultGardener.run(root: root, registry: registry, now: Self.now, timeZone: Self.utc)
        #expect(s.archived == 1 && s.line == "gardener: 0 notes tidied, 0 bullets moved to Earlier, 1 person archived")
        #expect(raw("People/Archive/Quiet.md", in: root) != nil && raw("People/Quiet.md", in: root) == nil && raw("People/Loud.md", in: root) != nil)
        #expect(await registry.notePath(for: id) == "People/Archive/Quiet.md")
    }

    @Test func aMissingVaultIsNothingToDo() async {
        let s = await VaultGardener.run(root: URL(fileURLWithPath: "/nonexistent/brownie-\(UUID().uuidString)"), now: Self.now)
        #expect(s == VaultGardener.Summary())
    }

    /// The line is offered on every night of a fortnight (a closed Mac must not lose it); the note takes it once.
    @Test func aRetiredLineOfferedNightAfterNightIsKeptOnce() async throws {
        let root = try fresh()
        try put("People/Meera.md", stamped("People/Meera.md", "# Meera\n\n## About\n- x\n"), in: root)
        let line = "- ✅ 20 Aug — they asked: “dinner?” — you replied 2 Sep 14:00"
        let first = await VaultGardener.run(root: root, registry: nil, now: Self.now, timeZone: Self.utc, retiredLines: { _ in [line] }, archive: false)
        #expect(first.retired == 1 && first.tidied == 1)
        let once = raw("People/Meera.md", in: root)
        // the next night, and a night a week on: offered again, nothing doubles
        for night in [1.0, 8.0] {
            let again = await VaultGardener.run(root: root, registry: nil, now: Self.now.addingTimeInterval(night * 86400), timeZone: Self.utc, retiredLines: { _ in [line] }, archive: false)
            #expect(again.retired == 0 && again.tidied == 0 && raw("People/Meera.md", in: root) == once, "night +\(Int(night)): byte for byte")
        }
        #expect(once!.components(separatedBy: "they asked: “dinner?”").count == 2)
    }

    /// At launch the vault is tidied and nothing more: no archiving (the night does that after its swap), and nothing at all
    /// while a sync is mid-way — the builder froze every note's stamp, and a rewrite now would be kept as the user's edit
    /// over the brain's merged work when the sync resumes.
    @Test func atLaunchTidiesOnlyAndWaitsForAPendingSync() async throws {
        let root = try fresh()
        let messy = "# Arjun Mehta\n\nOld friend.\n\n## Pending\n- Asked about the flat (2026-07-01)\n"
        try put("People/Arjun Mehta.md", stamped("People/Arjun Mehta.md", messy), in: root)
        try put("People/Quiet.md", stamped("People/Quiet.md", "# Quiet\n\n## About\n- x\n", updated: "2026-01-01"), in: root)
        let before = (raw("People/Arjun Mehta.md", in: root), raw("People/Quiet.md", in: root))
        #expect(await VaultGardener.atLaunch(root: root, now: Self.now, timeZone: Self.utc, syncPending: true) == nil)
        #expect(raw("People/Arjun Mehta.md", in: root) == before.0 && raw("People/Quiet.md", in: root) == before.1, "a sync is mid-way: not a byte")
        let s = try #require(await VaultGardener.atLaunch(root: root, now: Self.now, timeZone: Self.utc, syncPending: false))
        #expect(s.tidied == 1 && s.archived == 0 && s.changed == ["People/Arjun Mehta.md"])
        #expect(raw("People/Quiet.md", in: root) == before.1 && raw("People/Archive/Quiet.md", in: root) == nil, "quiet, but launch does not archive")
    }

    /// What the pipeline asks to keep — the household's shared group notes, what came back from Archive/ tonight — the move never takes.
    @Test func keptNotesStayThroughTheNightlyPass() async throws {
        let root = try fresh()
        try put("Groups/Building Chat.md", stamped("Groups/Building Chat.md", "# Building Chat\n\n## About\n- x\n", updated: "2026-01-01"), in: root)
        try put("Groups/Old Club.md", stamped("Groups/Old Club.md", "# Old Club\n\n## About\n- y\n", updated: "2026-01-01"), in: root)
        let s = await VaultGardener.run(root: root, registry: nil, now: Self.now, timeZone: Self.utc, keep: ["Groups/Building Chat.md"])
        #expect(s.archived == 1 && raw("Groups/Building Chat.md", in: root) != nil && raw("Groups/Archive/Old Club.md", in: root) != nil)
    }
}
