import Testing
import Foundation
import Platform
@testable import Knowledge

/// What was typed becomes an FTS5 query: every term required, the last one a prefix, phrases whole, only
/// function words dropped — and a question that demands too much falls back to its content words alone.
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
    @Test func looseIsAnyOfTheContentWords() {
        #expect(KnowledgeQuery.loose("who is nayan?") == "\"nayan\"*", "the question words go, or \"who\"* would find every “whoever”")
        #expect(KnowledgeQuery.loose("what did I promise Ravi?") == "\"promise\"* OR \"ravi\"*")
        #expect(KnowledgeQuery.loose("\"open promise\" meera") == "\"open promise\" OR \"meera\"*")
        #expect(KnowledgeQuery.loose("villa in Goa") == "\"villa\"* OR \"goa\"", "a short word is asked for whole: \"goa\"* is fine but \"who\"* is not")
        #expect(KnowledgeQuery.loose("who did what?") == "\"\"", "no content word: no fallback, so no junk hits")
        #expect(KnowledgeQuery.loose("is it") == "\"\"")
        #expect(KnowledgeQuery.fts("who is nayan?") == "\"who\" AND \"nayan\"*", "the strict pass still asks for every word")
    }

    @Test func anApostropheSplitsAWordAsTheTokenizerDoes() {
        // unicode61 stores "d" and "souza" for D'Souza, so the query must ask for what is stored
        #expect(KnowledgeQuery.fts("D'Souza") == "\"souza\"*")
        #expect(KnowledgeQuery.fts("O'Sullivan") == "\"sullivan\"*")
        #expect(KnowledgeQuery.fts("Ryan D'Souza") == "\"ryan\" AND \"souza\"*")
        #expect(KnowledgeQuery.fts("Nitesh's") == "\"nitesh\"*" && KnowledgeQuery.fts("Nitesh’s book") == "\"nitesh\" AND \"book\"*", "a possessive, straight or curly, is the name")
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

    @Test func aQuestionAboutNobodyFindsNobody() async throws {
        // every note has a word that starts with "wh" or "did", which is what the old fallback matched on
        let (root, store) = try Self.vault()
        try "# Launch\nWhoever owns it decides. Didi asked about it.".write(to: root.appendingPathComponent("Work-Launch.md"), atomically: true, encoding: .utf8)
        try "# Meera\nDesign lead; the whole team is on WhatsApp.".write(to: root.appendingPathComponent("People/Meera.md"), atomically: true, encoding: .utf8)
        #expect(try await store.search("who is Ravi?", limit: 5).isEmpty, "no note about Ravi: no notes, not the ones that say “whoever”")
        #expect(try await store.search("anything about Ravi?", limit: 5).isEmpty)
        #expect(try await store.search("what did I promise Ravi?", limit: 5).map(\.relativePath) == ["People/Nayan.md"], "“promise” is a content word: the one note that speaks of a promise, not the ones that say WhatsApp or Didi")
        #expect(try await store.search("who is nayan?", limit: 5).map(\.relativePath) == ["People/Nayan.md"], "the person named is still found")
        #expect(try await store.search("what did Meera promise?", limit: 5).map(\.relativePath).contains("People/Meera.md"))
    }

    @Test func namesWithAnApostropheAreFoundAndNotMistakenForAnother() async throws {
        let (root, store) = try Self.vault()
        try "# Ryan D'Souza\nRuns the Goa villa.".write(to: root.appendingPathComponent("People/Ryan D'Souza.md"), atomically: true, encoding: .utf8)
        try "# Ryan Shah\nCousin in Pune.".write(to: root.appendingPathComponent("People/Ryan Shah.md"), atomically: true, encoding: .utf8)
        try "# Pat O'Sullivan\nLandlord.".write(to: root.appendingPathComponent("People/Pat O'Sullivan.md"), atomically: true, encoding: .utf8)
        try "# Nitesh\nNitesh's book is due.".write(to: root.appendingPathComponent("People/Nitesh.md"), atomically: true, encoding: .utf8)
        #expect(try await store.find("D'Souza").hits.map(\.note.relativePath) == ["People/Ryan D'Souza.md"])
        #expect(try await store.find("O'Sullivan").hits.map(\.note.relativePath) == ["People/Pat O'Sullivan.md"])
        #expect(try await store.find("Nitesh's").hits.map(\.note.relativePath) == ["People/Nitesh.md"])
        #expect(try await store.search("Ryan D'Souza", limit: 2).map(\.relativePath) == ["People/Ryan D'Souza.md"], "the strict pass finds him, so the nudge is never drafted from Ryan Shah's note")
        #expect(try await store.search("Pat O'Sullivan", limit: 2).map(\.relativePath) == ["People/Pat O'Sullivan.md"])
    }

    @Test func typingAWordNeverLosesTheNoteOnTheWay() async throws {
        let (root, store) = try Self.vault()
        try "# Wedding\nThe wedding, a meeting, the hospital.".write(to: root.appendingPathComponent("Work-Wedding.md"), atomically: true, encoding: .utf8)
        for word in ["wedding", "meeting", "hospital"] {
            for n in 2...word.count {
                let typed = String(word.prefix(n))
                #expect(try await store.find(typed).hits.map(\.note.relativePath).contains("Work-Wedding.md"), Comment(rawValue: typed))
            }
        }
        #expect(try await store.find("meet").total == 1)
        #expect(try await store.find("meeting").total == 1)
    }

    @Test func snippetsShowTheNoteAsItIsDrawn() async throws {
        let (root, store) = try Self.vault()
        let block = "<!-- brownie:status -->\n## Between you\n_Kept by Brownie from the chats and the loops ledger. Not written by the brain._\n- ⏳ 3 Sep — they asked: “lunch?” — no reply yet\n<!-- /brownie:status -->"
        try ("# Arif\n\n" + block + "\n\n## Recently\n- **Promised** the [[Meera|deck]] by Friday <!-- private -->\n").write(to: root.appendingPathComponent("People/Arif.md"), atomically: true, encoding: .utf8)
        let (m, u) = (FileKnowledgeStore.SearchHit.mark, FileKnowledgeStore.SearchHit.unmark)
        let deck = try await store.find("deck")
        #expect(deck.hits.map(\.note.relativePath) == ["People/Arif.md"])
        let snip = deck.hits[0].snippet
        #expect(snip.contains(m + "deck" + u) && !snip.contains("<!--") && !snip.contains("# ") && !snip.contains("**") && !snip.contains("[["), Comment(rawValue: snip))
        let lunch = try await store.find("lunch")
        #expect(lunch.total == 1 && lunch.hits[0].snippet.contains(m + "lunch" + u) && !lunch.hits[0].snippet.contains("<!--"), "the card's line is drawn, so it is found and shown as the card shows it")
        for hidden in ["brownie", "ledger", "between", "private"] { #expect(try await store.find(hidden).total == 0, Comment(rawValue: hidden)) }
    }

    @Test func anIndexFileOfTheOldShapeIsRebuilt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("People"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("People/Arif.md")
        try "# Arif\nA friend from Pune.".write(to: file, atomically: true, encoding: .utf8)
        // the index a previous version left behind: a raw-body column under a stemming tokenizer, this file already in it
        let indexPath = root.appendingPathComponent("index.sqlite").path
        let old = try SQLite(path: indexPath)
        try old.exec("CREATE VIRTUAL TABLE note_fts USING fts5(path UNINDEXED, title, body, tokenize='porter unicode61'); CREATE TABLE note_meta(path TEXT PRIMARY KEY, mtime REAL NOT NULL)")
        let mtime = ((try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970
        try old.run("INSERT INTO note_fts(path, title, body) VALUES(?,?,?)", [.text("People/Arif.md"), .text("Arif"), .text("# Arif\nA friend from Pune.")])
        try old.run("INSERT INTO note_meta(path, mtime) VALUES(?,?)", [.text("People/Arif.md"), .real(mtime)])
        let store = try FileKnowledgeStore(root: root, indexPath: indexPath)
        let r = try await store.find("friend")
        #expect(r.total == 1 && !r.hits[0].snippet.contains("# "), "found through the rebuilt index, and the snippet comes from the new column")
        #expect(try SQLite(path: indexPath).query("PRAGMA user_version").first?["user_version"].int == FileKnowledgeStore.schemaVersion)
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
