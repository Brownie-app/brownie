import Testing
import Foundation
@testable import Knowledge

/// What was typed becomes an FTS5 query: every term required, the last one a prefix, phrases whole, only
/// function words dropped — and a question that demands too much falls back to any of its words.
@Suite struct KnowledgeQueryTests {
    @Test func functionWordsGoAndTheLastTermIsAPrefix() {
        #expect(KnowledgeQuery.fts("who is nayan?") == "\"who\" AND \"nayan\"*")
        #expect(KnowledgeQuery.fts("the landlord") == "\"landlord\"*")
        #expect(KnowledgeQuery.fts("Karan's villa in Goa") == "\"karan\" AND \"villa\" AND \"goa\"*")
    }
    @Test func everydayWordsAreSearchable() {
        for w in ["open", "promise", "ask", "last", "what", "who", "still"] { #expect(KnowledgeQuery.fts(w) == "\"\(w)\"*", Comment(rawValue: w)) }
    }
    @Test func aQuotedPhrasePassesThroughWhole() {
        #expect(KnowledgeQuery.fts("\"open promise\" meera") == "\"open promise\" AND \"meera\"*")
        #expect(KnowledgeQuery.fts("“not before Diwali”") == "\"not before diwali\"")
        #expect(KnowledgeQuery.fts("\"unclosed quote") == "\"unclosed\" AND \"quote\"*", "an unclosed quote is just words")
    }
    @Test func onlyStopWordsFallBackToTheWordsThemselvesAndNothingIsEmpty() {
        #expect(KnowledgeQuery.fts("is it") == "\"is\" AND \"it\"*")
        #expect(KnowledgeQuery.fts("??") == "\"\"")
        #expect(KnowledgeQuery.fts("a") == "\"\"")
    }
    @Test func repeatedWordsCountOnce() {
        #expect(KnowledgeQuery.fts("goa goa villa") == "\"goa\" AND \"villa\"*")
    }
    @Test func looseIsAnyOfTheTerms() {
        #expect(KnowledgeQuery.loose("who is nayan?") == "\"who\"* OR \"nayan\"*")
        #expect(KnowledgeQuery.loose("\"open promise\" meera") == "\"open promise\" OR \"meera\"*")
    }

    static func vault() throws -> (URL, FileKnowledgeStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("People"), withIntermediateDirectories: true)
        try "# Nayan\nNayan's a friend from Pune; owes you a book. Open promise: the book.".write(to: root.appendingPathComponent("People/Nayan.md"), atomically: true, encoding: .utf8)
        try "# Meera\nDesign lead. Promised a book review.".write(to: root.appendingPathComponent("People/Meera.md"), atomically: true, encoding: .utf8)
        return (root, try FileKnowledgeStore(root: root, indexPath: root.appendingPathComponent("index.sqlite").path))
    }

    @Test func searchFindsANoteFromAQuestion() async throws {
        let (_, store) = try Self.vault()
        #expect(try await store.search("who is nayan?", limit: 5).map(\.relativePath) == ["People/Nayan.md"], "no note says “who”, so the terms are OR-ed")
        #expect(try await store.search("what did I promise Meera?", limit: 5).map(\.relativePath).first == "People/Meera.md", "the note with more of the words ranks first")
        #expect(try await store.search("anything about Pune", limit: 5).map(\.relativePath) == ["People/Nayan.md"])
        #expect(try await store.search("who is Ravi?", limit: 5).isEmpty)
        #expect(try await store.search("book", limit: 5).count == 2)
    }

    @Test func findIsStrictWithSnippetsAndACount() async throws {
        let (root, store) = try Self.vault()
        let r = try await store.find("open promise")
        #expect(r.total == 1 && r.hits.map(\.note.relativePath) == ["People/Nayan.md"], "both words must be there")
        #expect(r.hits[0].snippet.contains(FileKnowledgeStore.SearchHit.mark + "Open" + FileKnowledgeStore.SearchHit.unmark), "the match is marked in the snippet")
        #expect(try await store.find("book").total == 2)
        #expect(try await store.find("pu").hits.map(\.note.relativePath) == ["People/Nayan.md"], "the word being typed matches as a prefix")
        #expect(try await store.find("\"book review\"").total == 1, "a phrase: the words together, so Nayan's book does not count")
        #expect(try await store.find("\"review book\"").total == 0)
        #expect(try await store.find("").total == 0)
        #expect(try await store.find("?").hits.isEmpty)
        // the limit cuts the list but not the count
        for i in 0..<5 { try "# Book \(i)\nbook".write(to: root.appendingPathComponent("People/B\(i).md"), atomically: true, encoding: .utf8) }
        let capped = try await store.find("book", limit: 3)
        #expect(capped.hits.count == 3 && capped.total == 7)
    }
}
