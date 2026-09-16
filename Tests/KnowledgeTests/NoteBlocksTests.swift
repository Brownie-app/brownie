import Testing
import Foundation
import Domain
@testable import Knowledge

/// The body read as blocks for the screen: every block kind, the inline styles, the three wikilink forms, HTML
/// comments that never show, and the status block lifted out as its own card.
@Suite struct NoteBlocksTests {
    typealias B = NoteBlocks.Block
    typealias I = NoteBlocks.Inline

    @Test func everyBlockKind() {
        let body = """
        # Nayan
        Friend from Pune; **owes** you a _book_.
        Second line of the same paragraph.

        ## Recently
        - met at `Koregaon`
        - [[Meera]] came too
          - nested
        1. first
        2. second

        ### Open
        - [ ] return the book
        - [x] lunch

        > he said: not before Diwali
        > two lines

        ---
        ```
        raw code
        ```
        """
        let blocks = NoteBlocks.parse(body)
        #expect(blocks[0] == .heading(level: 1, inlines: [.text("Nayan")]))
        #expect(blocks[1] == .paragraph([.text("Friend from Pune; "), .bold("owes"), .text(" you a "), .italic("book"), .text(". Second line of the same paragraph.")]))
        #expect(blocks[2] == .heading(level: 2, inlines: [.text("Recently")]))
        #expect(blocks[3] == .list([.init(indent: 0, ordinal: nil, inlines: [.text("met at "), .code("Koregaon")]), .init(indent: 0, ordinal: nil, inlines: [.wikilink(target: "Meera", heading: nil, label: "Meera"), .text(" came too")]),
                                     .init(indent: 1, ordinal: nil, inlines: [.text("nested")]), .init(indent: 0, ordinal: 1, inlines: [.text("first")]), .init(indent: 0, ordinal: 2, inlines: [.text("second")])]))
        #expect(blocks[4] == .heading(level: 3, inlines: [.text("Open")]))
        #expect(blocks[5] == .checklist([.init(checked: false, inlines: [.text("return the book")], cardID: nil), .init(checked: true, inlines: [.text("lunch")], cardID: nil)]))
        #expect(blocks[6] == .quote([.text("he said: not before Diwali\ntwo lines")]))
        #expect(blocks[7] == .rule)
        #expect(blocks[8] == .code("raw code"))
        #expect(blocks.count == 9)
    }

    @Test func deepHeadingsClampToThreeAndPlainHashesAreText() {
        #expect(NoteBlocks.parse("##### deep") == [.heading(level: 3, inlines: [.text("deep")])])
        #expect(NoteBlocks.parse("#hashtag") == [.paragraph([.text("#hashtag")])])
    }

    @Test func inlineStyles() {
        #expect(NoteBlocks.inlines("**bold** and __also__ and *it* and _it too_ and `code`") == [.bold("bold"), .text(" and "), .bold("also"), .text(" and "), .italic("it"), .text(" and "), .italic("it too"), .text(" and "), .code("code")])
        #expect(NoteBlocks.inlines("snake_case_name stays") == [.text("snake_case_name stays")], "an underscore inside a word is not italics")
        #expect(NoteBlocks.inlines("2 * 3 * 4") == [.text("2 * 3 * 4")], "a star with space around it is a star")
        #expect(NoteBlocks.inlines("see [the site](https://x.y)") == [.text("see "), .url(label: "the site", url: "https://x.y")])
    }

    @Test func theThreeWikilinkForms() {
        #expect(NoteBlocks.inlines("[[Meera]]") == [.wikilink(target: "Meera", heading: nil, label: "Meera")])
        #expect(NoteBlocks.inlines("[[Meera Iyer|Meera]]") == [.wikilink(target: "Meera Iyer", heading: nil, label: "Meera")])
        #expect(NoteBlocks.inlines("[[Meera#Open loops]]") == [.wikilink(target: "Meera", heading: "Open loops", label: "Meera › Open loops")])
        #expect(NoteBlocks.inlines("[[Meera#Open|her loops]]") == [.wikilink(target: "Meera", heading: "Open", label: "her loops")])
        #expect(NoteBlocks.inlines("[[unclosed") == [.text("[[unclosed")])
    }

    @Test func htmlCommentsNeverShow() {
        let body = "# T\nhello <!-- secret --> world\n<!-- a comment\nover lines -->\n- [ ] **Pay** — rent <!-- card:c1 -->\n"
        let blocks = NoteBlocks.parse(body)
        #expect(blocks == [.heading(level: 1, inlines: [.text("T")]), .paragraph([.text("hello  world")]), .checklist([.init(checked: false, inlines: [.bold("Pay"), .text(" — rent")], cardID: "c1")])])
        #expect(!NoteBlocks.plain(blocks.flatMap { b -> [I] in if case .paragraph(let i) = b { return i }; return [] }).contains("secret"))
    }

    @Test func statusBlockIsItsOwnBlock() {
        let body = "# Arif\n\n<!-- brownie:status -->\n## Between you\n_Kept by Brownie from the chats and the loops ledger. Not written by the brain._\n- ⏳ 3 Sep — they asked: “lunch?” — no reply yet\n- ✅ 1 Sep — they asked: “call?” — you replied 1 Sep 10:00\n- ⌛ you promised (1 Jul): the book — no news in 90 days; no longer tracked (lapsed 29 Sep)\n<!-- /brownie:status -->\n\nA friend.\n"
        let blocks = NoteBlocks.parse(body)
        #expect(blocks[0] == .heading(level: 1, inlines: [.text("Arif")]))
        #expect(blocks[1] == .status(lines: ["⏳ 3 Sep — they asked: “lunch?” — no reply yet", "✅ 1 Sep — they asked: “call?” — you replied 1 Sep 10:00", "⌛ you promised (1 Jul): the book — no news in 90 days; no longer tracked (lapsed 29 Sep)"]))
        #expect(blocks[2] == .paragraph([.text("A friend.")]))
        #expect(NoteBlocks.openItems(in: body) == 1)
        #expect(NoteBlocks.openItems(in: "# Arif\nno block\n") == 0)
        let legacy = "# Arif\n<!-- brownie:between-you -->\n## Between you\n- ⏳ open\n<!-- /brownie:between-you -->\n"
        #expect(NoteBlocks.parse(legacy).contains(.status(lines: ["⏳ open"])))
    }

    @Test func todayCheckboxesCanBeTicked() {
        let md = "# Today\n- [ ] **Pay** — rent <!-- card:a -->\n    > draft\n- [ ] **Call** — mum <!-- card:b -->\n"
        let ticked = NoteBlocks.setCheckbox(in: md, cardID: "b", checked: true)
        #expect(ticked == "# Today\n- [ ] **Pay** — rent <!-- card:a -->\n    > draft\n- [x] **Call** — mum <!-- card:b -->\n")
        #expect(TodayNote.parse(ticked) == [.init(cardID: "a", checked: false), .init(cardID: "b", checked: true)], "what the phone flow reads is what a tap wrote")
        #expect(NoteBlocks.setCheckbox(in: ticked, cardID: "b", checked: false) == md)
        #expect(NoteBlocks.setCheckbox(in: md, cardID: "zzz", checked: true) == md)
        let blocks = NoteBlocks.parse(md)
        #expect(blocks[1] == .checklist([.init(checked: false, inlines: [.bold("Pay"), .text(" — rent")], cardID: "a")]))
        #expect(blocks[2] == .quote([.text("draft")]))
        #expect(blocks[3] == .checklist([.init(checked: false, inlines: [.bold("Call"), .text(" — mum")], cardID: "b")]))
    }

    @Test func linksResolveByTitleFileNameOrAlias() {
        let meera = Note(relativePath: "People/Meera Iyer.md", title: "Meera Iyer", body: "# Meera Iyer\n", meta: NoteMeta(brownie: "person", aliases: ["Meera", "MI"], created: "", updated: ""), updatedAt: Date())
        let arif = Note(relativePath: "People/Arif.md", title: "Arif Khan", body: "# Arif Khan\n", meta: NoteMeta(brownie: "person", created: "", updated: ""), updatedAt: Date())
        let index = LinkIndex(folders: [KnowledgeFolder(name: "People", notes: [meera, arif])])
        #expect(index.path(for: "meera iyer") == "People/Meera Iyer.md")
        #expect(index.path(for: "Meera") == "People/Meera Iyer.md", "an alias from the front-matter")
        #expect(index.path(for: "Arif") == "People/Arif.md", "the file name")
        #expect(index.path(for: "ARIF KHAN") == "People/Arif.md", "the title, any case")
        #expect(index.path(for: "People/Arif") == "People/Arif.md", "a path-style link")
        #expect(index.path(for: "Ravi") == nil)
    }

    @Test func theMetaLineReadsTheFrontMatterNotTheFile() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_789_560_000)   // 2026-09-16
        let meta = NoteMeta(brownie: "person", sources: ["WhatsApp · Nitesh", "Slack"], created: "2026-09-01", updated: "2026-09-10")
        let n = Note(relativePath: "People/Nitesh.md", title: "Nitesh", body: "# Nitesh\n", meta: meta, updatedAt: now)
        #expect(NoteFacts.metaLine(n, now: now, calendar: cal) == "Updated 10 Sep · sources: WhatsApp · Nitesh, Slack")
        #expect(NoteFacts.quietDays(n, now: now, calendar: cal) == 6)
        var old = meta; old.updated = "2025-03-02"; old.sources = []
        let o = Note(relativePath: "People/Nitesh.md", title: "Nitesh", body: "", meta: old, updatedAt: now)
        #expect(NoteFacts.metaLine(o, now: now, calendar: cal) == "Updated 2 Mar 2025", "another year says so; no sources, no sources part")
        #expect(NoteFacts.quietDays(o, now: now, calendar: cal)! > NoteFacts.quietAfter)
        var none = meta; none.updated = ""; none.sources = []
        let u = Note(relativePath: "Work/Plain.md", title: "Plain", body: "", meta: none, updatedAt: cal.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 12))!)
        #expect(NoteFacts.metaLine(u, now: now, calendar: cal) == "Updated 9 Sep 2026", "no day in the front-matter: the store's date, year and all")
        #expect(NoteFacts.quietDays(u, now: now, calendar: cal) == nil)
    }

    @Test func editingStripsTheBlockAndSavingPutsItBack() async throws {
        let w = try FileKnowledgeStoreTests.world()
        let block = "<!-- brownie:status -->\n## Between you\n_Kept by Brownie from the chats and the loops ledger. Not written by the brain._\n- ⏳ 3 Sep — they asked: “lunch?” — no reply yet\n<!-- /brownie:status -->"
        let body = "# Arif\n\n" + block + "\n\nA friend.\n"
        try w.put("People/Arif.md", FileKnowledgeStoreTests.owned(body, path: "People/Arif.md", extra: "tags: [friend]"))
        let n = try #require(try await w.kb.note(at: "People/Arif.md"))
        let editable = NoteEdit.forEditing(n.body)
        #expect(editable == "# Arif\n\nA friend.\n", "the editor never shows the block")
        #expect(!editable.contains("brownie:"))
        // the user edits the prose; the block comes back exactly, the front-matter (with their tag) stays
        let saved = NoteEdit.reattach(edited: editable.replacingOccurrences(of: "A friend.", with: "A friend from Pune."), original: n.body)
        try await w.kb.save(Note(relativePath: n.relativePath, title: n.title, body: saved, sources: n.sources, updatedAt: FileKnowledgeStoreTests.today, userEdited: true))
        let raw = try #require(w.raw("People/Arif.md"))
        #expect(raw.contains(block), "the block, byte for byte")
        #expect(raw.hasPrefix("---\nbrownie: person\n") && raw.contains("tags: [friend]\n---\n") && raw.contains("created: 2026-09-01\n") && raw.contains("user_edited: true\n"))
        #expect(NoteStatus.extract(from: NoteMeta.parse(raw, path: "People/Arif.md").body) == block)
        #expect(NoteStatus.strip(NoteMeta.parse(raw, path: "People/Arif.md").body) == "# Arif\n\nA friend from Pune.\n")
        // a body that never had a block gets none
        #expect(NoteEdit.reattach(edited: "# Plain\nwords\n", original: "# Plain\nold\n") == "# Plain\nwords\n")
        // pasting the block back into the editor does not double it
        #expect(NoteEdit.reattach(edited: n.body, original: n.body) == n.body)
    }
}
