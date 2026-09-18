import Testing
import Foundation
import Domain
@testable import Knowledge

/// The brain's file tools, driven as a scripted brain would: prose in, prose out, and one sentence back for
/// every write that would break the vault's shape.
@Suite struct FileToolsTests {
    static let today = "2026-09-16"
    static let block = "<!-- brownie:status -->\n## Between you\n- ⏳ 3 Sep — they asked: “lunch?” — no reply yet\n<!-- /brownie:status -->"
    struct World {
        let root: URL
        var tools: [Tool]
        func put(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        func raw(_ rel: String) -> String? { try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) }
        func call(_ name: String, _ args: [String: Any]) async throws -> String {
            try await tools.first { $0.name == name }!.run(try JSONSerialization.data(withJSONObject: args)).text
        }
        func read(_ p: String) async throws -> String { try await call("read_file", ["path": p]) }
        func write(_ p: String, _ c: String) async throws -> String { try await call("write_file", ["path": p, "content": c]) }
        /// The one sentence a refused call hands the brain, or nil when it went through.
        func refusal(_ name: String, _ args: [String: Any]) async -> String? {
            do { _ = try await call(name, args); return nil } catch let r as FileTools.Refusal { return r.description } catch { return "\(error)" }
        }
    }
    static func world(people: [Person] = []) throws -> World {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return World(root: root, tools: FileTools.make(root: root, people: people, today: today))
    }
    static func owned(_ body: String, path: String, extra: String = "") -> String {
        var m = NoteMeta.fresh(path: path, body: body, today: "2026-09-01"); m.updated = "2026-09-10"; m.sources = ["whatsapp"]
        return m.render().replacingOccurrences(of: "\n---\n", with: extra.isEmpty ? "\n---\n" : "\n\(extra)\n---\n") + body
    }
    static let t0 = Date(timeIntervalSince1970: 1_789_560_000)
    static func person(_ id: String, _ name: String, aliases: [String] = [], note: String?) -> Person { Person(id: id, name: name, aliases: aliases, notePath: note, firstSeen: t0, lastSeen: t0) }

    @Test func writeBeforeReadIsRefusedAndReadThenWriteGoesThrough() async throws {
        let w = try Self.world()
        try w.put("People/Arif.md", Self.owned("# Arif\n\nA friend.\n", path: "People/Arif.md"))
        #expect(await w.refusal("write_file", ["path": "People/Arif.md", "content": "# Arif\n\nrewritten\n"]) == "read People/Arif.md before overwriting it")
        #expect(w.raw("People/Arif.md")!.hasSuffix("# Arif\n\nA friend.\n"), "nothing was written")
        #expect(try await w.read("People/Arif.md") == "# Arif\n\nA friend.\n", "the brain sees prose, not the front-matter")
        #expect(try await w.write("People/Arif.md", "# Arif\n\nA friend from Pune.\n") == "wrote People/Arif.md (28 bytes)")
        #expect(w.raw("People/Arif.md")!.hasSuffix("---\n# Arif\n\nA friend from Pune.\n"))
        #expect(try await w.write("Work/New.md", "# New\n") == "wrote Work/New.md (6 bytes)", "a new note needs no read")
    }

    @Test func frontMatterAndStatusBlockComeBackByteIdentical() async throws {
        let w = try Self.world()
        let body = "# Arif\n\n" + Self.block + "\n\nA friend.\n"
        let file = Self.owned(body, path: "People/Arif.md", extra: "tags: [friend]")
        try w.put("People/Arif.md", file)
        #expect(try await w.read("People/Arif.md") == "# Arif\n\nA friend.\n", "the status block is invisible to the brain")
        // The same prose back: the file does not change at all — same hash, same updated day.
        _ = try await w.write("People/Arif.md", "# Arif\n\nA friend.\n")
        #expect(w.raw("People/Arif.md") == file, "nothing moved, byte for byte")
        // New prose: the front-matter keeps created, sources and the user's key; updated moves to today; the block is back after the title.
        _ = try await w.write("People/Arif.md", "# Arif\n\nA friend from Pune.\n")
        let after = try #require(w.raw("People/Arif.md"))
        let (meta, newBody) = NoteMeta.parse(after, path: "People/Arif.md")
        let m = try #require(meta)
        #expect(m.created == "2026-09-01" && m.updated == Self.today && m.sources == ["whatsapp"] && m.extra["tags"] == " [friend]" && !m.userEdited)
        #expect(m.contentHash == NoteMeta.hash("# Arif\n\nA friend from Pune.\n"))
        #expect(newBody == "# Arif\n\n" + Self.block + "\n\nA friend from Pune.\n")
        // Front-matter or a block the brain wrote anyway are dropped, never doubled.
        _ = try await w.write("People/Arif.md", "---\nbrownie: person\nupdated: 1999-01-01\n---\n# Arif\n\n<!-- brownie:status -->\nfake\n<!-- /brownie:status -->\n\nA colleague.\n")
        let third = try #require(w.raw("People/Arif.md"))
        #expect(third.components(separatedBy: "brownie:status -->").count == 3 && !third.contains("fake") && !third.contains("1999") && third.contains("created: 2026-09-01\n"))
    }

    @Test func anOutsideEditIsPersistedAsTheUsersOnTheNextWrite() async throws {
        let w = try Self.world()
        try w.put("People/Arif.md", Self.owned("# Arif\n\nA friend.\n", path: "People/Arif.md").replacingOccurrences(of: "A friend.", with: "A friend, edited in Obsidian."))
        _ = try await w.read("People/Arif.md")
        _ = try await w.write("People/Arif.md", "# Arif\n\nA friend, edited in Obsidian. Moved to Pune.\n")
        #expect(w.raw("People/Arif.md")!.contains("user_edited: true\n"))
    }

    @Test func periodStampedTitlesAreRefusedWithTheNoteToUse() async throws {
        let w = try Self.world()
        try w.put("Money/Invoices.md", Self.owned("# Invoices\n", path: "Money/Invoices.md"))
        #expect(await w.refusal("write_file", ["path": "Money/Invoices (Sep–Nov 2026).md", "content": "# Invoices (Sep–Nov 2026)\n"])
                == "\"Invoices (Sep–Nov 2026)\" is a period-stamped title; keep one note per subject and write the dated section into Money/Invoices.md instead")
        #expect(await w.refusal("write_file", ["path": "Money/Invoices (Sep-Nov 2026).md", "content": "x"])?.hasSuffix("into Money/Invoices.md instead") == true, "a plain hyphen too")
        #expect(await w.refusal("write_file", ["path": "Trips/Goa (2026).md", "content": "x"]) == "\"Goa (2026)\" is a period-stamped title; keep one note per subject and write the dated section into Trips/Goa.md instead", "no existing note: the bare path is named")
        #expect(await w.refusal("write_file", ["path": "Trips/Goa (Oct 2026).md", "content": "x"])?.contains("Trips/Goa.md") == true)
        #expect(await w.refusal("write_file", ["path": "Work/Plan (v2).md", "content": "# Plan (v2)\n"]) == nil, "parentheses that are not a period are fine")
    }

    @Test func nearDuplicateTitlesAreRefused() async throws {
        let w = try Self.world()
        try w.put("Money/Invoices.md", Self.owned("# Invoices\n", path: "Money/Invoices.md"))
        #expect(await w.refusal("write_file", ["path": "Money/invoices.md", "content": "x"]) == "Money/invoices.md differs from Money/Invoices.md only by case, punctuation or a date suffix; write into Money/Invoices.md instead")
        #expect(await w.refusal("write_file", ["path": "Money/Invoices!.md", "content": "x"])?.contains("write into Money/Invoices.md") == true)
        #expect(await w.refusal("write_file", ["path": "Work/Invoices.md", "content": "x"]) == nil, "another folder is another subject")
    }

    @Test func anEleventhRootFolderIsRefused() async throws {
        let w = try Self.world()
        for f in ["People", "Groups", "Work", "Money", "Health", "Trips", "Home", "Admin", "Ideas", "Family"] { try w.put("\(f)/One.md", "# One\n") }
        let r = await w.refusal("write_file", ["path": "Pets/Bruno.md", "content": "# Bruno\n"])
        #expect(r == "the knowledge base already has its 10 root folders (Admin, Family, Groups, Health, Home, Ideas, Money, People, Trips, Work); put this note in one of them instead of creating Pets/")
        #expect(await w.refusal("write_file", ["path": "Home/Bruno.md", "content": "# Bruno\n"]) == nil)
        #expect(await w.refusal("write_file", ["path": "Bruno.md", "content": "# Bruno\n"]) == nil, "the root is not a folder")
    }

    @Test func aNinthNoteInATopicFolderIsRefusedButPeopleAndGroupsGrow() async throws {
        let w = try Self.world()
        for i in 1...8 { try w.put("Work/N\(i).md", "# N\(i)\n"); try w.put("People/P\(i).md", "# P\(i)\n"); try w.put("Groups/G\(i).md", "# G\(i)\n") }
        let r = await w.refusal("write_file", ["path": "Work/N9.md", "content": "# N9\n"])
        #expect(r == "Work/ already holds 8 notes (N1, N2, N3, N4, N5, N6, N7, N8); fold this into one of them instead of adding a ninth")
        _ = try await w.read("Work/N3.md")
        #expect(await w.refusal("write_file", ["path": "Work/N3.md", "content": "# N3\nmore\n"]) == nil, "an existing note can still be updated")
        #expect(await w.refusal("write_file", ["path": "People/P9.md", "content": "# P9\n"]) == nil)
        #expect(await w.refusal("write_file", ["path": "Groups/G9.md", "content": "# G9\n"]) == nil)
        #expect(w.raw("Groups/G9.md")?.hasPrefix("---\nbrownie: group\n") == true, "a ninth group note is written, as a group")
    }

    @Test func peopleAndGroupsAreCreatedPastTheRootFolderCap() async throws {
        // A first build from mail and files alone can fill the ten folders without Groups/; the vault's own folders must still open.
        let w = try Self.world()
        for f in ["Work", "Money", "Health", "Trips", "Home", "Admin", "Ideas", "Family", "Pets", "Cars"] { try w.put("\(f)/One.md", "# One\n") }
        #expect(await w.refusal("write_file", ["path": "Books/Dune.md", "content": "# Dune\n"])?.hasPrefix("the knowledge base already has its 10 root folders") == true)
        #expect(await w.refusal("write_file", ["path": "Groups/Founders.md", "content": "# Founders\n"]) == nil)
        #expect(await w.refusal("write_file", ["path": "People/Arif.md", "content": "# Arif\n"]) == nil)
        #expect(w.raw("Groups/Founders.md")?.hasPrefix("---\nbrownie: group\n") == true && w.raw("People/Arif.md")?.hasPrefix("---\nbrownie: person\n") == true)
        #expect(FileTools.rootFolders(of: w.root).count == 12, "neither counts towards the cap")
        #expect(await w.refusal("write_file", ["path": "Books/Dune.md", "content": "# Dune\n"]) != nil, "and the cap still holds for the rest")
    }

    @Test func readmeOverBudgetIsRefused() async throws {
        let w = try Self.world()
        let long = "# Me\n\n" + Array(repeating: "word", count: 400).joined(separator: " ")
        #expect(await w.refusal("write_file", ["path": "README.md", "content": long]) == "README.md would be 402 words; the map stays under 350 — keep one line per folder and three to five recent updates")
        #expect(await w.refusal("write_file", ["path": "README.md", "content": "# Me\n\n" + Array(repeating: "word", count: 200).joined(separator: " ")]) == nil)
        #expect(w.raw("README.md")?.hasPrefix("---\nbrownie: portrait\n") == true)
    }

    /// The README is the vault's map, and the user likes it that way: a folder index goes through.
    @Test func readmeThatReadsAsAFolderIndexIsWelcome() async throws {
        let w = try Self.world()
        try w.put("Work/Loadmill.md", "# Loadmill\n"); try w.put("Money/Bills.md", "# Bills\n")
        let index = "# Knowledge Base\n\n- People/ — one note per person\n- Groups/ — the chats\n- Work — Loadmill and Orbit\n- Money — bills\n\n## Recent updates\n- Updated [[Kanika Pandey]] with the SBI deck\n"
        #expect(await w.refusal("write_file", ["path": "README.md", "content": index]) == nil)
        #expect(w.raw("README.md")?.hasSuffix(index) == true)
    }

    /// The user is never a person or a group in their own vault: the note is refused, and the sentence says where what is about them goes.
    @Test func aPeopleOrGroupsNoteAboutTheUserIsRefused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let w = World(root: root, tools: FileTools.make(root: root, today: Self.today, selfNames: ["Vivek Upreti", "vivek"]))
        let refusal = "That is you — what is about you belongs in a topic note under Life/ or Work/, never in People/"
        for path in ["People/Vivek Upreti.md", "People/Vivek.md", "People/Vivek Upreti — Career Materials (Jul–Aug 2026).md", "People/vivek upreti (work).md", "Groups/Vivek Upreti.md"] {
            #expect(await w.refusal("write_file", ["path": path, "content": "# X\n"]) == refusal, Comment(rawValue: path))
            #expect(w.raw(path) == nil)
        }
        #expect(try await w.write("People/Kanika Pandey.md", "# Kanika Pandey\n") == "wrote People/Kanika Pandey.md (16 bytes)")
        #expect(try await w.write("Life/Vivek Upreti — Career Materials.md", "# Career Materials\n").hasPrefix("wrote"), "a topic note may carry the name")
        let plain = try Self.world()
        #expect(await plain.refusal("write_file", ["path": "People/Vivek Upreti.md", "content": "# Vivek Upreti\n"]) == nil, "with no self names known, nothing is refused")
    }

    @Test func aSecondPeoplePathForAKnownPersonIsRefused() async throws {
        let w = try Self.world(people: [Self.person("p-1", "Arjun Mehta", aliases: ["Arjun"], note: "People/Arjun Mehta.md"), Self.person("p-2", "Nitesh", note: nil)])
        try w.put("People/Arjun Mehta.md", Self.owned("# Arjun Mehta\n", path: "People/Arjun Mehta.md"))
        #expect(await w.refusal("write_file", ["path": "People/Arjun.md", "content": "# Arjun\n"]) == "Arjun Mehta already has a note at People/Arjun Mehta.md; write about them there, not in People/Arjun.md")
        #expect(await w.refusal("write_file", ["path": "People/arjun mehta.md", "content": "x"])?.contains("People/Arjun Mehta.md") == true)
        // A person without a note yet gets one, stamped with the registry's id and spellings.
        #expect(await w.refusal("write_file", ["path": "People/Nitesh.md", "content": "# Nitesh\n"]) == nil)
        let m = try #require(NoteMeta.parse(w.raw("People/Nitesh.md")!, path: "People/Nitesh.md").meta)
        #expect(m.id == "p-2" && m.brownie == "person" && m.created == Self.today && m.updated == Self.today && m.aliases.isEmpty)
        #expect(await w.refusal("write_file", ["path": "People/Someone New.md", "content": "# Someone New\n"]) == nil, "a stranger gets a file")
        #expect(NoteMeta.parse(w.raw("People/Someone New.md")!, path: "People/Someone New.md").meta?.id == nil)
    }

    /// Two people Brownie is not sure about — the same name on WhatsApp and on Slack, pending toward each other — are two
    /// to the file tools: the second gets the file the header told the brain to write, stamped with his own id, and neither
    /// is refused as "a second People path" for the other. The same once the user has said they are two.
    @Test func aPendingNamesakeGetsTheFileHeWasToldAndIsNoSecondPathForTheOther() async throws {
        var wa = Self.person("p-1", "Nitesh Kumar", aliases: ["Nitesh Kumar"], note: "People/Nitesh Kumar.md"); wa.handles = ["whatsapp:+919540752593"]; wa.pending = ["p-2"]
        var sl = Self.person("p-2", "Nitesh Kumar", aliases: ["Nitesh Kumar"], note: nil); sl.handles = ["slack:U1"]; sl.pending = ["p-1"]
        let w = try Self.world(people: [wa, sl])
        try w.put("People/Nitesh Kumar.md", Self.owned("# Nitesh Kumar\n\nOn WhatsApp.\n", path: "People/Nitesh Kumar.md"))
        #expect(PersonRegistry.headerLines([wa, sl]).contains { $0.contains("write them in People/Nitesh Kumar (Slack).md") })
        #expect(await w.refusal("write_file", ["path": "People/Nitesh Kumar (Slack).md", "content": "# Nitesh Kumar (Slack)\n\nOn Slack.\n"]) == nil, "his own file, as the header said")
        let m = try #require(NoteMeta.parse(w.raw("People/Nitesh Kumar (Slack).md")!, path: "People/Nitesh Kumar (Slack).md").meta)
        #expect(m.id == "p-2" && m.aliases == ["Nitesh Kumar"], "stamped as the Slack record's, so the seed gives it to him and not to the WhatsApp Nitesh; his name is the alias")
        #expect(await w.refusal("write_file", ["path": "People/Nitesh Kumar.md", "content": "# Nitesh Kumar\n\nMore.\n"]) == "read People/Nitesh Kumar.md before overwriting it", "the WhatsApp file is still the WhatsApp file")
        #expect(await w.refusal("write_file", ["path": "People/Nitesh Kumar (Teams).md", "content": "# Nitesh Kumar (Teams)\n"]) == nil)
        #expect(NoteMeta.parse(w.raw("People/Nitesh Kumar (Teams).md")!, path: "People/Nitesh Kumar (Teams).md").meta?.id == nil, "a title neither was told, between two who share the key, is nobody's: unstamped, as before")
        // the user said they are two: the same files, and no refusal between them
        wa.pending = []; wa.notSame = ["p-2"]; sl.pending = []; sl.notSame = ["p-1"]
        let w2 = try Self.world(people: [wa, sl])
        try w2.put("People/Nitesh Kumar.md", Self.owned("# Nitesh Kumar\n", path: "People/Nitesh Kumar.md"))
        #expect(await w2.refusal("write_file", ["path": "People/Nitesh Kumar (Slack).md", "content": "# Nitesh Kumar (Slack)\n"]) == nil)
        #expect(NoteMeta.parse(w2.raw("People/Nitesh Kumar (Slack).md")!, path: "People/Nitesh Kumar (Slack).md").meta?.id == "p-2")
        // neither has a note yet: the first keeps the plain title, the newcomer his suffixed one
        var a = Self.person("p-1", "Nitesh Kumar", aliases: ["Nitesh Kumar"], note: nil); a.handles = ["whatsapp:+1"]; a.pending = ["p-2"]
        var b = Self.person("p-2", "Nitesh Kumar", aliases: ["Nitesh Kumar"], note: nil); b.handles = ["slack:U1"]; b.pending = ["p-1"]; b.lastSeen = Self.t0.addingTimeInterval(60)
        let w3 = try Self.world(people: [a, b])
        #expect(await w3.refusal("write_file", ["path": "People/Nitesh Kumar.md", "content": "# Nitesh Kumar\n"]) == nil)
        #expect(await w3.refusal("write_file", ["path": "People/Nitesh Kumar (Slack).md", "content": "# Nitesh Kumar (Slack)\n"]) == nil)
        #expect(NoteMeta.parse(w3.raw("People/Nitesh Kumar.md")!, path: "People/Nitesh Kumar.md").meta?.id == "p-1")
        #expect(NoteMeta.parse(w3.raw("People/Nitesh Kumar (Slack).md")!, path: "People/Nitesh Kumar (Slack).md").meta?.id == "p-2")
    }

    /// A person archived since the roster was written can still be written about: whichever path the brain takes — the
    /// archived one the roster names, or the active one — the note comes back first and the write updates it, and no
    /// refusal along the way names a path the tools would refuse.
    @Test func anArchivedPersonComesBackForTheWriteAndNoRefusalNamesArchive() async throws {
        let w = try Self.world(people: [Self.person("p-1", "Priya", note: "People/Archive/Priya.md"), Self.person("p-2", "Kanika Pandey", aliases: ["KP Loadmill"], note: "People/Archive/Kanika Pandey.md")])
        try w.put("People/Archive/Priya.md", Self.owned("# Priya\n\n" + Self.block + "\n\nSister-in-law.\n", path: "People/Archive/Priya.md"))
        try w.put("People/Archive/Kanika Pandey.md", Self.owned("# Kanika Pandey\n\nWorks at Loadmill.\n", path: "People/Archive/Kanika Pandey.md"))
        let created = NoteMeta.parse(w.raw("People/Archive/Priya.md")!, path: "People/Archive/Priya.md").meta!.created
        // The brain writes the active path unread: the note comes back, and what is refused is the unread overwrite — of a path it can read.
        let r = await w.refusal("write_file", ["path": "People/Priya.md", "content": "# Priya\n\nMoving to Berlin.\n"])
        #expect(r == "read People/Priya.md before overwriting it")
        #expect(w.raw("People/Priya.md") != nil && w.raw("People/Archive/Priya.md") == nil, "back where the brain writes")
        #expect(try await w.read("People/Priya.md") == "# Priya\n\nSister-in-law.\n")
        #expect(try await w.write("People/Priya.md", "# Priya\n\nSister-in-law.\n\nMoving to Berlin.\n") == "wrote People/Priya.md (43 bytes)")
        let (meta, body) = NoteMeta.parse(w.raw("People/Priya.md")!, path: "People/Priya.md")
        #expect(meta?.created == created && meta?.updated == Self.today && body == "# Priya\n\n" + Self.block + "\n\nSister-in-law.\n\nMoving to Berlin.\n", "an update: its block, its status lines, the new prose")
        #expect(await w.refusal("write_file", ["path": "People/Priya.md", "content": "# Priya\n\nAnd again.\n"]) == nil, "the part's roster followed the move")
        // The brain follows the roster to the archived path: read there, write there — it lands on the active path.
        #expect(try await w.read("People/Archive/Kanika Pandey.md") == "# Kanika Pandey\n\nWorks at Loadmill.\n")
        #expect(try await w.write("People/Archive/Kanika Pandey.md", "# Kanika Pandey\n\nWorks at Loadmill.\n\nLeft for Berlin too.\n") == "wrote People/Kanika Pandey.md (58 bytes)")
        #expect(w.raw("People/Kanika Pandey.md")!.hasSuffix("Left for Berlin too.\n") && w.raw("People/Archive/Kanika Pandey.md") == nil)
        #expect(await w.refusal("write_file", ["path": "People/KP Loadmill.md", "content": "# KP Loadmill\n"]) == "Kanika Pandey already has a note at People/Kanika Pandey.md; write about them there, not in People/KP Loadmill.md")
        #expect(await w.refusal("write_file", ["path": "People/Archive/Nobody.md", "content": "# Nobody\n"])?.contains("one level deep") == true, "no note there to bring back: the depth rule stands")
    }

    @Test func aNewPeopleNoteCarriesNamesOnlyAsAliases() async throws {
        // The registry learns chat labels verbatim — numbers, handles and all; the note's aliases are the names among them.
        let labels = ["Nitesh (+919540752593)", "nitesh", "Nitesh Kumar", "Nitesh Kumar (Loadmill)", "@nitesh", "919540752593@s.whatsapp.net", "+91 95407 52593", "nitesh@example.com", "whatsapp:+919540752593", "Nitesh K"]
        let w = try Self.world(people: [Self.person("p-2", "Nitesh", aliases: labels, note: nil)])
        #expect(await w.refusal("write_file", ["path": "People/Nitesh.md", "content": "# Nitesh\n"]) == nil)
        let raw = try #require(w.raw("People/Nitesh.md"))
        let m = try #require(NoteMeta.parse(raw, path: "People/Nitesh.md").meta)
        #expect(m.aliases == ["Nitesh Kumar", "Nitesh K"], "names only, the title not repeated, each spelling once")
        #expect(!raw.contains("9540752593") && !raw.contains("@") && !raw.contains("whatsapp:"), "no number, address, handle or JID anywhere in the file")
    }

    @Test func aFolderSpelledInAnotherCaseIsRefusedNamingTheSpellingThatExists() async throws {
        // The Mac's file system folds "people/" onto People/, so a miscased path would slip past every rule keyed on the folder.
        let w = try Self.world(people: [Self.person("p-1", "Arjun Mehta", aliases: ["Arjun"], note: "People/Arjun Mehta.md")])
        try w.put("People/Arjun Mehta.md", Self.owned("# Arjun Mehta\n", path: "People/Arjun Mehta.md"))
        try w.put("Money/Rent.md", Self.owned("# Rent\n", path: "Money/Rent.md"))
        #expect(await w.refusal("write_file", ["path": "people/Arjun.md", "content": "# Arjun\n"]) == "the folder is spelled People/; spell it People/Arjun.md, not people/Arjun.md")
        #expect(await w.refusal("write_file", ["path": "PEOPLE/Someone New.md", "content": "# Someone New\n"]) == "the folder is spelled People/; spell it People/Someone New.md, not PEOPLE/Someone New.md")
        #expect(await w.refusal("write_file", ["path": "groups/Founders.md", "content": "# Founders\n"]) == "the folder is spelled Groups/; spell it Groups/Founders.md, not groups/Founders.md", "Brownie's own folders are spelled one way even before they exist")
        #expect(await w.refusal("write_file", ["path": "money/Bills.md", "content": "# Bills\n"]) == "Money/ already exists and money/Bills.md differs from it only by case; spell it Money/Bills.md")
        #expect(await w.refusal("write_file", ["path": "readme.md", "content": "# Me\n"]) == "the portrait is README.md; spell it so, not readme.md")
        #expect(await w.refusal("write_file", ["path": "today.md", "content": "x"]) != nil)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: w.root.appendingPathComponent("People").path)) == ["Arjun Mehta.md"], "no second file for a known person, and nothing stamped as a topic")
        #expect(w.raw("Money/Bills.md") == nil && w.raw("Groups/Founders.md") == nil && w.raw("README.md") == nil && w.raw("Today.md") == nil)
        // Spelled right, the same writes go through — and the ninth-note exemption sees People/ whatever the case would have been.
        for i in 1...8 { try w.put("People/P\(i).md", "# P\(i)\n") }
        #expect(await w.refusal("write_file", ["path": "People/Someone New.md", "content": "# Someone New\n"]) == nil)
        #expect(await w.refusal("write_file", ["path": "Money/Bills.md", "content": "# Bills\n"]) == nil)
        #expect(await w.refusal("write_file", ["path": "MONEY/Bills.md", "content": "# Bills\n"])?.contains("spell it Money/Bills.md") == true, "an existing note is not overwritten through another spelling either")
    }

    @Test func deletingAMiscasedPeopleOrGroupsPathIsRefused() async throws {
        let w = try Self.world()
        try w.put("People/Arif.md", "# Arif\n"); try w.put("Groups/Founders.md", "# Founders\n"); try w.put("Work/Old.md", "# Old\n"); try w.put("Today.md", "# Today\n")
        #expect(await w.refusal("delete_file", ["path": "people/Arif.md"])?.hasPrefix("notes under People/ and Groups/ are never deleted by the brain") == true)
        #expect(await w.refusal("delete_file", ["path": "GROUPS/founders.md"])?.hasPrefix("notes under People/ and Groups/ are never deleted by the brain") == true)
        #expect(await w.refusal("delete_file", ["path": "People/Archive/Arif.md"]) != nil)
        #expect(await w.refusal("delete_file", ["path": "people/archive/Arif.md"]) != nil)
        #expect(await w.refusal("delete_file", ["path": "work/Old.md"]) == "Work/ already exists and work/Old.md differs from it only by case; spell it Work/Old.md")
        #expect(await w.refusal("delete_file", ["path": "today.md"]) != nil)
        #expect(w.raw("People/Arif.md") != nil && w.raw("Groups/Founders.md") != nil && w.raw("Work/Old.md") != nil && w.raw("Today.md") != nil, "nothing went")
        #expect(try await w.call("delete_file", ["path": "Work/Old.md"]) == "deleted Work/Old.md")
    }

    @Test func deletingUnderPeopleOrGroupsIsRefused() async throws {
        let w = try Self.world()
        try w.put("People/Arif.md", "# Arif\n"); try w.put("Groups/Founders.md", "# Founders\n"); try w.put("Work/Old.md", "# Old\n")
        #expect(await w.refusal("delete_file", ["path": "People/Arif.md"])?.hasPrefix("notes under People/ and Groups/ are never deleted by the brain") == true)
        #expect(await w.refusal("delete_file", ["path": "Groups/Founders.md"]) != nil)
        #expect(w.raw("People/Arif.md") != nil && w.raw("Groups/Founders.md") != nil)
        #expect(try await w.call("delete_file", ["path": "Work/Old.md"]) == "deleted Work/Old.md")
        #expect(w.raw("Work/Old.md") == nil)
    }

    @Test func todayIsNeitherListedNorReadNorWritten() async throws {
        let w = try Self.world()
        try w.put(TodayNote.path, "# Today\n"); try w.put("People/Arif.md", "# Arif\n"); try w.put(".brownie/people.json", "{}")
        #expect(try await w.call("list_dir", [:]) == "People/\nPeople/Arif.md")
        #expect(await w.refusal("read_file", ["path": "Today.md"]) == "Today.md is Brownie's own checklist for the phone, not a note; leave it alone")
        #expect(await w.refusal("write_file", ["path": "Today.md", "content": "x"]) != nil)
        #expect(await w.refusal("write_file", ["path": "notes.txt", "content": "x"]) != nil)
        #expect(await w.refusal("write_file", ["path": "../escape.md", "content": "x"]) != nil)
        #expect(await w.refusal("write_file", ["path": "Work/Deep/Nested.md", "content": "x"]) != nil)
    }
}
