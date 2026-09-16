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

    // MARK: two people sharing a key

    @Test func resolvePrefersTheExactSpellingAndNeverGuessesBetweenTwoWhoShareAKey() async throws {
        let v = try Self.vault(); let r = v.registry()
        // "Kanika Pandey Loadmill.md" sorts before "Kanika Pandey.md", so the Loadmill record is on file first
        let notes = [Self.note("People/Kanika Pandey Loadmill.md", "Kanika Pandey Loadmill"), Self.note("People/Kanika Pandey.md", "Kanika Pandey"),
                     Self.note("People/Arjun Mehta.md", "Arjun Mehta"), Self.note("People/Arjun Mehta (Landlord).md", "Arjun Mehta (Landlord)")]
        await r.seed(from: [KnowledgeFolder(name: "People", notes: notes)])
        let people = await r.people()
        let plain = try #require(people.first { $0.notePath == "People/Kanika Pandey.md" }), loadmill = try #require(people.first { $0.notePath == "People/Kanika Pandey Loadmill.md" })
        let landlord = try #require(people.first { $0.notePath == "People/Arjun Mehta (Landlord).md" }), arjun = try #require(people.first { $0.notePath == "People/Arjun Mehta.md" })
        #expect(await r.resolve(label: "Kanika Pandey", handle: nil) == plain.id, "the chat named exactly like the note is that note's person, not the first record on file")
        #expect(await r.resolve(label: "kanika pandey ", handle: nil) == plain.id, "case and surrounding space aside")
        #expect(await r.resolve(label: "Kanika Pandey Loadmill", handle: nil) == loadmill.id)
        #expect(await r.resolve(label: "Arjun Mehta (Landlord)", handle: nil) == landlord.id, "the parenthesised suffix the key strips still tells the two apart")
        #expect(await r.resolve(label: "Arjun Mehta", handle: nil) == arjun.id)
        #expect(await r.resolve(label: "Kanika Pandey (work)", handle: nil) == nil, "a spelling that is neither of them is nobody — never the first on file")
        // a label that spells neither is not learned onto either, and no third person is opened for it
        let picked = await r.register(label: "Kanika Pandey (work)", handle: "whatsapp:+919")
        let count = await r.people().count
        #expect([plain.id, loadmill.id].contains(picked) && count == 4)
        #expect(await r.people().allSatisfy { $0.handles.isEmpty && !$0.aliases.contains("Kanika Pandey (work)") }, "no handle and no alias attached by a guess")
        #expect(await r.resolve(label: "Renamed Chat", handle: "whatsapp:+919") == nil)
        // the exact spelling takes the handle, and the handle then decides whatever the chat is called
        #expect(await r.register(label: "Kanika Pandey", handle: "whatsapp:+919") == plain.id)
        let plainHandles = await r.person(plain.id)?.handles, loadmillHandles = await r.person(loadmill.id)?.handles
        #expect(plainHandles == ["whatsapp:+919"] && loadmillHandles == [])
        #expect(await r.resolve(label: "Renamed Chat", handle: "whatsapp:+919") == plain.id)
        // kept separate, the pair still resolves the same way, and the block for each label lands on its own note
        await r.keepSeparate(plain.id, loadmill.id)
        #expect(await r.notePath(forLabel: "Kanika Pandey", handle: nil, amongNotes: notes) == "People/Kanika Pandey.md")
        #expect(await r.notePath(forLabel: "Kanika Pandey Loadmill", handle: nil, amongNotes: notes) == "People/Kanika Pandey Loadmill.md")
        #expect(await r.notePath(forLabel: "Kanika Pandey (work)", handle: nil, amongNotes: notes) == nil, "nowhere rather than the wrong note")
        // the title fallback of an empty registry follows the same rule
        let e = try Self.vault().registry()
        #expect(await e.notePath(forLabel: "Kanika Pandey", handle: nil, amongNotes: notes) == "People/Kanika Pandey.md")
        #expect(await e.notePath(forLabel: "Kanika Pandey (work)", handle: nil, amongNotes: notes) == nil)
        // a person known from chats takes the note spelled like them, not the same-key note that sorts first
        let c = try Self.vault().registry()
        let known = await c.register(label: "Kanika Pandey", handle: "whatsapp:+1")
        await c.seed(from: [KnowledgeFolder(name: "People", notes: Array(notes.prefix(2)))])
        let knownPath = await c.notePath(for: known), knownCount = await c.people().count
        #expect(knownPath == "People/Kanika Pandey.md" && knownCount == 2)
    }

    @Test func seedLeavesEveryNotePathAloneWhenNoPeopleFolderWasListed() async throws {
        let v = try Self.vault(); let r = v.registry()
        try v.put("People/Nitesh.md", "# Nitesh\n\nRecurring.\n")
        try v.put("People/Arjun Mehta.md", "# Arjun Mehta\n")
        await r.seed(from: try await v.kb.folders())
        let paths = await r.people().compactMap(\.notePath).sorted()
        #expect(paths == ["People/Arjun Mehta.md", "People/Nitesh.md"])
        // one file the store cannot read (Latin-1 bytes) fails the whole listing, which the run turns into an empty one
        try Data([0x23, 0x20, 0x4A, 0xF6, 0x72, 0x67, 0x0A]).write(to: v.root.appendingPathComponent("People/Jorg.md"))
        let listed = try? await v.kb.folders()
        #expect(listed == nil, "the listing fails on the unreadable note")
        await r.seed(from: listed ?? [])
        #expect(await r.people().compactMap(\.notePath).sorted() == paths, "nothing was listed, so nothing is released")
        #expect(PersonRegistry.headerLines(await r.people()).allSatisfy { !$0.contains("no note yet") })
        // a listed People folder with a note gone does release that one
        await r.seed(from: Self.folders([("People/Nitesh.md", "Nitesh")]))
        #expect(await r.people().compactMap(\.notePath) == ["People/Nitesh.md"])
    }

    @Test func saveKeepsAMergeAndAKeepSeparateMadeWhileTheRunHeldItsCopy() async throws {
        let v = try Self.vault()
        let first = v.registry()
        await first.seed(from: Self.folders([("People/Kanika Pandey.md", "Kanika Pandey"), ("People/Kanika Pandey Loadmill.md", "Kanika Pandey Loadmill")]))
        let a = await first.register(label: "Arjun", handle: nil), b = await first.register(label: "Arjun Mehta", handle: "whatsapp:+1")
        try await first.save()
        let keep = try #require(await first.people().first { $0.notePath == "People/Kanika Pandey.md" }?.id), drop = try #require(await first.people().first { $0.notePath == "People/Kanika Pandey Loadmill.md" }?.id)
        // the night run loads its copy and works for an hour; meanwhile the app merges the Kanikas, keeps the Arjuns apart, deletes the dropped note
        let run = v.registry(at: 3600); await run.load()
        let app = v.registry(at: 10); await app.load()
        await app.merge(keep: keep, drop: drop); await app.keepSeparate(a, b); try await app.save()
        // the run learned a handle for the dropped spelling, a fuller name for Arjun, someone new, and saw the notes as they are now
        await run.seed(from: Self.folders([("People/Kanika Pandey.md", "Kanika Pandey"), ("People/Zed Zulu.md", "Zed Zulu")]))
        _ = await run.register(label: "Kanika Pandey Loadmill", handle: "whatsapp:+919")
        _ = await run.register(label: "Kanika Pandey", handle: "slack:U9")
        _ = await run.register(label: "Arjun", handle: "telegram:7")
        try await run.save()
        let again = v.registry(at: 99); await again.load()
        let people = await again.people()
        #expect(people.count == 4 && people.first { $0.id == drop } == nil, "the merge the app made stands")
        let kept = try #require(people.first { $0.id == keep })
        #expect(kept.aliases.contains("Kanika Pandey Loadmill") && kept.handles.sorted() == ["slack:U9", "whatsapp:+919"] && kept.notePath == "People/Kanika Pandey.md", "what the run learned about either Kanika is on the kept one")
        #expect(people.first { $0.id == a }?.notSame == [b] && people.first { $0.id == b }?.notSame == [a], "keep separate stands")
        #expect(people.first { $0.id == a }?.handles == ["telegram:7"] && people.first { $0.notePath == "People/Zed Zulu.md" } != nil)
        #expect(await again.suspects().isEmpty, "the banner has nothing left to ask")
        #expect(await run.people().sorted { $0.id < $1.id } == people.sorted { $0.id < $1.id }, "the run's own view is the reconciled one, so its status blocks route the same way")
        // the other order: the run saved first and the app, holding an older copy, merges afterwards — the run's learning survives
        let v2 = try Self.vault(); let seed = v2.registry()
        await seed.seed(from: Self.folders([("People/Kanika Pandey.md", "Kanika Pandey"), ("People/Kanika Pandey Loadmill.md", "Kanika Pandey Loadmill")])); try await seed.save()
        let k2 = try #require(await seed.people().first { $0.notePath == "People/Kanika Pandey.md" }?.id), d2 = try #require(await seed.people().first { $0.notePath == "People/Kanika Pandey Loadmill.md" }?.id)
        let app2 = v2.registry(at: 5); await app2.load()
        let run2 = v2.registry(at: 6); await run2.load()
        _ = await run2.register(label: "Kanika Pandey Loadmill", handle: "whatsapp:+919"); _ = await run2.register(label: "New Person", handle: nil); try await run2.save()
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
        let kept = "# Kanika Pandey\n<!-- brownie:status -->\n## Between you\n- ⏳ 1 Sep — they asked: “x?” — no reply yet\n<!-- /brownie:status -->\n\nWorks at Loadmill.\n"
        let dropped = "# Kanika Pandey Loadmill\n<!-- brownie:status -->\n## Between you\n- ⏳ 3 Sep — they asked: “pricing?” — no reply yet\n<!-- /brownie:status -->\n\nAsked about pricing.\n"
        let out = PersonNotes.appendMerged(into: kept, droppedBody: dropped, droppedName: "Kanika Pandey Loadmill", date: Self.t0, stripping: blocks)
        #expect(out == kept.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n## Merged from Kanika Pandey Loadmill (16 Sep 2026)\nAsked about pricing.\n")
        #expect(out.components(separatedBy: "<!-- brownie:status -->").count == 2, "one block in the note: the kept note's own")
        let legacy = "# Old\n\n<!-- brownie:between-you -->\n- ⏳ old\n<!-- /brownie:between-you -->\n\nStill here.\n<!-- brownie:status -->\nno closer\n"
        let out2 = PersonNotes.appendMerged(into: "# New\n", droppedBody: legacy, droppedName: "Old", date: Self.t0, stripping: blocks)
        #expect(out2 == "# New\n\n## Merged from Old (16 Sep 2026)\nStill here.\n<!-- brownie:status -->\nno closer\n", "the old markers go too; an opener with no closer is left as text")
        #expect(PersonNotes.appendMerged(into: "# New\n", droppedBody: dropped, droppedName: "K", date: Self.t0).contains("<!-- brownie:status -->"), "nothing is stripped unless asked")
    }

    @Test func renamedLoopsAndAsksKeepEveryOtherField() throws {
        var loop = Loop(id: "L1", direction: .theirs, person: "Arjun", what: "send the estimates", quote: "will send", sourceLabel: "WhatsApp · Fri", due: "Friday", dueDate: Self.t0, status: .lapsed,
                        openedAt: Self.t0.addingTimeInterval(-91 * 86400), closedAt: Self.t0, closedHow: "let go", closedBy: "lapsed", lapsedAt: Self.t0, firedCardIDs: ["c1"], cameBackCount: 2)
        loop.nudgedForDue = true; loop.owner = "either"
        let ask = Ask(id: "A1", person: "Arjun", bucket: BucketID("whatsapp:1"), askedAt: Self.t0.addingTimeInterval(-60 * 86400), question: "estimates?", answeredAt: Self.t0.addingTimeInterval(-59 * 86400),
                      reply: "lol", addressed: false, handle: "whatsapp:+1", lapsedAt: Self.t0.addingTimeInterval(-20 * 86400))
        let l = loop.renamed(to: "Arjun Mehta"), a = ask.renamed(to: "Arjun Mehta")
        #expect(l.person == "Arjun Mehta" && a.person == "Arjun Mehta")
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
