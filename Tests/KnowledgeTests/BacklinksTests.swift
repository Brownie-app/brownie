import Testing
import Foundation
import Domain
@testable import Knowledge

/// "Mentioned in": the notes that link to this one, in any of the three link forms and any case, never itself.
@Suite struct BacklinksTests {
    @Test func theThreeFormsCaseInsensitiveSelfExcluded() async throws {
        let w = try FileKnowledgeStoreTests.world()
        try w.put("People/Meera Iyer.md", "# Meera Iyer\nDesign lead. See [[Meera Iyer]] (herself).\n")
        try w.put("People/Nayan.md", "# Nayan\nMet [[meera iyer]] in Pune.\n")
        try w.put("Work/Launch.md", "# Launch\nOwner [[Meera Iyer|Meera]]; see [[Meera Iyer#Open loops]].\n")
        try w.put("Work/Other.md", "# Other\nNothing about her; [[Nayan]] though.\n")
        let links = try await w.kb.backlinks(to: "Meera Iyer")
        #expect(links.map(\.relativePath) == ["People/Nayan.md", "Work/Launch.md"], "one entry per note, sorted; her own note not listed")
        #expect(try await w.kb.backlinks(to: "nayan").map(\.relativePath) == ["Work/Other.md"])
        #expect(try await w.kb.backlinks(to: "Ravi").isEmpty)
        #expect(try await w.kb.backlinks(to: "").isEmpty)
    }

    @Test func theMapFollowsTheFiles() async throws {
        let w = try FileKnowledgeStoreTests.world()
        try w.put("People/Meera.md", "# Meera\n")
        try w.put("Work/A.md", "# A\n[[Meera]]\n")
        #expect(try await w.kb.backlinks(to: "Meera").map(\.relativePath) == ["Work/A.md"])
        // a new link on disk (Obsidian, the phone) shows up; a deleted note drops out
        try w.put("Work/B.md", "# B\nask [[Meera]]\n")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: w.root.appendingPathComponent("Work/B.md").path)
        #expect(try await w.kb.backlinks(to: "Meera").map(\.relativePath) == ["Work/A.md", "Work/B.md"])
        try await w.kb.delete(relativePath: "Work/A.md")
        #expect(try await w.kb.backlinks(to: "Meera").map(\.relativePath) == ["Work/B.md"])
    }
}
