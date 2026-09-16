import Testing
import Foundation
import Domain
import Platform
@testable import Knowledge

/// The registry on a throwaway vault: seeded from People notes, learning from chats, merging, and the
/// one rule the note picker lives by — a first name alone claims a note only through the registry.
@Suite struct PersonRegistryTests {
    static let t0 = Date(timeIntervalSince1970: 1_789_560_000)
    struct Vault {
        let root: URL
        let kb: FileKnowledgeStore
        func put(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        func registry(at seconds: Double = 0) -> PersonRegistry { PersonRegistry(vault: root, now: { PersonRegistryTests.t0.addingTimeInterval(seconds) }) }
    }
    static func vault() throws -> Vault {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("people-\(UUID().uuidString)", isDirectory: true)
        let root = dir.appendingPathComponent("KB", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Vault(root: root, kb: try FileKnowledgeStore(root: root, indexPath: dir.appendingPathComponent("index.sqlite").path))
    }
    static func note(_ rel: String, _ title: String) -> Note { Note(relativePath: rel, title: title, body: "# \(title)\n", sources: [], updatedAt: t0, userEdited: false) }
    static func folders(_ people: [(String, String)]) -> [KnowledgeFolder] { [KnowledgeFolder(name: "People", notes: people.map { note($0.0, $0.1) })] }

    @Test func seedMakesOnePersonPerPeopleNoteOnce() async throws {
        let v = try Self.vault(); let r = v.registry()
        let f = Self.folders([("People/Kanika Pandey.md", "Kanika Pandey"), ("People/Kanika Pandey Loadmill.md", "Kanika Pandey Loadmill"), ("People/Nitesh.md", "Nitesh")])
        await r.seed(from: f); await r.seed(from: f)
        let people = await r.people()
        #expect(people.count == 3, "seeding twice adds nothing")
        #expect(people.map(\.notePath).compactMap { $0 }.sorted() == ["People/Kanika Pandey Loadmill.md", "People/Kanika Pandey.md", "People/Nitesh.md"])
        #expect(people.first { $0.notePath == "People/Nitesh.md" }?.name == "Nitesh")
        let pairs = await r.suspects()
        #expect(pairs.count == 1 && Set([pairs[0].0.name, pairs[0].1.name]) == ["Kanika Pandey", "Kanika Pandey Loadmill"], "two notes with the same key are the pair the banner shows")
    }

    @Test func seedGivesANoteToAPersonKnownFromChatsAndReleasesAVanishedOne() async throws {
        let v = try Self.vault(); let r = v.registry()
        let id = await r.register(label: "Arjun Mehta", handle: "whatsapp:+911")
        await r.seed(from: Self.folders([("People/Arjun.md", "Arjun")]))
        #expect(await r.notePath(for: id) == "People/Arjun.md", "the only Arjun on file gets the note titled by his first name")
        #expect(await r.people().count == 1)
        await r.seed(from: Self.folders([]))
        #expect(await r.notePath(for: id) == nil, "the note is gone, so the path is released")
        await r.seed(from: Self.folders([("People/Arjun Mehta.md", "Arjun Mehta")]))
        #expect(await r.notePath(for: id) == "People/Arjun Mehta.md")
    }

    @Test func resolveByHandleThenAliasThenAUniqueFirstName() async throws {
        let v = try Self.vault(); let r = v.registry()
        let kanika = await r.register(label: "Kanika Pandey Loadmill", handle: "whatsapp:+919")
        let arjun = await r.register(label: "Arjun Mehta", handle: nil)
        #expect(await r.resolve(label: "Renamed Chat", handle: "whatsapp:+919") == kanika, "the handle wins over any spelling")
        #expect(await r.resolve(label: "Kanika Pandey", handle: nil) == kanika, "same key")
        #expect(await r.resolve(label: "kanika pandey loadmill", handle: nil) == kanika)
        #expect(await r.resolve(label: "Arjun", handle: nil) == arjun, "one Arjun on file — a first name is enough")
        #expect(await r.resolve(label: "Kanika Sharma", handle: nil) == nil, "another surname is nobody we know")
        _ = await r.register(label: "Arjun Kapoor", handle: nil)
        #expect(await r.resolve(label: "Arjun", handle: nil) == nil, "two Arjuns — nobody")
        #expect(await r.resolve(label: "Arjun Mehta", handle: nil) == arjun)
        #expect(await r.resolve(label: "+91 98765", handle: nil) == nil, "a bare number has no key")
    }

    @Test func registerLearnsAliasesHandlesAndAFullerName() async throws {
        let v = try Self.vault(); let r = v.registry()
        let id = await r.register(label: "Nitesh (+919540752593)", handle: "whatsapp:+919540752593")
        #expect(await r.register(label: "Nitesh", handle: nil) == id)
        #expect(await r.register(label: "Nitesh Kumar", handle: "whatsapp:+919540752593") == id, "the handle says who this fuller name is")
        #expect(await r.register(label: "Nitesh", handle: "imessage:+919540752593") == id, "a second handle is learned")
        let p = try #require(await r.person(id))
        #expect(p.name == "Nitesh Kumar", "the fuller spelling becomes the name")
        #expect(p.aliases.contains("Nitesh (+919540752593)") && p.aliases.contains("Nitesh"))
        #expect(p.handles == ["whatsapp:+919540752593", "imessage:+919540752593"])
        #expect(await r.register(label: "Anything", handle: "imessage:+919540752593") == id, "the second handle is now theirs too")
        #expect(await r.people().count == 1)
        #expect(await r.register(label: "Nitesh Sharma", handle: nil) != id, "a fuller name with no handle is not assumed to be the Nitesh on file")
        #expect(await r.people().count == 2)
    }

    @Test func mergeUnitesTwoRecordsAndKeepSeparateSilencesThePair() async throws {
        let v = try Self.vault(); let r = v.registry()
        await r.seed(from: Self.folders([("People/Kanika Pandey.md", "Kanika Pandey"), ("People/Kanika Pandey Loadmill.md", "Kanika Pandey Loadmill")]))
        let people = await r.people()
        let keep = try #require(people.first { $0.notePath == "People/Kanika Pandey.md" }), drop = try #require(people.first { $0.notePath == "People/Kanika Pandey Loadmill.md" })
        _ = await r.register(label: "Kanika", handle: "slack:U1")   // a lone first name beside two Kanikas: a third person
        let third = try #require(await r.resolve(label: "Kanika", handle: nil))
        #expect(await r.people().count == 3)
        await r.keepSeparate(keep.id, third)
        _ = await r.register(label: "Kanika Pandey Loadmill", handle: "whatsapp:+919")
        let merged = try #require(await r.merge(keep: keep.id, drop: drop.id))
        #expect(merged.id == keep.id && merged.notePath == "People/Kanika Pandey.md")
        #expect(merged.aliases.contains("Kanika Pandey Loadmill") && merged.handles == ["whatsapp:+919"])
        let gone = await r.person(drop.id), left = await r.people().count
        #expect(gone == nil && left == 2)
        #expect(await r.resolve(label: "Kanika Pandey Loadmill", handle: nil) == keep.id, "the dropped spelling now names the kept person")
        #expect(await r.suspects().isEmpty, "the lone Kanika was kept separate; the merged pair is gone")
        let noNote = await r.register(label: "Someone New", handle: nil)
        _ = await r.merge(keep: noNote, drop: keep.id)
        #expect(await r.notePath(for: noNote) == "People/Kanika Pandey.md", "a kept person with no note takes the dropped one's")
        #expect(await r.merge(keep: "nobody", drop: noNote) == nil, "unknown ids merge nothing")
    }

    @Test func suspectsPairSameKeysAndLoneFirstNamesUnlessToldOtherwise() async throws {
        let v = try Self.vault(); let r = v.registry()
        let a = await r.register(label: "Arjun", handle: nil)
        let b = await r.register(label: "Arjun Mehta", handle: "whatsapp:+1")
        #expect(a != b, "a fuller name is never assumed to be the lone first name on file — the banner asks")
        let one = await r.suspects()
        #expect(one.count == 1 && one[0].0.id == b && one[0].1.id == a, "the fuller name is the one to keep")
        // Two full names sharing a first word are not suspects; a lone first name beside two full names is.
        let v2 = try Self.vault(); let r2 = v2.registry()
        await r2.seed(from: Self.folders([("People/Arjun Mehta.md", "Arjun Mehta"), ("People/Arjun Kapoor.md", "Arjun Kapoor")]))
        #expect(await r2.suspects().isEmpty)
        await r2.seed(from: Self.folders([("People/Arjun Mehta.md", "Arjun Mehta"), ("People/Arjun Kapoor.md", "Arjun Kapoor"), ("People/Arjun.md", "Arjun")]))
        let pairs = await r2.suspects()
        #expect(pairs.count == 2 && pairs.allSatisfy { $0.1.name == "Arjun" }, "the fuller name is the one to keep, so it comes first")
        let lone = try #require(await r2.people().first { $0.name == "Arjun" })
        for p in pairs { await r2.keepSeparate(p.0.id, lone.id) }
        #expect(await r2.suspects().isEmpty)
        #expect(await r2.person(lone.id)?.notSame.count == 2)
    }

    @Test func jsonRoundTripsAndTheHiddenFileIsNoNote() async throws {
        let v = try Self.vault()
        try v.put("People/Nitesh.md", "# Nitesh\n\nRecurring.\n")
        let r = v.registry(at: 5)
        await r.seed(from: try await v.kb.folders())
        let id = await r.register(label: "Nitesh (+919540752593)", handle: "whatsapp:+919540752593")
        let other = await r.register(label: "Nitesh Sharma", handle: nil)
        await r.keepSeparate(id, "p-unknown")
        await r.keepSeparate(id, other)
        try await r.save()
        #expect(FileManager.default.fileExists(atPath: v.root.appendingPathComponent(".brownie/people.json").path))
        let again = v.registry(at: 99); await again.load()
        let before = await r.people().sorted { $0.id < $1.id }, after = await again.people().sorted { $0.id < $1.id }
        #expect(before == after && after.count == 2, "every field survives the file")
        let nitesh = try #require(after.first { $0.id == id })
        #expect(nitesh.firstSeen == Self.t0.addingTimeInterval(5) && nitesh.handles == ["whatsapp:+919540752593"] && nitesh.notSame == [other], "an unknown id is never kept separate; a known one is")
        #expect(try await v.kb.noteCount() == 1, "the registry's file is not a note")
        #expect(try await v.kb.folders().flatMap(\.notes).map(\.relativePath) == ["People/Nitesh.md"])
        #expect(try await v.kb.fingerprint() == (try await v.kb.fingerprint()))
        let e = try Self.vault().registry(); await e.load()
        #expect(await e.people().isEmpty, "no file is an empty registry")
    }

    @Test func aNoteIsPickedByTheRegistryElseByExactKeyNeverByFirstNameAlone() async throws {
        let v = try Self.vault(); let r = v.registry()
        let notes = [Self.note("People/Arjun Mehta.md", "Arjun Mehta"), Self.note("People/Kanika Pandey.md", "Kanika Pandey"), Self.note("People/Nitesh.md", "Nitesh")]
        // an empty registry: only an exact key finds a note
        #expect(await r.notePath(forLabel: "Kanika Pandey Loadmill", handle: nil, amongNotes: notes) == "People/Kanika Pandey.md")
        #expect(await r.notePath(forLabel: "Nitesh (+919540752593)", handle: nil, amongNotes: notes) == "People/Nitesh.md")
        #expect(await r.notePath(forLabel: "Arjun", handle: nil, amongNotes: notes) == nil, "a first name never claims a fuller title by itself")
        #expect(await r.notePath(forLabel: "Kanika Sharma", handle: nil, amongNotes: notes) == nil)
        // the registry knows one Arjun: now "Arjun" has a note
        await r.seed(from: [KnowledgeFolder(name: "People", notes: notes)])
        #expect(await r.notePath(forLabel: "Arjun", handle: nil, amongNotes: notes) == "People/Arjun Mehta.md")
        _ = await r.register(label: "Arjun Kapoor", handle: nil)
        #expect(await r.notePath(forLabel: "Arjun", handle: nil, amongNotes: notes) == nil, "two Arjuns: the block goes nowhere rather than to the wrong note")
        // a handle finds the note whatever the chat is called now
        _ = await r.register(label: "Kanika Pandey", handle: "whatsapp:+919")
        #expect(await r.notePath(forLabel: "K. Pandey (work)", handle: "whatsapp:+919", amongNotes: notes) == "People/Kanika Pandey.md")
    }

    @Test func headerLinesNameTheFileAndTheOtherSpellingsAndStopAtTheCap() async throws {
        let v = try Self.vault(); let r = v.registry()
        await r.seed(from: Self.folders([("People/Kanika Pandey.md", "Kanika Pandey")]))
        _ = await r.register(label: "Kanika Pandey Loadmill", handle: nil)
        _ = await r.register(label: "Kanika Pandey", handle: nil)
        _ = await r.register(label: "Zed", handle: nil)
        let lines = PersonRegistry.headerLines(await r.people())
        #expect(lines == ["Kanika Pandey — People/Kanika Pandey.md (also: Kanika Pandey Loadmill)", "Zed — no note yet"], "people with notes first; the name itself is not an alias")
        // 250 distinct names (digits are not letters, so they must differ in their letters)
        for i in 0..<250 { _ = await r.register(label: "Name\(UnicodeScalar(65 + i % 26)!)\(UnicodeScalar(65 + i / 26)!) Surname", handle: nil) }
        #expect(await r.people().count == 252)
        #expect(PersonRegistry.headerLines(await r.people()).count == 200)
        #expect(PersonRegistry.headerLines([]).isEmpty)
    }

    @Test func mergedNoteTextAndLinkRewrites() {
        let kept = "# Kanika Pandey\n\nWorks at Loadmill.\n"
        let dropped = "# Kanika Pandey Loadmill\n\nAsked about pricing on 2026-09-01.\n"
        let out = PersonNotes.appendMerged(into: kept, droppedBody: dropped, droppedName: "Kanika Pandey Loadmill", date: Self.t0)
        #expect(out == "# Kanika Pandey\n\nWorks at Loadmill.\n\n## Merged from Kanika Pandey Loadmill (16 Sep 2026)\nAsked about pricing on 2026-09-01.\n")
        #expect(PersonNotes.appendMerged(into: kept, droppedBody: "# Empty\n", droppedName: "Empty", date: Self.t0).hasSuffix("(16 Sep 2026)\n_Nothing else was written there._\n"))
        #expect(PersonNotes.rewriteLinks(in: "See [[Kanika Pandey Loadmill]] and [[Kanika Pandey Loadmill|her]].", from: "Kanika Pandey Loadmill", to: "Kanika Pandey") == "See [[Kanika Pandey]] and [[Kanika Pandey|her]].")
        #expect(PersonNotes.rewriteLinks(in: "See [[Kanika Pandey]].", from: "Kanika Pandey Loadmill", to: "Kanika Pandey") == nil, "nothing to change")
        #expect(PersonNotes.rewriteLinks(in: "x", from: "A", to: "A") == nil)
    }
}
