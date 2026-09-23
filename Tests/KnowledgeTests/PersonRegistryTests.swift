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
        let f = Self.folders([("People/Lalita Pathak.md", "Lalita Pathak"), ("People/Lalita Pathak Tideline.md", "Lalita Pathak Tideline"), ("People/Lokesh.md", "Lokesh")])
        await r.seed(from: f); await r.seed(from: f)
        let people = await r.people()
        #expect(people.count == 3, "seeding twice adds nothing")
        #expect(people.map(\.notePath).compactMap { $0 }.sorted() == ["People/Lalita Pathak Tideline.md", "People/Lalita Pathak.md", "People/Lokesh.md"])
        #expect(people.first { $0.notePath == "People/Lokesh.md" }?.name == "Lokesh")
        let pairs = await r.suspects()
        #expect(pairs.count == 1 && Set([pairs[0].0.name, pairs[0].1.name]) == ["Lalita Pathak", "Lalita Pathak Tideline"], "two notes with the same key are the pair the banner shows")
    }

    @Test func seedGivesANoteToAPersonKnownFromChatsAndReleasesAVanishedOne() async throws {
        let v = try Self.vault(); let r = v.registry()
        let id = await r.register(label: "Kiran Bose", handle: "whatsapp:+911")
        await r.seed(from: Self.folders([("People/Kiran.md", "Kiran")]))
        #expect(await r.notePath(for: id) == "People/Kiran.md", "the only Kiran on file gets the note titled by his first name")
        #expect(await r.people().count == 1)
        await r.seed(from: Self.folders([]))
        #expect(await r.notePath(for: id) == nil, "the note is gone, so the path is released")
        await r.seed(from: Self.folders([("People/Kiran Bose.md", "Kiran Bose")]))
        #expect(await r.notePath(for: id) == "People/Kiran Bose.md")
    }

    @Test func resolveByHandleThenAliasThenAUniqueFirstName() async throws {
        let v = try Self.vault(); let r = v.registry()
        let lalita = await r.register(label: "Lalita Pathak Tideline", handle: "whatsapp:+919")
        let kiran = await r.register(label: "Kiran Bose", handle: nil)
        #expect(await r.resolve(label: "Renamed Chat", handle: "whatsapp:+919") == lalita, "the handle wins over any spelling")
        #expect(await r.resolve(label: "Lalita Pathak", handle: nil) == lalita, "same key")
        #expect(await r.resolve(label: "lalita pathak tideline", handle: nil) == lalita)
        #expect(await r.resolve(label: "Kiran", handle: nil) == kiran, "one Kiran on file — a first name is enough")
        #expect(await r.resolve(label: "Lalita Dalal", handle: nil) == nil, "another surname is nobody we know")
        _ = await r.register(label: "Kiran Dutta", handle: nil)
        #expect(await r.resolve(label: "Kiran", handle: nil) == nil, "two Kirans — nobody")
        #expect(await r.resolve(label: "Kiran Bose", handle: nil) == kiran)
        #expect(await r.resolve(label: "+91 98765", handle: nil) == nil, "a bare number has no key")
    }

    @Test func registerLearnsAliasesHandlesAndAFullerName() async throws {
        let v = try Self.vault(); let r = v.registry()
        let id = await r.register(label: "Lokesh (+919000000111)", handle: "whatsapp:+919000000111")
        #expect(await r.register(label: "Lokesh", handle: nil) == id)
        #expect(await r.register(label: "Lokesh Kadri", handle: "whatsapp:+919000000111") == id, "the handle says who this fuller name is")
        #expect(await r.register(label: "Lokesh", handle: "imessage:+919000000111") == id, "a second handle is learned")
        let p = try #require(await r.person(id))
        #expect(p.name == "Lokesh Kadri", "the fuller spelling becomes the name")
        #expect(p.aliases.contains("Lokesh (+919000000111)") && p.aliases.contains("Lokesh"))
        #expect(p.handles == ["whatsapp:+919000000111", "imessage:+919000000111"])
        #expect(await r.register(label: "Anything", handle: "imessage:+919000000111") == id, "the second handle is now theirs too")
        #expect(await r.people().count == 1)
        #expect(await r.register(label: "Lokesh Dalal", handle: nil) != id, "a fuller name with no handle is not assumed to be the Lokesh on file")
        #expect(await r.people().count == 2)
    }

    @Test func mergeUnitesTwoRecordsAndKeepSeparateSilencesThePair() async throws {
        let v = try Self.vault(); let r = v.registry()
        await r.seed(from: Self.folders([("People/Lalita Pathak.md", "Lalita Pathak"), ("People/Lalita Pathak Tideline.md", "Lalita Pathak Tideline")]))
        let people = await r.people()
        let keep = try #require(people.first { $0.notePath == "People/Lalita Pathak.md" }), drop = try #require(people.first { $0.notePath == "People/Lalita Pathak Tideline.md" })
        _ = await r.register(label: "Lalita", handle: "slack:U1")   // a lone first name beside two Lalitas: a third person
        let third = try #require(await r.resolve(label: "Lalita", handle: nil))
        #expect(await r.people().count == 3)
        await r.keepSeparate(keep.id, third)
        _ = await r.register(label: "Lalita Pathak Tideline", handle: "whatsapp:+919")
        let merged = try #require(await r.merge(keep: keep.id, drop: drop.id))
        #expect(merged.id == keep.id && merged.notePath == "People/Lalita Pathak.md")
        #expect(merged.aliases.contains("Lalita Pathak Tideline") && merged.handles == ["whatsapp:+919"])
        let gone = await r.person(drop.id), left = await r.people().count
        #expect(gone == nil && left == 2)
        #expect(await r.resolve(label: "Lalita Pathak Tideline", handle: nil) == keep.id, "the dropped spelling now names the kept person")
        #expect(await r.suspects().isEmpty, "the lone Lalita was kept separate; the merged pair is gone")
        let noNote = await r.register(label: "Someone New", handle: nil)
        _ = await r.merge(keep: noNote, drop: keep.id)
        #expect(await r.notePath(for: noNote) == "People/Lalita Pathak.md", "a kept person with no note takes the dropped one's")
        #expect(await r.merge(keep: "nobody", drop: noNote) == nil, "unknown ids merge nothing")
    }

    @Test func suspectsPairSameKeysAndLoneFirstNamesUnlessToldOtherwise() async throws {
        let v = try Self.vault(); let r = v.registry()
        let a = await r.register(label: "Kiran", handle: nil)
        let b = await r.register(label: "Kiran Bose", handle: "whatsapp:+1")
        #expect(a != b, "a fuller name is never assumed to be the lone first name on file — the banner asks")
        let one = await r.suspects()
        #expect(one.count == 1 && one[0].0.id == b && one[0].1.id == a, "the fuller name is the one to keep")
        // Two full names sharing a first word are not suspects; a lone first name beside two full names is.
        let v2 = try Self.vault(); let r2 = v2.registry()
        await r2.seed(from: Self.folders([("People/Kiran Bose.md", "Kiran Bose"), ("People/Kiran Dutta.md", "Kiran Dutta")]))
        #expect(await r2.suspects().isEmpty)
        await r2.seed(from: Self.folders([("People/Kiran Bose.md", "Kiran Bose"), ("People/Kiran Dutta.md", "Kiran Dutta"), ("People/Kiran.md", "Kiran")]))
        let pairs = await r2.suspects()
        #expect(pairs.count == 2 && pairs.allSatisfy { $0.1.name == "Kiran" }, "the fuller name is the one to keep, so it comes first")
        let lone = try #require(await r2.people().first { $0.name == "Kiran" })
        for p in pairs { await r2.keepSeparate(p.0.id, lone.id) }
        #expect(await r2.suspects().isEmpty)
        #expect(await r2.person(lone.id)?.notSame.count == 2)
    }

    @Test func jsonRoundTripsAndTheHiddenFileIsNoNote() async throws {
        let v = try Self.vault()
        try v.put("People/Lokesh.md", "# Lokesh\n\nRecurring.\n")
        let r = v.registry(at: 5)
        await r.seed(from: try await v.kb.folders())
        let id = await r.register(label: "Lokesh (+919000000111)", handle: "whatsapp:+919000000111")
        let other = await r.register(label: "Lokesh Dalal", handle: nil)
        await r.keepSeparate(id, "p-unknown")
        await r.keepSeparate(id, other)
        try await r.save()
        #expect(FileManager.default.fileExists(atPath: v.root.appendingPathComponent(".brownie/people.json").path))
        let again = v.registry(at: 99); await again.load()
        let before = await r.people().sorted { $0.id < $1.id }, after = await again.people().sorted { $0.id < $1.id }
        #expect(before == after && after.count == 2, "every field survives the file")
        let lokesh = try #require(after.first { $0.id == id })
        #expect(lokesh.firstSeen == Self.t0.addingTimeInterval(5) && lokesh.handles == ["whatsapp:+919000000111"] && lokesh.notSame == [other], "an unknown id is never kept separate; a known one is")
        #expect(try await v.kb.noteCount() == 1, "the registry's file is not a note")
        #expect(try await v.kb.folders().flatMap(\.notes).map(\.relativePath) == ["People/Lokesh.md"])
        #expect(try await v.kb.fingerprint() == (try await v.kb.fingerprint()))
        let e = try Self.vault().registry(); await e.load()
        #expect(await e.people().isEmpty, "no file is an empty registry")
    }

    @Test func aNoteIsPickedByTheRegistryElseByExactKeyNeverByFirstNameAlone() async throws {
        let v = try Self.vault(); let r = v.registry()
        let notes = [Self.note("People/Kiran Bose.md", "Kiran Bose"), Self.note("People/Lalita Pathak.md", "Lalita Pathak"), Self.note("People/Lokesh.md", "Lokesh")]
        // an empty registry: only an exact key finds a note
        #expect(await r.notePath(forLabel: "Lalita Pathak Tideline", handle: nil, amongNotes: notes) == "People/Lalita Pathak.md")
        #expect(await r.notePath(forLabel: "Lokesh (+919000000111)", handle: nil, amongNotes: notes) == "People/Lokesh.md")
        #expect(await r.notePath(forLabel: "Kiran", handle: nil, amongNotes: notes) == nil, "a first name never claims a fuller title by itself")
        #expect(await r.notePath(forLabel: "Lalita Dalal", handle: nil, amongNotes: notes) == nil)
        // the registry knows one Kiran: now "Kiran" has a note
        await r.seed(from: [KnowledgeFolder(name: "People", notes: notes)])
        #expect(await r.notePath(forLabel: "Kiran", handle: nil, amongNotes: notes) == "People/Kiran Bose.md")
        _ = await r.register(label: "Kiran Dutta", handle: nil)
        #expect(await r.notePath(forLabel: "Kiran", handle: nil, amongNotes: notes) == nil, "two Kirans: the block goes nowhere rather than to the wrong note")
        // a handle finds the note whatever the chat is called now
        _ = await r.register(label: "Lalita Pathak", handle: "whatsapp:+919")
        #expect(await r.notePath(forLabel: "K. Pathak (work)", handle: "whatsapp:+919", amongNotes: notes) == "People/Lalita Pathak.md")
    }

    @Test func headerLinesNameTheFileAndTheOtherSpellingsAndStopAtTheCap() async throws {
        let v = try Self.vault(); let r = v.registry()
        await r.seed(from: Self.folders([("People/Lalita Pathak.md", "Lalita Pathak")]))
        _ = await r.register(label: "Lalita Pathak Tideline", handle: nil)
        _ = await r.register(label: "Lalita Pathak", handle: nil)
        _ = await r.register(label: "Zed", handle: nil)
        let lines = PersonRegistry.headerLines(await r.people())
        #expect(lines == ["Lalita Pathak — People/Lalita Pathak.md (also: Lalita Pathak Tideline)", "Zed — no note yet"], "people with notes first; the name itself is not an alias")
        // 250 distinct names (digits are not letters, so they must differ in their letters)
        for i in 0..<250 { _ = await r.register(label: "Name\(UnicodeScalar(65 + i % 26)!)\(UnicodeScalar(65 + i / 26)!) Surname", handle: nil) }
        #expect(await r.people().count == 252)
        #expect(PersonRegistry.headerLines(await r.people()).count == 200)
        #expect(PersonRegistry.headerLines([]).isEmpty)
    }

    // MARK: two people sharing a key

    @Test func resolvePrefersTheExactSpellingAndNeverGuessesBetweenTwoWhoShareAKey() async throws {
        let v = try Self.vault(); let r = v.registry()
        // "Lalita Pathak Tideline.md" sorts before "Lalita Pathak.md", so the Tideline record is on file first
        let notes = [Self.note("People/Lalita Pathak Tideline.md", "Lalita Pathak Tideline"), Self.note("People/Lalita Pathak.md", "Lalita Pathak"),
                     Self.note("People/Kiran Bose.md", "Kiran Bose"), Self.note("People/Kiran Bose (Landlord).md", "Kiran Bose (Landlord)")]
        await r.seed(from: [KnowledgeFolder(name: "People", notes: notes)])
        let people = await r.people()
        let plain = try #require(people.first { $0.notePath == "People/Lalita Pathak.md" }), tideline = try #require(people.first { $0.notePath == "People/Lalita Pathak Tideline.md" })
        let landlord = try #require(people.first { $0.notePath == "People/Kiran Bose (Landlord).md" }), kiran = try #require(people.first { $0.notePath == "People/Kiran Bose.md" })
        #expect(await r.resolve(label: "Lalita Pathak", handle: nil) == plain.id, "the chat named exactly like the note is that note's person, not the first record on file")
        #expect(await r.resolve(label: "lalita pathak ", handle: nil) == plain.id, "case and surrounding space aside")
        #expect(await r.resolve(label: "Lalita Pathak Tideline", handle: nil) == tideline.id)
        #expect(await r.resolve(label: "Kiran Bose (Landlord)", handle: nil) == landlord.id, "the parenthesised suffix the key strips still tells the two apart")
        #expect(await r.resolve(label: "Kiran Bose", handle: nil) == kiran.id)
        #expect(await r.resolve(label: "Lalita Pathak (work)", handle: nil) == nil, "a spelling that is neither of them is nobody — never the first on file")
        // a label that spells neither is not learned onto either, and no third person is opened for it
        let picked = await r.register(label: "Lalita Pathak (work)", handle: "whatsapp:+919")
        let count = await r.people().count
        #expect([plain.id, tideline.id].contains(picked) && count == 4)
        #expect(await r.people().allSatisfy { $0.handles.isEmpty && !$0.aliases.contains("Lalita Pathak (work)") }, "no handle and no alias attached by a guess")
        #expect(await r.resolve(label: "Renamed Chat", handle: "whatsapp:+919") == nil)
        // the exact spelling takes the handle, and the handle then decides whatever the chat is called
        #expect(await r.register(label: "Lalita Pathak", handle: "whatsapp:+919") == plain.id)
        let plainHandles = await r.person(plain.id)?.handles, tidelineHandles = await r.person(tideline.id)?.handles
        #expect(plainHandles == ["whatsapp:+919"] && tidelineHandles == [])
        #expect(await r.resolve(label: "Renamed Chat", handle: "whatsapp:+919") == plain.id)
        // kept separate, the pair still resolves the same way, and the block for each label lands on its own note
        await r.keepSeparate(plain.id, tideline.id)
        #expect(await r.notePath(forLabel: "Lalita Pathak", handle: nil, amongNotes: notes) == "People/Lalita Pathak.md")
        #expect(await r.notePath(forLabel: "Lalita Pathak Tideline", handle: nil, amongNotes: notes) == "People/Lalita Pathak Tideline.md")
        #expect(await r.notePath(forLabel: "Lalita Pathak (work)", handle: nil, amongNotes: notes) == nil, "nowhere rather than the wrong note")
        // the title fallback of an empty registry follows the same rule
        let e = try Self.vault().registry()
        #expect(await e.notePath(forLabel: "Lalita Pathak", handle: nil, amongNotes: notes) == "People/Lalita Pathak.md")
        #expect(await e.notePath(forLabel: "Lalita Pathak (work)", handle: nil, amongNotes: notes) == nil)
        // a person known from chats takes the note spelled like them, not the same-key note that sorts first
        let c = try Self.vault().registry()
        let known = await c.register(label: "Lalita Pathak", handle: "whatsapp:+1")
        await c.seed(from: [KnowledgeFolder(name: "People", notes: Array(notes.prefix(2)))])
        let knownPath = await c.notePath(for: known), knownCount = await c.people().count
        #expect(knownPath == "People/Lalita Pathak.md" && knownCount == 2)
    }

    @Test func aKnownPersonWithoutANoteNeverGetsANamesakesNote() async throws {
        // two Lalitas from two notes, kept separate; the plain one's note is then deleted (or renamed) in Obsidian
        let v = try Self.vault(); let r = v.registry()
        let plainNote = Self.note("People/Lalita Pathak.md", "Lalita Pathak"), tidelineNote = Self.note("People/Lalita Pathak Tideline.md", "Lalita Pathak Tideline")
        await r.seed(from: [KnowledgeFolder(name: "People", notes: [plainNote, tidelineNote])])
        let plain = try #require(await r.people().first { $0.notePath == "People/Lalita Pathak.md" }), tideline = try #require(await r.people().first { $0.notePath == "People/Lalita Pathak Tideline.md" })
        await r.keepSeparate(plain.id, tideline.id)
        #expect(await r.register(label: "Lalita Pathak", handle: "whatsapp:+1") == plain.id)
        await r.seed(from: [KnowledgeFolder(name: "People", notes: [tidelineNote])])
        let plainPath = await r.notePath(for: plain.id), tidelinePath = await r.notePath(for: tideline.id)
        #expect(plainPath == nil && tidelinePath == "People/Lalita Pathak Tideline.md", "the vanished note is released; the other stays hers")
        #expect(await r.resolve(label: "Lalita Pathak", handle: "whatsapp:+1") == plain.id)
        #expect(await r.notePath(forLabel: "Lalita Pathak", handle: "whatsapp:+1", amongNotes: [tidelineNote]) == nil, "her asks and loops go to no note rather than into the note of the person the user keeps apart")
        #expect(await r.notePath(forLabel: "Lalita Pathak", handle: nil, amongNotes: [tidelineNote]) == nil)
        #expect(await r.notePath(forLabel: "Lalita Pathak (work)", handle: nil, amongNotes: [tidelineNote]) == nil, "a label that is neither of two who share a key is nobody's, however many of their notes remain")
        #expect(await r.notePath(forLabel: "Lalita Pathak Tideline", handle: nil, amongNotes: [tidelineNote]) == "People/Lalita Pathak Tideline.md")
        #expect(await r.notePath(forLabel: "Lokesh", handle: nil, amongNotes: [tidelineNote, Self.note("People/Lokesh.md", "Lokesh")]) == "People/Lokesh.md", "a label the registry knows nothing of still finds its own title")
    }

    @Test func seedReleasesDeadPathsWhenThePeopleFolderHoldsNoNoteAtAll() async throws {
        // the store lists folders from the notes it read, so a People folder emptied by the user is not listed at all
        let v = try Self.vault(); let r = v.registry()
        try v.put("People/Lalita Pathak.md", "# Lalita Pathak\n")
        await r.seed(from: try await v.kb.folders())
        let id = try #require(await r.people().first?.id)
        #expect(await r.notePath(for: id) == "People/Lalita Pathak.md")
        try FileManager.default.removeItem(at: v.root.appendingPathComponent("People/Lalita Pathak.md"))
        let listed = try await v.kb.folders()
        #expect(!listed.contains { $0.name == "People" })
        await r.seed(from: listed)
        #expect(await r.notePath(for: id) == nil, "the folder is there and empty: the path is dead, and released")
        // seeded again after the brain writes her under another spelling, she gets that note instead of a second person
        try v.put("People/Lalita Pathak Tideline.md", "# Lalita Pathak Tideline\n")
        await r.seed(from: try await v.kb.folders())
        let claimed = await r.notePath(for: id), count = await r.people().count
        #expect(claimed == "People/Lalita Pathak Tideline.md" && count == 1)
        // the People directory gone altogether releases too; a directory with a note the store could not read does not
        try FileManager.default.removeItem(at: v.root.appendingPathComponent("People"))
        await r.seed(from: try await v.kb.folders())
        #expect(await r.notePath(for: id) == nil)
        try v.put("People/Lalita Pathak Tideline.md", "# Lalita Pathak Tideline\n")
        await r.seed(from: try await v.kb.folders())
        try Data([0x23, 0x20, 0x4A, 0xF6, 0x72, 0x67, 0x0A]).write(to: v.root.appendingPathComponent("People/Jorg.md"))
        await r.seed(from: (try? await v.kb.folders()) ?? [])
        #expect(await r.notePath(for: id) == "People/Lalita Pathak Tideline.md", "a failed listing strips nothing")
    }

    @Test func aMergeRenamesOnlyTheRowsThatWereTheDroppedPersons() async throws {
        // K "Lalita" from Slack with a note, D "Lalita Pathak" whose note was deleted, T "Lalita Pathak Tideline" the user keeps apart from D
        let v = try Self.vault(); let r = v.registry()
        let all = Self.folders([("People/Lalita.md", "Lalita"), ("People/Lalita Pathak.md", "Lalita Pathak"), ("People/Lalita Pathak Tideline.md", "Lalita Pathak Tideline")])
        await r.seed(from: all)
        let d = try #require(await r.people().first { $0.notePath == "People/Lalita Pathak.md" }), t = try #require(await r.people().first { $0.notePath == "People/Lalita Pathak Tideline.md" })
        await r.keepSeparate(d.id, t.id)
        await r.seed(from: Self.folders([("People/Lalita.md", "Lalita"), ("People/Lalita Pathak Tideline.md", "Lalita Pathak Tideline")]))
        let before = await r.people()
        #expect(PersonRegistry.belonged(label: "Lalita Pathak", handle: nil, to: d.id, among: before), "the dropped person's own spelling")
        #expect(!PersonRegistry.belonged(label: "Lalita Pathak Tideline", handle: nil, to: d.id, among: before), "the same key, but the kept-apart person's rows: left alone")
        #expect(!PersonRegistry.belonged(label: "Lalita", handle: nil, to: d.id, among: before), "the kept person's own rows")
        #expect(!PersonRegistry.belonged(label: "Lalita Pathak (work)", handle: nil, to: d.id, among: before), "a spelling that is neither resolves to nobody")
        _ = await r.register(label: "Lalita Pathak", handle: "whatsapp:+2")
        #expect(PersonRegistry.belonged(label: "K. Pathak", handle: "whatsapp:+2", to: d.id, among: await r.people()), "a handle finds the dropped person whatever the chat is called")
    }

    @Test func seedLeavesEveryNotePathAloneWhenNoPeopleFolderWasListed() async throws {
        let v = try Self.vault(); let r = v.registry()
        try v.put("People/Lokesh.md", "# Lokesh\n\nRecurring.\n")
        try v.put("People/Kiran Bose.md", "# Kiran Bose\n")
        await r.seed(from: try await v.kb.folders())
        let paths = await r.people().compactMap(\.notePath).sorted()
        #expect(paths == ["People/Kiran Bose.md", "People/Lokesh.md"])
        // one file the store cannot read (Latin-1 bytes) fails the whole listing, which the run turns into an empty one
        try Data([0x23, 0x20, 0x4A, 0xF6, 0x72, 0x67, 0x0A]).write(to: v.root.appendingPathComponent("People/Jorg.md"))
        let listed = try? await v.kb.folders()
        #expect(listed == nil, "the listing fails on the unreadable note")
        await r.seed(from: listed ?? [])
        #expect(await r.people().compactMap(\.notePath).sorted() == paths, "nothing was listed, so nothing is released")
        #expect(PersonRegistry.headerLines(await r.people()).allSatisfy { !$0.contains("no note yet") })
        // a listed People folder with a note gone does release that one
        await r.seed(from: Self.folders([("People/Lokesh.md", "Lokesh")]))
        #expect(await r.people().compactMap(\.notePath) == ["People/Lokesh.md"])
    }

    @Test func saveKeepsAMergeAndAKeepSeparateMadeWhileTheRunHeldItsCopy() async throws {
        let v = try Self.vault()
        let first = v.registry()
        await first.seed(from: Self.folders([("People/Lalita Pathak.md", "Lalita Pathak"), ("People/Lalita Pathak Tideline.md", "Lalita Pathak Tideline")]))
        let a = await first.register(label: "Kiran", handle: nil), b = await first.register(label: "Kiran Bose", handle: "whatsapp:+1")
        try await first.save()
        let keep = try #require(await first.people().first { $0.notePath == "People/Lalita Pathak.md" }?.id), drop = try #require(await first.people().first { $0.notePath == "People/Lalita Pathak Tideline.md" }?.id)
        // the night run loads its copy and works for an hour; meanwhile the app merges the Lalitas, keeps the Kirans apart, deletes the dropped note
        let run = v.registry(at: 3600); await run.load()
        let app = v.registry(at: 10); await app.load()
        await app.merge(keep: keep, drop: drop); await app.keepSeparate(a, b); try await app.save()
        // the run learned a handle for the dropped spelling, a fuller name for Kiran, someone new, and saw the notes as they are now
        await run.seed(from: Self.folders([("People/Lalita Pathak.md", "Lalita Pathak"), ("People/Zed Zulu.md", "Zed Zulu")]))
        _ = await run.register(label: "Lalita Pathak Tideline", handle: "whatsapp:+919")
        _ = await run.register(label: "Lalita Pathak", handle: "slack:U9")
        _ = await run.register(label: "Kiran", handle: "telegram:7")
        try await run.save()
        let again = v.registry(at: 99); await again.load()
        let people = await again.people()
        #expect(people.count == 4 && people.first { $0.id == drop } == nil, "the merge the app made stands")
        let kept = try #require(people.first { $0.id == keep })
        #expect(kept.aliases.contains("Lalita Pathak Tideline") && kept.handles.sorted() == ["slack:U9", "whatsapp:+919"] && kept.notePath == "People/Lalita Pathak.md", "what the run learned about either Lalita is on the kept one")
        #expect(people.first { $0.id == a }?.notSame == [b] && people.first { $0.id == b }?.notSame == [a], "keep separate stands")
        #expect(people.first { $0.id == a }?.handles == ["telegram:7"] && people.first { $0.notePath == "People/Zed Zulu.md" } != nil)
        #expect(await again.suspects().isEmpty, "the banner has nothing left to ask")
        #expect(await run.people().sorted { $0.id < $1.id } == people.sorted { $0.id < $1.id }, "the run's own view is the reconciled one, so its status blocks route the same way")
        // the other order: the run saved first and the app, holding an older copy, merges afterwards — the run's learning survives
        let v2 = try Self.vault(); let seed = v2.registry()
        await seed.seed(from: Self.folders([("People/Lalita Pathak.md", "Lalita Pathak"), ("People/Lalita Pathak Tideline.md", "Lalita Pathak Tideline")])); try await seed.save()
        let k2 = try #require(await seed.people().first { $0.notePath == "People/Lalita Pathak.md" }?.id), d2 = try #require(await seed.people().first { $0.notePath == "People/Lalita Pathak Tideline.md" }?.id)
        let app2 = v2.registry(at: 5); await app2.load()
        let run2 = v2.registry(at: 6); await run2.load()
        _ = await run2.register(label: "Lalita Pathak Tideline", handle: "whatsapp:+919"); _ = await run2.register(label: "New Person", handle: nil); try await run2.save()
        await app2.merge(keep: k2, drop: d2); try await app2.save()
        let final = v2.registry(at: 99); await final.load()
        let finalCount = await final.people().count, gone2 = await final.person(d2), keptHandles = await final.person(k2)?.handles, newcomer = await final.resolve(label: "New Person", handle: nil)
        #expect(finalCount == 2 && gone2 == nil)
        #expect(keptHandles == ["whatsapp:+919"] && newcomer != nil)
        // nothing changed on disk: a plain write
        let lone = v2.registry(at: 100); await lone.load(); _ = await lone.register(label: "Third", handle: nil); try await lone.save()
        let check = v2.registry(); await check.load()
        #expect(await check.people().count == 3)
    }

    @Test func mergedNoteDropsTheStatusBlockSoOnlyTheKeptOneIsMaintained() {
        let blocks = [(open: "<!-- brownie:status -->", close: "<!-- /brownie:status -->"), (open: "<!-- brownie:between-you -->", close: "<!-- /brownie:between-you -->")]
        let kept = "# Lalita Pathak\n<!-- brownie:status -->\n## Between you\n- ⏳ 1 Sep — they asked: “x?” — no reply yet\n<!-- /brownie:status -->\n\nWorks at Tideline.\n"
        let dropped = "# Lalita Pathak Tideline\n<!-- brownie:status -->\n## Between you\n- ⏳ 3 Sep — they asked: “pricing?” — no reply yet\n<!-- /brownie:status -->\n\nAsked about pricing.\n"
        let out = PersonNotes.appendMerged(into: kept, droppedBody: dropped, droppedName: "Lalita Pathak Tideline", date: Self.t0, stripping: blocks)
        #expect(out == kept.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n## Merged from Lalita Pathak Tideline (16 Sep 2026)\nAsked about pricing.\n")
        #expect(out.components(separatedBy: "<!-- brownie:status -->").count == 2, "one block in the note: the kept note's own")
        let legacy = "# Old\n\n<!-- brownie:between-you -->\n- ⏳ old\n<!-- /brownie:between-you -->\n\nStill here.\n<!-- brownie:status -->\nno closer\n"
        let out2 = PersonNotes.appendMerged(into: "# New\n", droppedBody: legacy, droppedName: "Old", date: Self.t0, stripping: blocks)
        #expect(out2 == "# New\n\n## Merged from Old (16 Sep 2026)\nStill here.\n<!-- brownie:status -->\nno closer\n", "the old markers go too; an opener with no closer is left as text")
        #expect(PersonNotes.appendMerged(into: "# New\n", droppedBody: dropped, droppedName: "K", date: Self.t0).contains("<!-- brownie:status -->"), "nothing is stripped unless asked")
    }

    @Test func renamedLoopsAndAsksKeepEveryOtherField() throws {
        var loop = Loop(id: "L1", direction: .theirs, person: "Kiran", what: "send the estimates", quote: "will send", sourceLabel: "WhatsApp · Fri", due: "Friday", dueDate: Self.t0, status: .lapsed,
                        openedAt: Self.t0.addingTimeInterval(-91 * 86400), closedAt: Self.t0, closedHow: "let go", closedBy: "lapsed", lapsedAt: Self.t0, firedCardIDs: ["c1"], cameBackCount: 2)
        loop.nudgedForDue = true; loop.owner = "either"
        let ask = Ask(id: "A1", person: "Kiran", bucket: BucketID("whatsapp:1"), askedAt: Self.t0.addingTimeInterval(-60 * 86400), question: "estimates?", answeredAt: Self.t0.addingTimeInterval(-59 * 86400),
                      reply: "lol", addressed: false, handle: "whatsapp:+1", lapsedAt: Self.t0.addingTimeInterval(-20 * 86400))
        let l = loop.renamed(to: "Kiran Bose"), a = ask.renamed(to: "Kiran Bose")
        #expect(l.person == "Kiran Bose" && a.person == "Kiran Bose")
        #expect(l.lapsedAt == Self.t0 && l.closedBy == "lapsed" && l.status == .lapsed, "a let-go loop stays let go, by the same hand, on the same day")
        #expect(a.lapsedAt == ask.lapsedAt && !a.isOpen, "a let-go ask does not come back as open")
        // every field but the name survives, whatever fields the records grow
        func fields<T: Encodable>(_ x: T) throws -> NSDictionary {
            var d = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(x)) as? [String: Any]); d["person"] = nil; return d as NSDictionary
        }
        let (fl, floop, fa, fask) = (try fields(l), try fields(loop), try fields(a), try fields(ask))
        #expect(fl == floop && fa == fask)
    }

    @Test func mergedNoteTextAndLinkRewrites() {
        let kept = "# Lalita Pathak\n\nWorks at Tideline.\n"
        let dropped = "# Lalita Pathak Tideline\n\nAsked about pricing on 2026-09-01.\n"
        let out = PersonNotes.appendMerged(into: kept, droppedBody: dropped, droppedName: "Lalita Pathak Tideline", date: Self.t0)
        #expect(out == "# Lalita Pathak\n\nWorks at Tideline.\n\n## Merged from Lalita Pathak Tideline (16 Sep 2026)\nAsked about pricing on 2026-09-01.\n")
        #expect(PersonNotes.appendMerged(into: kept, droppedBody: "# Empty\n", droppedName: "Empty", date: Self.t0).hasSuffix("(16 Sep 2026)\n_Nothing else was written there._\n"))
        #expect(PersonNotes.rewriteLinks(in: "See [[Lalita Pathak Tideline]] and [[Lalita Pathak Tideline|her]].", from: "Lalita Pathak Tideline", to: "Lalita Pathak") == "See [[Lalita Pathak]] and [[Lalita Pathak|her]].")
        #expect(PersonNotes.rewriteLinks(in: "See [[Lalita Pathak]].", from: "Lalita Pathak Tideline", to: "Lalita Pathak") == nil, "nothing to change")
        #expect(PersonNotes.rewriteLinks(in: "x", from: "A", to: "A") == nil)
    }

    /// The user is never a person: a note titled after them seeds nobody, a loop or ask under their name registers nobody.
    @Test func theUsersOwnNameOpensNoRecord() async throws {
        let v = try Self.vault()
        let r = PersonRegistry(vault: v.root, now: { Self.t0 }, selfNames: ["Ishan Shirke", "ishan", " ", ""])
        #expect(r.selfNames == ["Ishan Shirke", "ishan"], "blank names are dropped")
        await r.seed(from: Self.folders([("People/Ishan Shirke — Career Materials (Jul–Aug 2026).md", "Ishan Shirke — Career Materials (Jul–Aug 2026)"), ("People/Ishan.md", "Ishan"), ("People/Lalita Pathak.md", "Lalita Pathak")]))
        #expect(await r.people().map(\.name) == ["Lalita Pathak"], "only Lalita seeds")
        let a = await r.register(label: "Ishan Shirke", handle: nil), b = await r.register(label: "ishan", handle: "whatsapp:+91")
        #expect(a == "" && b == "", "the empty id names nobody")
        let learned = await r.people()
        #expect(learned.count == 1 && learned[0].handles.isEmpty, "nothing was learned")
        #expect(await r.register(label: "Ishan Sharma", handle: nil) != "", "another Ishan with his own surname is somebody else")
        #expect(await r.register(label: "Ishan", handle: nil) == "", "the bare first name is still the user")
        let kiran = await r.register(label: "Kiran Bose", handle: nil)
        await r.remove(kiran)
        #expect(Set(await r.people().map(\.name)) == ["Lalita Pathak", "Ishan Sharma"])
        try await r.save()
        let again = v.registry(); await again.load()
        #expect(Set(await again.people().map(\.name)) == ["Lalita Pathak", "Ishan Sharma"], "a removed record stays removed on disk")
    }

    // MARK: proof joins, a name alone asks

    /// A clock the tests move by hand, so the second record is seen later than the first.
    final class Ticker: @unchecked Sendable {
        var t = PersonRegistryTests.t0
        func registry(_ v: Vault) -> PersonRegistry { PersonRegistry(vault: v.root, now: { self.t }) }
        func tick(_ s: Double = 60) { t = t.addingTimeInterval(s) }
    }

    @Test func aNameOnASecondChatOpensAPendingRecordAndAProofJoins() async throws {
        let v = try Self.vault(); let c = Ticker(); let r = c.registry(v)
        let wa = await r.register(label: "Lokesh Kadri", handle: "whatsapp:+919000000111")
        await r.setNotePath("People/Lokesh Kadri.md", for: wa)
        c.tick()
        // the same name on Slack: not joined — a new record, and the two are pending toward each other
        let sl = await r.register(label: "Lokesh Kadri", handle: "slack:U1")
        #expect(sl != wa && sl != "")
        let (w, s) = (try #require(await r.person(wa)), try #require(await r.person(sl)))
        #expect(w.pending == [sl] && s.pending == [wa], "each may be the other, awaiting the user's word")
        #expect(w.handles == ["whatsapp:+919000000111"] && s.handles == ["slack:U1"], "the Slack handle did not join the WhatsApp record")
        #expect(w.sources == ["WhatsApp"] && s.sources == ["Slack"])
        #expect(w.allProofs == ["phone:919000000111"] && w.proofs == ["phone:919000000111"], "a WhatsApp handle proves a phone, and the record keeps it")
        #expect(await r.register(label: "Lokesh K", handle: "slack:U1") == sl, "the handle, once on file, is that record")
        #expect(await r.people().count == 2)
        // proof joins: an iMessage chat with the same number is the WhatsApp Lokesh; a Teams profile with the Slack email is the Slack one
        #expect(await r.register(label: "Lokesh", handle: "imessage:+919000000111") == wa)
        _ = await r.register(label: "Lokesh Kadri", handle: "slack:U1", proofs: ["email:lokesh@harbour.test"])
        #expect(await r.register(label: "N. Kadri", handle: "teams:T9", proofs: ["email:lokesh@harbour.test"]) == sl)
        let s2 = try #require(await r.person(sl))
        #expect(s2.handles == ["slack:U1", "teams:T9"] && s2.proofs == ["email:lokesh@harbour.test"] && s2.aliases.contains("N. Kadri"))
        #expect(await r.people().count == 2, "no third record for a proven chat")
        // a name alone, without a handle, resolves as before: the pending pair are both candidates and the one with the note answers
        #expect(await r.register(label: "Lokesh Kadri", handle: nil) == wa)
        #expect(await r.resolve(label: "lokesh kadri", handle: nil) == wa)
        #expect(await r.resolve(label: "Lokesh Kadri", handle: "slack:U1") == sl, "the handle always says")
        // a lone first name on a second chat asks too
        let am = await r.register(label: "Kiran Bose", handle: "whatsapp:+1"); c.tick()
        let ar = await r.register(label: "Kiran", handle: "telegram:7")
        let (kiran, mehra) = (try #require(await r.person(ar)), try #require(await r.person(am)))
        #expect(ar != am && kiran.pending == [am] && mehra.pending == [ar])
        // someone never seen on a chat — from a note, or from loops by name — takes the first handle that names them: there is no second chat to confuse
        let zed = await r.register(label: "Zed Zulu", handle: nil)
        #expect(await r.register(label: "Zed Zulu", handle: "whatsapp:+2") == zed)
        let z = try #require(await r.person(zed))
        #expect(z.pending == [] && z.handles == ["whatsapp:+2"])
        // the user's own name still opens nothing
        let me = PersonRegistry(vault: v.root, now: { Self.t0 }, selfNames: ["Ishan Shirke"])
        #expect(await me.register(label: "Ishan Shirke", handle: "slack:U2", proofs: ["email:v@x.in"]) == "")
    }

    @Test func aPendingPairResolvesByTheNoteAndNeverGuessesWithoutOne() async throws {
        let v = try Self.vault(); let c = Ticker(); let r = c.registry(v)
        let wa = await r.register(label: "Lokesh Kadri", handle: "whatsapp:+1"); c.tick()
        let sl = await r.register(label: "Lokesh Kadri", handle: "slack:U1")
        #expect(await r.resolve(label: "Lokesh Kadri", handle: nil) == nil, "spelled the same by both, neither with a note: nobody")
        #expect(await r.register(label: "Lokesh Kadri", handle: nil) == wa, "a loop under the bare name is not a third person; the likelier is returned and nothing is attached")
        #expect(await r.people().count == 2)
        await r.setNotePath("People/Lokesh Kadri.md", for: wa)
        #expect(await r.resolve(label: "Lokesh Kadri", handle: nil) == wa, "the one with the note")
        await r.setNotePath("People/Lokesh Kadri (Slack).md", for: sl)
        #expect(await r.resolve(label: "Lokesh Kadri", handle: nil) == nil, "both have a note: nobody, never the first on file")
        #expect(await r.resolve(label: "Lokesh Kadri (Slack)", handle: nil) == sl, "the title spelled exactly is his")
        // a same-key pair that is not pending is told apart by spelling only: a note is no tie-break there
        await r.seed(from: Self.folders([("People/Lalita Pathak.md", "Lalita Pathak"), ("People/Lalita Pathak Tideline.md", "Lalita Pathak Tideline")]))
        let plain = try #require(await r.people().first { $0.notePath == "People/Lalita Pathak.md" }?.id)
        await r.setNotePath(nil, for: plain)
        #expect(await r.resolve(label: "Lalita Pathak (work)", handle: nil) == nil, "spells neither: nobody, whoever has a note")
        #expect(await r.resolve(label: "Lalita Pathak", handle: nil) == plain)
    }

    @Test func aPendingPairNeverRoutesAnAskAcross() async throws {
        let v = try Self.vault(); let c = Ticker(); let r = c.registry(v)
        let wa = await r.register(label: "Lokesh Kadri", handle: "whatsapp:+1"); c.tick()
        let sl = await r.register(label: "Lokesh Kadri", handle: "slack:U1")
        let notes = [Self.note("People/Lokesh Kadri.md", "Lokesh Kadri")]
        await r.seed(from: [KnowledgeFolder(name: "People", notes: notes)])
        let (waPath, slPath) = (await r.notePath(for: wa), await r.notePath(for: sl))
        #expect(waPath == "People/Lokesh Kadri.md" && slPath == nil, "the note goes to the one on file first")
        #expect(await r.notePath(forLabel: "Lokesh Kadri", handle: "whatsapp:+1", amongNotes: notes) == "People/Lokesh Kadri.md")
        #expect(await r.notePath(forLabel: "Lokesh Kadri", handle: "slack:U1", amongNotes: notes) == nil, "the Slack ask goes to no note rather than into the WhatsApp Lokesh's")
        #expect(await r.notePath(forLabel: "Lokesh Kadri", handle: nil, amongNotes: notes) == "People/Lokesh Kadri.md", "a loop under the bare name goes to the one with the note")
        let both = notes + [Self.note("People/Lokesh Kadri (Slack).md", "Lokesh Kadri (Slack)")]
        await r.seed(from: [KnowledgeFolder(name: "People", notes: both)])
        #expect(await r.notePath(for: sl) == "People/Lokesh Kadri (Slack).md", "the file he was told to be written in is his")
        #expect(await r.notePath(forLabel: "Lokesh Kadri", handle: "slack:U1", amongNotes: both) == "People/Lokesh Kadri (Slack).md")
        #expect(await r.notePath(forLabel: "Lokesh Kadri", handle: nil, amongNotes: both) == nil, "both have a note now: the bare name goes to neither")
        #expect(await r.people().count == 2, "no third record for either note")
    }

    @Test func suggestedFilesTellAPendingPairApartAndTheSeedFollowsThem() async throws {
        let v = try Self.vault(); let c = Ticker(); let r = c.registry(v)
        let wa = await r.register(label: "Lokesh Kadri", handle: "whatsapp:+1"); c.tick()
        let sl = await r.register(label: "Lokesh Kadri", handle: "slack:U1")
        let people = await r.people()
        let (w, s) = (try #require(people.first { $0.id == wa }), try #require(people.first { $0.id == sl }))
        #expect(PersonRegistry.suggestedNotePath(for: w, among: people) == "People/Lokesh Kadri.md", "the one on file first keeps the plain name")
        #expect(PersonRegistry.suggestedNotePath(for: s, among: people) == "People/Lokesh Kadri (Slack).md", "the newcomer is told apart by the chat")
        #expect(PersonRegistry.resolveTitle("Lokesh Kadri (Slack)", among: people) == sl && PersonRegistry.resolveTitle("Lokesh Kadri", among: people) == wa)
        // the header lists both, the newcomer with his file and the line that keeps the brain from folding them
        let lines = PersonRegistry.headerLines(people)
        #expect(lines.count == 2)
        #expect(lines.contains { $0.hasPrefix("Lokesh Kadri — no note yet; write them in People/Lokesh Kadri (Slack).md") && $0.contains("(seen on Slack)") && $0.contains("may be the Lokesh Kadri of People/Lokesh Kadri.md") && $0.hasSuffix(PersonRegistry.unsureLine) }, "\(lines)")
        #expect(lines.contains { $0.hasPrefix("Lokesh Kadri — no note yet; write them in People/Lokesh Kadri.md") && $0.contains("(seen on WhatsApp)") && $0.hasSuffix(PersonRegistry.unsureLine) }, "\(lines)")
        #expect(PersonRegistry.unsureLine == "Brownie is not sure these are one person; write each in their own file until the user says")
        // the seed claims each file for its record: the plain title for the first, the suffixed one for the newcomer
        await r.seed(from: Self.folders([("People/Lokesh Kadri (Slack).md", "Lokesh Kadri (Slack)"), ("People/Lokesh Kadri.md", "Lokesh Kadri")]))
        let (waPath, slPath, count) = (await r.notePath(for: wa), await r.notePath(for: sl), await r.people().count)
        #expect(waPath == "People/Lokesh Kadri.md" && slPath == "People/Lokesh Kadri (Slack).md" && count == 2)
        // a front-matter id says whose a note is above any title
        let v2 = try Self.vault(); let r2 = c.registry(v2)
        let a = await r2.register(label: "Lokesh Kadri", handle: "whatsapp:+1"); c.tick(); let b = await r2.register(label: "Lokesh Kadri", handle: "slack:U1")
        let plain = Self.note("People/Lokesh Kadri.md", "Lokesh Kadri")
        let stamped = Note(relativePath: plain.relativePath, title: plain.title, body: plain.body, meta: NoteMeta.fresh(path: plain.relativePath, body: plain.body, today: "2026-09-16", id: b), updatedAt: Self.t0)
        await r2.seed(from: [KnowledgeFolder(name: "People", notes: [stamped])])
        let (aPath, bPath) = (await r2.notePath(for: a), await r2.notePath(for: b))
        #expect(bPath == "People/Lokesh Kadri.md" && aPath == nil, "the id in the front-matter says whose the note is")
        let people2 = await r2.people()
        #expect(PersonRegistry.suggestedNotePath(for: people2.first { $0.id == a }!, among: people2) == "People/Lokesh Kadri (WhatsApp).md", "the plain title is taken, so the first is told apart by his chat")
        // once the user says they are two, the newcomer still has a file of his own, and the header says nothing unsure
        let v3 = try Self.vault(); let r3 = c.registry(v3)
        let x = await r3.register(label: "Lokesh Kadri", handle: "whatsapp:+1"); c.tick(); let y = await r3.register(label: "Lokesh Kadri", handle: "slack:U1")
        await r3.keepSeparate(x, y)
        let apart = await r3.people()
        #expect(PersonRegistry.suggestedNotePath(for: apart.first { $0.id == y }!, among: apart) == "People/Lokesh Kadri (Slack).md")
        #expect(PersonRegistry.resolveTitle("Lokesh Kadri (Slack)", among: apart) == y && PersonRegistry.resolveTitle("Lokesh Kadri", among: apart) == x)
        let apartLines = PersonRegistry.headerLines(apart)
        #expect(apartLines == ["Lokesh Kadri — no note yet", "Lokesh Kadri — no note yet; write them in People/Lokesh Kadri (Slack).md"], "\(apartLines)")
    }

    @Test func suspectsAskPendingPairsFirstAndAnAnswerClearsThem() async throws {
        let v = try Self.vault(); let c = Ticker(); let r = c.registry(v)
        _ = await r.register(label: "Kiran", handle: nil)
        _ = await r.register(label: "Kiran Bose", handle: "whatsapp:+1")   // a look-alike pair
        let wa = await r.register(label: "Lokesh Kadri", handle: "whatsapp:+2"); c.tick()
        let sl = await r.register(label: "Lokesh Kadri", handle: "slack:U1")
        let pairs = await r.suspects()
        #expect(pairs.count == 2 && Set([pairs[0].0.id, pairs[0].1.id]) == [wa, sl] && pairs[1].1.name == "Kiran", "the question Brownie raised comes first, the look-alike after")
        #expect(PeopleQuestion.isPending(pairs[0]) && !PeopleQuestion.isPending(pairs[1]))
        #expect(PeopleQuestion.title(pairs[0]) == "Is Lokesh Kadri on Slack the same Lokesh Kadri as on WhatsApp?", "\(PeopleQuestion.title(pairs[0]))")
        #expect(PeopleQuestion.yes(pairs[0]) == "Same person" && PeopleQuestion.no(pairs[0]) == "Different people")
        #expect(PeopleQuestion.title(pairs[1]) == "These two look like one person: Kiran Bose · Kiran" && PeopleQuestion.yes(pairs[1]) == "Merge" && PeopleQuestion.no(pairs[1]) == "Keep separate")
        #expect(PeopleQuestion.consequence(pairs[0]) == "Same person keeps Lokesh Kadri")
        // Different people: pending gone both ways, notSame set both ways, and the pair is never asked again
        await r.keepSeparate(wa, sl)
        let (w, s) = (try #require(await r.person(wa)), try #require(await r.person(sl)))
        #expect(w.pending.isEmpty && s.pending.isEmpty && w.notSame == [sl] && s.notSame == [wa])
        #expect(await r.suspects().count == 1)
        // Same person: the merge keeps the one with the note and clears the question
        let v2 = try Self.vault(); let r2 = c.registry(v2)
        let a = await r2.register(label: "Lokesh Kadri", handle: "whatsapp:+2"); c.tick()
        let b = await r2.register(label: "Lokesh Kadri", handle: "slack:U1", proofs: ["email:n@x.in"])
        await r2.setNotePath("People/Lokesh Kadri.md", for: a)
        let pair = try #require(await r2.suspects().first)
        #expect(pair.0.id == a && pair.1.id == b, "the one with the note is kept")
        #expect(PeopleQuestion.consequence(pair) == "Same person keeps Lokesh Kadri and their note People/Lokesh Kadri.md")
        let merged = try #require(await r2.merge(keep: a, drop: b))
        #expect(merged.pending.isEmpty && merged.handles == ["whatsapp:+2", "slack:U1"] && merged.proofs == ["email:n@x.in"], "the kept one takes the handle and the proofs")
        let (left, count) = (await r2.suspects().count, await r2.people().count)
        #expect(left == 0 && count == 1)
        // two chats on the same app under one name: the question says so
        let v3 = try Self.vault(); let r3 = c.registry(v3)
        _ = await r3.register(label: "Lokesh Kadri", handle: "whatsapp:+5"); c.tick(); _ = await r3.register(label: "Lokesh Kadri", handle: "whatsapp:+6")
        #expect(PeopleQuestion.title(try #require(await r3.suspects().first)) == "Are the two Lokesh Kadris on WhatsApp the same person?")
    }

    @Test func aThirdChatUnderTheNameIsPendingTowardBothAndTheQuestionFollowsAMerge() async throws {
        let v = try Self.vault(); let c = Ticker(); let r = c.registry(v)
        let rr = await r.register(label: "Lokesh Kadri", handle: "whatsapp:+1"); c.tick()
        let n = await r.register(label: "Lokesh Kadri", handle: "slack:U1"); c.tick()
        await r.setNotePath("People/Lokesh Kadri.md", for: rr)
        // a third chat under the very name: its own record, pending toward both — a handle left unattached would route its asks nowhere and ask nobody
        let t = await r.register(label: "Lokesh Kadri", handle: "teams:T1")
        let (count, pt, prr, pn) = (await r.people().count, await r.person(t), await r.person(rr), await r.person(n))
        #expect(count == 3 && pt?.pending == [rr, n] && prr?.pending == [n, t] && pn?.pending == [rr, t])
        #expect(await r.register(label: "Lokesh Kadri", handle: "teams:T1") == t)
        let three = await r.suspects()
        #expect(three.count == 3 && three.allSatisfy(PeopleQuestion.isPending), "three questions, none guessed")
        // N merges into R: T's question about N is now about R, and about nobody twice
        _ = await r.merge(keep: rr, drop: n)
        let (pt2, prr2, left) = (await r.person(t), await r.person(rr), await r.suspects().count)
        #expect(pt2?.pending == [rr] && prr2?.pending == [t] && left == 1, "the question follows the person")
        // kept apart, T and R are never asked again — and T, the namesake without a note, gets a file of his own
        await r.keepSeparate(rr, t)
        let (people, none) = (await r.people(), await r.suspects().isEmpty)
        #expect(none && PersonRegistry.suggestedNotePath(for: people.first { $0.id == t }!, among: people) == "People/Lokesh Kadri (Teams).md")
    }

    @Test func anAnswerTheAppGaveWhileTheRunHeldItsCopyStands() async throws {
        // the run holds a pending pair; the app says Different people meanwhile; the run's save keeps the answer and what the run learned
        let v = try Self.vault(); let c = Ticker(); let first = c.registry(v)
        let a = await first.register(label: "Lokesh Kadri", handle: "whatsapp:+1"); c.tick(); let b = await first.register(label: "Lokesh Kadri", handle: "slack:U1")
        try await first.save()
        let run = c.registry(v); await run.load()
        let app = c.registry(v); await app.load(); await app.keepSeparate(a, b); try await app.save()
        _ = await run.register(label: "Lokesh Kadri", handle: "slack:U1", proofs: ["email:n@x.in"])
        try await run.save()
        let again = c.registry(v); await again.load()
        let (pa, pb) = (try #require(await again.person(a)), try #require(await again.person(b)))
        #expect(pa.pending.isEmpty && pb.pending.isEmpty && pa.notSame == [b] && pb.notSame == [a] && pb.proofs == ["email:n@x.in"], "kept separate stands; the proof the run learned is kept")
        // the other way round: the app said Same person
        let v2 = try Self.vault(); let seed = c.registry(v2)
        let x = await seed.register(label: "Lokesh Kadri", handle: "whatsapp:+1"); c.tick(); let y = await seed.register(label: "Lokesh Kadri", handle: "slack:U1"); try await seed.save()
        let run2 = c.registry(v2); await run2.load()
        let app2 = c.registry(v2); await app2.load(); await app2.merge(keep: x, drop: y); try await app2.save()
        _ = await run2.register(label: "Lokesh Kadri", handle: "slack:U1"); try await run2.save()
        let final = c.registry(v2); await final.load()
        let (count, px) = (await final.people().count, try #require(await final.person(x)))
        #expect(count == 1 && px.pending == [] && px.handles == ["whatsapp:+1", "slack:U1"])
    }

    @Test func proofsAndPendingSurviveTheFileAndAnOldFileLoadsWithBothEmpty() async throws {
        let v = try Self.vault(); let c = Ticker(); let r = c.registry(v)
        let a = await r.register(label: "Lokesh Kadri", handle: "whatsapp:+919000000111", proofs: ["email:lokesh@harbour.test"]); c.tick()
        let b = await r.register(label: "Lokesh Kadri", handle: "slack:U1")
        try await r.save()
        let again = c.registry(v); await again.load()
        let (pa, pb) = (try #require(await again.person(a)), try #require(await again.person(b)))
        #expect(pa.proofs == ["email:lokesh@harbour.test", "phone:919000000111"] && pa.pending == [b] && pb.pending == [a])
        // a people.json from before: no proofs, no pending — and the records it joined by name stay joined
        let old = """
        {"version":1,"people":[{"id":"p-old","name":"Lokesh Kadri","aliases":["Lokesh Kadri"],"handles":["whatsapp:+919000000111","slack:U1"],"notePath":"People/Lokesh Kadri.md","notSame":[],"firstSeen":"2026-09-01T00:00:00Z","lastSeen":"2026-09-01T00:00:00Z"}]}
        """
        let v2 = try Self.vault()
        try FileManager.default.createDirectory(at: v2.root.appendingPathComponent(".brownie"), withIntermediateDirectories: true)
        try old.write(to: v2.root.appendingPathComponent(".brownie/people.json"), atomically: true, encoding: .utf8)
        let legacy = c.registry(v2); await legacy.load()
        let p = try #require(await legacy.person("p-old"))
        #expect(p.proofs.isEmpty && p.pending.isEmpty && p.handles.count == 2 && p.allProofs == ["phone:919000000111"], "nothing is split; the handle still proves its phone")
        #expect(await legacy.register(label: "Lokesh Kadri", handle: "slack:U1") == "p-old")
        #expect(await legacy.suspects().isEmpty)
    }

    @Test func contactsLinkWhatOneCardProvesAndAnswerAPendingPairEitherWay() async throws {
        let v = try Self.vault(); let c = Ticker(); let r = c.registry(v)
        let wa = await r.register(label: "Lokesh (+919000000111)", handle: "whatsapp:+919000000111"); c.tick()
        await r.setNotePath("People/Lokesh.md", for: wa)
        let sl = await r.register(label: "Lokesh Kadri", handle: "slack:U1", proofs: ["email:lokesh@harbour.test"])
        let before = await r.suspects()
        #expect(before.count == 1 && !PeopleQuestion.isPending(before[0]), "\"Lokesh Kadri\" beside \"Lokesh\" is a look-alike, not a question Brownie raised")
        // one card holds the phone and the email: the two are one person, merged onto the one with the note, who learns the card's name
        let card = ContactCard(name: "Lokesh Kadri", nickname: "Nitu", phones: ["+91 90000 00111"], emails: ["Lokesh@Harbour.test"])
        #expect(await r.link(contacts: [card]) == 1)
        let (kept, gone) = (try #require(await r.person(wa)), await r.person(sl))
        #expect(gone == nil && kept.handles == ["whatsapp:+919000000111", "slack:U1"] && kept.notePath == "People/Lokesh.md")
        #expect(kept.name == "Lokesh Kadri" && kept.aliases.contains("Nitu") && Set(kept.proofs) == ["phone:919000000111", "email:lokesh@harbour.test"])
        #expect(await r.link(contacts: [card]) == 0, "linking again changes nothing")
        #expect(await r.suspects().isEmpty)
        // a pending pair proven one by a card is merged; one on two cards under two names is kept separate; two cards under one name leave the question
        let v2 = try Self.vault(); let r2 = c.registry(v2)
        let a = await r2.register(label: "Lokesh Kadri", handle: "whatsapp:+919000000001"); c.tick()
        let b = await r2.register(label: "Lokesh Kadri", handle: "slack:U1", proofs: ["email:n@x.in"])
        #expect(await r2.person(a)?.pending == [b])
        await r2.link(contacts: [ContactCard(name: "Lokesh Kadri", phones: ["+91 90000 00001"], emails: ["n@x.in"])])
        let (count2, pa) = (await r2.people().count, await r2.person(a))
        #expect(count2 == 1 && pa?.pending == [], "one card: same person")
        let v3 = try Self.vault(); let r3 = c.registry(v3)
        let x = await r3.register(label: "Lokesh Kadri", handle: "whatsapp:+919000000001"); c.tick()
        let y = await r3.register(label: "Lokesh Kadri", handle: "slack:U1", proofs: ["email:n@x.in"])
        await r3.link(contacts: [ContactCard(name: "Lokesh Kadri", phones: ["+919000000001"], emails: []), ContactCard(name: "Lokesh Kadri", phones: [], emails: ["n@x.in"])])
        let (px0, still) = (await r3.person(x), await r3.suspects().count)
        #expect(px0?.pending == [y] && still == 1, "two cards under one name prove nothing: still a question")
        await r3.link(contacts: [ContactCard(name: "Lokesh Kadri", phones: ["+919000000001"], emails: []), ContactCard(name: "Lokesh K. (Harbour)", phones: [], emails: ["n@x.in"])])
        let (px, py, none) = (try #require(await r3.person(x)), try #require(await r3.person(y)), await r3.suspects().isEmpty)
        #expect(px.pending.isEmpty && py.pending.isEmpty && px.notSame == [y] && py.notSame == [x], "two cards, two names: different people")
        #expect(py.aliases.contains("Lokesh K. (Harbour)") && none)
        try await r3.save()
        // two with a note each are not merged here, where the notes cannot be folded: the pair is left for the banner, whose one click folds them
        let v4 = try Self.vault(); let r4 = c.registry(v4)
        let m = await r4.register(label: "Lokesh", handle: "whatsapp:+919000000001"); c.tick()
        let n = await r4.register(label: "Lokesh Kadri", handle: "slack:U1", proofs: ["email:n@x.in"])
        await r4.setNotePath("People/Lokesh.md", for: m); await r4.setNotePath("People/Lokesh Kadri.md", for: n)
        #expect(await r4.link(contacts: [ContactCard(name: "Lokesh Kadri", phones: ["+919000000001"], emails: ["n@x.in"])]) == 0)
        let (pm, pn, ask) = (try #require(await r4.person(m)), try #require(await r4.person(n)), await r4.suspects())
        #expect(pm.pending == [n] && pn.pending == [m] && pm.proofs.contains("email:n@x.in") && pn.proofs.contains("phone:919000000001"), "both learn the card; neither note is orphaned")
        #expect(ask.count == 1 && PeopleQuestion.isPending(ask[0]) && Set([ask[0].0.id, ask[0].1.id]) == [m, n])
        // the user's own card links nothing, even on a number a record carries; nor does a card with no phone or email
        let me = PersonRegistry(vault: v3.root, now: { Self.t0 }, selfNames: ["Ishan Shirke"])
        await me.load()
        #expect(await me.link(contacts: [ContactCard(name: "Ishan Shirke", phones: ["+919000000001"], emails: []), ContactCard(name: "Nobody", phones: [], emails: [])]) == 0)
        #expect(await me.person(x)?.aliases.contains("Ishan Shirke") == false)
    }
}

@Suite struct PersonRegistryProfileProofTests {
    static let t0 = Date(timeIntervalSince1970: 1_789_560_000)
    func fresh() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("people-\(UUID().uuidString)/KB", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    /// The Slack "Lokesh Kadri" was kept apart from the WhatsApp one because a name proves nothing; then Slack's profile
    /// shows the number the WhatsApp handle is — proof — and the two become one without a question.
    @Test func aProfileThatProvesTheNumberJoinsTheNamesakes() async throws {
        let r = PersonRegistry(vault: try fresh(), now: { Self.t0 })
        let wa = await r.register(label: "Lokesh Kadri", handle: "whatsapp:+919000000111")
        let sl = await r.register(label: "Lokesh Kadri", handle: "slack:U1")
        let pendingBefore = await r.person(wa)?.pending
        #expect(wa != sl && pendingBefore == [sl], "a name alone opens a second record and a question")
        let learned = await r.learn(proofs: ["phone:919000000111"], forHandle: "slack:U1")
        #expect(learned)
        let people = await r.people()
        #expect(people.count == 1 && Set(people[0].handles) == ["whatsapp:+919000000111", "slack:U1"] && people[0].pending.isEmpty, "one person, the question gone")
        let again = await r.learn(proofs: ["phone:919000000111"], forHandle: "slack:U1")
        let nobody = await r.learn(proofs: ["email:x@y.in"], forHandle: "teams:nobody")
        #expect(!again && !nobody, "nothing new the second time; a handle nobody holds teaches nothing")
    }
    /// Both namesakes already have a note: the proof does not fold two files behind the user's back — it marks the pair
    /// pending so the banner folds them with the notes. Kept apart by the user, they stay apart.
    @Test func aProofBetweenTwoNotesAsksRatherThanFolds() async throws {
        let r = PersonRegistry(vault: try fresh(), now: { Self.t0 })
        let wa = await r.register(label: "Lokesh Kadri", handle: "whatsapp:+919000000111")
        let sl = await r.register(label: "Lokesh Kadri", handle: "slack:U1")
        await r.setNotePath("People/Lokesh Kadri.md", for: wa); await r.setNotePath("People/Lokesh Kadri (Slack).md", for: sl)
        await r.keepSeparate(wa, sl)
        _ = await r.learn(proofs: ["phone:919000000111"], forHandle: "slack:U1")
        let apart = await r.people()
        #expect(apart.count == 2, "kept apart by the user stays apart even with a shared number")
        let r2 = PersonRegistry(vault: try fresh(), now: { Self.t0 })
        let a = await r2.register(label: "Lokesh Kadri", handle: "whatsapp:+919000000111"), b = await r2.register(label: "Lokesh Kadri", handle: "slack:U1")
        await r2.setNotePath("People/Lokesh Kadri.md", for: a); await r2.setNotePath("People/Lokesh Kadri (Slack).md", for: b)
        let learned = await r2.learn(proofs: ["phone:919000000111"], forHandle: "slack:U1")
        let count = await r2.people().count, pending = await r2.person(a)?.pending
        #expect(learned && count == 2 && pending == [b], "two notes: the banner's job")
    }
}
