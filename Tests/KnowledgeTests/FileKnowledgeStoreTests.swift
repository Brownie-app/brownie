import Testing
import Foundation
import Domain
@testable import Knowledge

/// The store as the keeper of the front-matter: an edit made anywhere is noticed by its hash, a save keeps what
/// the user added, `updated` moves only with the substance, and Today.md is never knowledge.
@Suite struct FileKnowledgeStoreTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let today = Date(timeIntervalSince1970: 1_789_560_000)   // 2026-09-16
    struct World {
        let root: URL, kb: FileKnowledgeStore
        func put(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        func raw(_ rel: String) -> String? { try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) }
    }
    static func world(now: Date = today) throws -> World {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fks-\(UUID().uuidString)", isDirectory: true)
        let root = dir.appendingPathComponent("KB", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return World(root: root, kb: try FileKnowledgeStore(root: root, indexPath: dir.appendingPathComponent("index.sqlite").path, now: { now }, timeZone: utc))
    }
    static func owned(_ body: String, path: String, updated: String = "2026-09-10", extra: String = "") -> String {
        var m = NoteMeta.fresh(path: path, body: body, today: "2026-09-01"); m.updated = updated
        return m.render().replacingOccurrences(of: "\n---\n", with: extra.isEmpty ? "\n---\n" : "\n\(extra)\n---\n") + body
    }

    @Test func anEditMadeOutsideTheAppCountsAsTheUsers() async throws {
        let w = try Self.world()
        try w.put("People/Arif.md", Self.owned("# Arif\n\nA friend.\n", path: "People/Arif.md"))
        #expect(try await w.kb.note(at: "People/Arif.md")?.userEdited == false)
        try w.put("People/Arif.md", w.raw("People/Arif.md")!.replacingOccurrences(of: "A friend.", with: "A friend from Pune."))   // Obsidian, the phone, the household
        let edited = Date(timeIntervalSince1970: 1_789_473_600)   // 2026-09-15 12:00 UTC, when that edit was made
        try FileManager.default.setAttributes([.modificationDate: edited], ofItemAtPath: w.root.appendingPathComponent("People/Arif.md").path)
        let n = try #require(try await w.kb.note(at: "People/Arif.md"))
        #expect(n.userEdited, "the body no longer hashes to what Brownie wrote")
        #expect(n.meta.updated == "2026-09-15" && n.updatedAt == edited, "the hand edit changed the substance on the day the file was written, not on the block's old day")
        #expect(w.raw("People/Arif.md")!.contains("user_edited: false") && w.raw("People/Arif.md")!.contains("updated: 2026-09-10"), "noticed on read; written back on the next code write")
        // a note whose body still hashes keeps the day its block records, whatever the file's mtime
        try w.put("People/Sam.md", Self.owned("# Sam\n\nA friend.\n", path: "People/Sam.md"))
        try FileManager.default.setAttributes([.modificationDate: edited], ofItemAtPath: w.root.appendingPathComponent("People/Sam.md").path)
        let s = try #require(try await w.kb.note(at: "People/Sam.md"))
        #expect(!s.userEdited && s.meta.updated == "2026-09-10" && s.updatedAt == NoteMeta.date("2026-09-10", Self.utc))
    }

    @Test func aNoteWithoutAHashIsNotAnEdit() async throws {
        let w = try Self.world()
        try w.put("Work/Plain.md", "# Plain\nno front-matter yet\n")
        let n = try #require(try await w.kb.note(at: "Work/Plain.md"))
        #expect(!n.userEdited && n.meta.brownie == "topic" && n.meta.created.isEmpty)
    }

    @Test func saveKeepsTheBlockMovesUpdatedOnlyWithTheSubstanceAndPersistsTheEdit() async throws {
        let w = try Self.world()
        try w.put("People/Arif.md", Self.owned("# Arif\n\nA friend.\n", path: "People/Arif.md", extra: "tags: [friend]"))
        let n = try #require(try await w.kb.note(at: "People/Arif.md"))
        // the same words back: user_edited (the app's editor) but no new day
        try await w.kb.save(Note(relativePath: n.relativePath, title: n.title, body: n.body, sources: ["whatsapp"], updatedAt: Self.today, userEdited: true))
        var raw = try #require(w.raw("People/Arif.md"))
        #expect(raw.contains("updated: 2026-09-10\n") && raw.contains("user_edited: true\n") && raw.contains("created: 2026-09-01\n") && raw.contains("sources: [whatsapp]\n"))
        #expect(raw.hasSuffix("tags: [friend]\n---\n# Arif\n\nA friend.\n"), "the user's key rides along")
        // a real change: updated moves to today
        try await w.kb.save(Note(relativePath: n.relativePath, title: n.title, body: "# Arif\n\nA friend from Pune.\n", sources: ["whatsapp"], updatedAt: Self.today, userEdited: true))
        raw = try #require(w.raw("People/Arif.md"))
        #expect(raw.contains("updated: 2026-09-16\n") && raw.contains("content_hash: \(NoteMeta.hash("# Arif\n\nA friend from Pune.\n"))"))
        #expect(try await w.kb.note(at: "People/Arif.md")?.userEdited == true)
    }

    @Test func todayIsNeverKnowledge() async throws {
        let w = try Self.world()
        try w.put("People/Arif.md", "# Arif\nplumber in Pune\n")
        try w.put(TodayNote.path, "# Today\n- [ ] **Reply to Arif** — plumber <!-- card:a -->\n")
        #expect(try await w.kb.noteCount() == 1)
        #expect(try await w.kb.folders().flatMap { $0.notes.map(\.relativePath) } == ["People/Arif.md"])
        #expect(try await w.kb.note(at: TodayNote.path) == nil)
        #expect(try await w.kb.search("plumber", limit: 5).map(\.relativePath) == ["People/Arif.md"])
        #expect(try await w.kb.search("today", limit: 5).isEmpty)
        #expect(Vault.isNote("People/Arif.md") && Vault.isNote("README.md") && !Vault.isNote("Today.md") && !Vault.isNote(".sync/People/A.md") && !Vault.isNote("People/.x.md") && !Vault.isNote("index.sqlite"))
    }

    @Test func existsIsFalseWhenOnlyTodayIsThere() async throws {
        let w = try Self.world()
        try w.put(TodayNote.path, "# Today\n")
        #expect(await w.kb.exists() == false)
    }
}
