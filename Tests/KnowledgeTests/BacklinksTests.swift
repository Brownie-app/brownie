import Testing
import Foundation
import Domain
@testable import Knowledge

/// "Mentioned in": the notes that link to this one, in any of the three link forms and any case, by whatever name a
/// click resolves — title, file name, path or alias — never itself.
@Suite struct BacklinksTests {
    @Test func theThreeFormsCaseInsensitiveSelfExcluded() async throws {
        let w = try FileKnowledgeStoreTests.world()
        try w.put("People/Meera Iyer.md", "# Meera Iyer\nDesign lead. See [[Meera Iyer]] (herself).\n")
        try w.put("People/Nayan.md", "# Nayan\nMet [[meera iyer]] in Pune.\n")
        try w.put("Work/Launch.md", "# Launch\nOwner [[Meera Iyer|Meera]]; see [[Meera Iyer#Open loops]].\n")
        try w.put("Work/Other.md", "# Other\nNothing about her; [[Nayan]] though.\n")
        let links = try await w.kb.backlinks(to: "People/Meera Iyer.md")
        #expect(links.map(\.relativePath) == ["People/Nayan.md", "Work/Launch.md"], "one entry per note, sorted; her own note not listed")
        #expect(try await w.kb.backlinks(to: "People/Nayan.md").map(\.relativePath) == ["Work/Other.md"])
        #expect(try await w.kb.backlinks(to: "People/Ravi.md").isEmpty)
        #expect(try await w.kb.backlinks(to: "").isEmpty)
    }

    @Test func aLinkCountsByWhateverNameOpensTheNote() async throws {
        let w = try FileKnowledgeStoreTests.world()
        // the heading is not the file name; the front-matter carries aliases, as the builder writes them from the registry
        try w.put("People/Priya.md", "# Priya Sharma\nPM.\n")
        try w.put("People/Meera Iyer.md", NoteMeta.fresh(path: "People/Meera Iyer.md", body: "# Meera Iyer\n", today: "2026-09-01", aliases: ["Meera", "MI"]).render() + "# Meera Iyer\nDesign lead.\n")
        try w.put("Work/A.md", "# A\nOwner [[Priya]] — the file name, as the prompts ask for.\n")
        try w.put("Work/B.md", "# B\nPing [[MI]] on Friday; [[Priya Sharma|her]] too.\n")
        try w.put("Work/C.md", "# C\nSee [[People/Meera Iyer]] and [[meera]].\n")
        try w.put("Work/D.md", "# D\n[[Ravi]] is nobody yet; [[Priya#Open]] is her.\n")
        #expect(try await w.kb.backlinks(to: "People/Priya.md").map(\.relativePath) == ["Work/A.md", "Work/B.md", "Work/D.md"], "by file name, by title, by file name with a heading")
        #expect(try await w.kb.backlinks(to: "People/Meera Iyer.md").map(\.relativePath) == ["Work/B.md", "Work/C.md"], "by alias, by path, by alias in another case")
        #expect(try await w.kb.backlinks(to: "People/Ravi.md").isEmpty, "a link to a note that is not there is nobody's mention")
    }

    @Test func theMapFollowsTheFiles() async throws {
        let w = try FileKnowledgeStoreTests.world()
        try w.put("People/Meera.md", "# Meera\n")
        try w.put("Work/A.md", "# A\n[[Meera]]\n")
        #expect(try await w.kb.backlinks(to: "People/Meera.md").map(\.relativePath) == ["Work/A.md"])
        // a new link on disk (Obsidian, the phone) shows up; a deleted note drops out
        try w.put("Work/B.md", "# B\nask [[Meera]]\n")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: w.root.appendingPathComponent("Work/B.md").path)
        #expect(try await w.kb.backlinks(to: "People/Meera.md").map(\.relativePath) == ["Work/A.md", "Work/B.md"])
        try await w.kb.delete(relativePath: "Work/A.md")
        #expect(try await w.kb.backlinks(to: "People/Meera.md").map(\.relativePath) == ["Work/B.md"])
    }
}
