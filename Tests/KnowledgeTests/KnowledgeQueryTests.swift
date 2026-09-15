import Testing
import Foundation
@testable import Knowledge

@Suite struct KnowledgeQueryTests {
    @Test func questionWordsAreDroppedAndNamesKept() {
        #expect(KnowledgeQuery.fts("who is nayan?") == "\"nayan\"*")
        #expect(KnowledgeQuery.fts("What did I promise Meera?") == "\"meera\"*")
        #expect(KnowledgeQuery.fts("what's still open with the landlord") == "\"landlord\"*")
    }
    @Test func severalTermsAreORedLongestFirstAndPrefixed() {
        #expect(KnowledgeQuery.fts("Karan's villa in Goa") == "\"karan\"* OR \"villa\"* OR \"goa\"*")
    }
    @Test func allStopWordsFallBackToTheWordsThemselves() {
        #expect(KnowledgeQuery.fts("who is it") == "\"who\"* OR \"is\"* OR \"it\"*")
        #expect(KnowledgeQuery.fts("??") == "\"\"")
    }
    @Test func searchFindsANoteFromAQuestion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("People"), withIntermediateDirectories: true)
        try "# Nayan\nNayan's a friend from Pune; owes you a book.".write(to: root.appendingPathComponent("People/Nayan.md"), atomically: true, encoding: .utf8)
        try "# Meera\nDesign lead.".write(to: root.appendingPathComponent("People/Meera.md"), atomically: true, encoding: .utf8)
        let store = try FileKnowledgeStore(root: root, indexPath: root.appendingPathComponent("index.sqlite").path)
        #expect(try await store.search("who is nayan?", limit: 5).map(\.relativePath) == ["People/Nayan.md"])
        #expect(try await store.search("what did I promise Meera?", limit: 5).map(\.relativePath) == ["People/Meera.md"])
        #expect(try await store.search("anything about Pune", limit: 5).map(\.relativePath) == ["People/Nayan.md"])
        #expect(try await store.search("who is Ravi?", limit: 5).isEmpty)
    }
}
