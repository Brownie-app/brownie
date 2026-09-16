import Testing
import Foundation
@testable import Domain

/// The code-owned front-matter: what it keeps, what it drops, and the hash that decides `updated` and `user_edited`.
@Suite struct NoteMetaTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let block = """
    <!-- brownie:status -->
    ## Between you
    - ⏳ 3 Sep — they asked: “lunch?” — no reply yet
    <!-- /brownie:status -->
    """

    @Test func roundTripKeepsUnknownKeysVerbatimAndInOrder() throws {
        let raw = """
        ---
        brownie: person
        id: p-1
        aliases: [Kanika Pandey Loadmill, "Pandey, Kanika"]
        sources: [whatsapp, gmail]
        created: 2026-09-01
        updated: 2026-09-10
        user_edited: false
        content_hash: abc
        tags:
          - friend
          - work
        cssclass: wide
        ---
        # Kanika Pandey

        A friend.

        """
        let (meta, body) = NoteMeta.parse(raw, path: "People/Kanika Pandey.md")
        let m = try #require(meta)
        #expect(m.brownie == "person" && m.id == "p-1" && m.created == "2026-09-01" && m.updated == "2026-09-10" && m.contentHash == "abc" && !m.userEdited)
        #expect(m.aliases == ["Kanika Pandey Loadmill", "Pandey, Kanika"] && m.sources == ["whatsapp", "gmail"])
        #expect(m.extraOrder == ["tags", "cssclass"], "the user's keys, in the order they wrote them")
        #expect(m.extra["tags"] == "\n  - friend\n  - work" && m.extra["cssclass"] == " wide")
        #expect(body == "# Kanika Pandey\n\nA friend.\n")
        let again = m.render() + body
        #expect(again == raw, "rendered back byte for byte")
        #expect(NoteMeta.parse(again, path: "People/Kanika Pandey.md").meta == m)
    }

    @Test func noFrontMatterIsNilAndALegacyBlockLosesItsTimestamp() throws {
        #expect(NoteMeta.parse("# A\nplain", path: "People/A.md").meta == nil)
        #expect(NoteMeta.parse("# A\nplain", path: "People/A.md").body == "# A\nplain")
        let legacy = "---\nsources: whatsapp, files\nupdated: 2026-09-10T03:00:00Z\nuser_edited: true\n---\n# A\n"
        let m = try #require(NoteMeta.parse(legacy, path: "Work/A.md").meta)
        #expect(m.brownie == "topic" && m.sources == ["whatsapp", "files"] && m.userEdited && m.created.isEmpty && m.updated.isEmpty && m.contentHash.isEmpty)
        #expect(m.extra.isEmpty, "the old keys are Brownie's, not the user's")
    }

    @Test func kindComesFromTheFolder() {
        #expect(NoteMeta.kind(forPath: "People/A.md") == "person" && NoteMeta.kind(forPath: "Groups/G.md") == "group")
        #expect(NoteMeta.kind(forPath: "README.md") == "portrait" && NoteMeta.kind(forPath: "Work/Loadmill.md") == "topic" && NoteMeta.kind(forPath: "Ideas.md") == "topic")
    }

    @Test func hashIgnoresTheStatusBlockAndTrailingWhitespace() {
        let plain = "# Arif\n\nArif is a friend.\n"
        let withBlock = NoteStatus.insert(Self.block, into: plain)
        #expect(withBlock.contains("<!-- brownie:status -->") && withBlock.hasPrefix("# Arif\n\n<!-- brownie:status -->"))
        #expect(NoteMeta.hash(withBlock) == NoteMeta.hash(plain), "the block coming and going changes nothing")
        #expect(NoteMeta.hash(plain + "\n\n") == NoteMeta.hash(plain))
        #expect(NoteMeta.hash("# Arif\n\nArif is a colleague.\n") != NoteMeta.hash(plain))
        let legacy = plain.replacingOccurrences(of: "# Arif\n", with: "# Arif\n\n<!-- brownie:between-you -->\nold\n<!-- /brownie:between-you -->\n")
        #expect(NoteMeta.hash(legacy) == NoteMeta.hash(plain), "the old markers are stripped too")
    }

    @Test func bodyDiffersOnlyWhenAHashIsOnRecord() {
        var m = NoteMeta.fresh(path: "People/A.md", body: "# A\nx", today: "2026-09-16")
        #expect(!m.bodyDiffers("# A\nx") && m.bodyDiffers("# A\ny"))
        m.contentHash = ""
        #expect(!m.bodyDiffers("# A\ny"), "no hash yet means nothing is known, not that the user edited")
    }

    @Test func restampMovesTheHashWithACodeRewriteButKeepsAnEditVisible() throws {
        let meta = NoteMeta.fresh(path: "Work/Plan.md", body: "# Plan\n\nwith [[Arjun]].\n", today: "2026-09-01")
        let raw = meta.render() + "# Plan\n\nwith [[Arjun]].\n"
        #expect(NoteMeta.restamp(raw, path: "Work/Plan.md") { _ in nil } == nil, "nothing to change, nothing written")
        let renamed = try #require(NoteMeta.restamp(raw, path: "Work/Plan.md") { $0.replacingOccurrences(of: "[[Arjun]]", with: "[[Arjun Mehta]]") })
        let (m, body) = NoteMeta.parse(renamed, path: "Work/Plan.md")
        #expect(body == "# Plan\n\nwith [[Arjun Mehta]].\n")
        #expect(m?.contentHash == NoteMeta.hash(body) && m?.bodyDiffers(body) == false, "the rename is code's, not an edit")
        #expect(m?.updated == "2026-09-01" && m?.created == "2026-09-01", "the substance did not change, so the day does not move")
        // A body the user had already touched keeps the stale hash, so the next read still sees their edit.
        let edited = meta.render() + "# Plan\n\nwith [[Arjun]], edited by hand.\n"
        let both = try #require(NoteMeta.restamp(edited, path: "Work/Plan.md") { $0.replacingOccurrences(of: "[[Arjun]]", with: "[[Arjun Mehta]]") })
        let (m2, body2) = NoteMeta.parse(both, path: "Work/Plan.md")
        #expect(body2.contains("[[Arjun Mehta]], edited by hand") && m2?.bodyDiffers(body2) == true)
        #expect(NoteMeta.restamp("# bare\n[[Arjun]]\n", path: "Work/Bare.md") { $0.replacingOccurrences(of: "Arjun", with: "A") } == "# bare\n[[A]]\n", "no front-matter, no block invented")
    }

    @Test func statusBlockStripAndInsertRoundTrip() {
        let body = "# Arif\n\n" + Self.block + "\n\nArif is a friend.\n"
        #expect(NoteStatus.extract(from: body) == Self.block)
        let stripped = NoteStatus.strip(body)
        #expect(stripped == "# Arif\n\nArif is a friend.\n")
        #expect(NoteStatus.insert(Self.block, into: stripped) == body, "put back where it was, byte for byte")
        #expect(NoteStatus.insert(Self.block, into: "no title\n") == Self.block + "\n\nno title\n")
        #expect(NoteStatus.strip("# A\nnothing here\n") == "# A\nnothing here\n")
    }

    @Test func daysAreISOInTheGivenZone() throws {
        let d = Date(timeIntervalSince1970: 1_789_560_000)   // 2026-09-16 12:00 UTC
        #expect(NoteMeta.day(d, Self.utc) == "2026-09-16")
        #expect(NoteMeta.day(d, TimeZone(identifier: "Pacific/Kiritimati")!) == "2026-09-17")
        #expect(NoteMeta.date("2026-09-16", Self.utc) == Date(timeIntervalSince1970: 1_789_516_800))
        #expect(NoteMeta.date("", Self.utc) == nil && NoteMeta.date("2026-09-10T03:00:00Z", Self.utc) == nil)
    }

    @Test func renderQuotesWhatWouldBreakTheList() {
        let m = NoteMeta(brownie: "person", aliases: ["Pandey, Kanika", "plain"], created: "2026-09-01", updated: "2026-09-01")
        #expect(m.render().contains("aliases: [\"Pandey, Kanika\", plain]"))
        #expect(NoteMeta.parse(m.render() + "# x", path: "People/x.md").meta?.aliases == ["Pandey, Kanika", "plain"])
    }

    /// A note the brain wrote with no blank line under its title used to come back from insert-then-strip with one,
    /// and that blank line was read as the user's edit for good.
    @Test func insertAndStripAreInversesWhetherOrNotTheTitleHasABlankLineUnderIt() {
        for body in ["# Arif\nArif is a friend.\n", "# Arif\n\nArif is a friend.\n", "# Arif\n", "# Arif", "no title\n\nprose\n", ""] {
            let with = NoteStatus.insert(Self.block, into: body)
            #expect(NoteStatus.strip(with) == body, "strip undoes insert for \(body.debugDescription)")
            #expect(NoteStatus.upsert("", into: with) == body && NoteStatus.upsert(Self.block, into: body) == with)
            #expect(NoteMeta.hash(with) == NoteMeta.hash(body) && !NoteMeta.fresh(path: "People/Arif.md", body: body, today: "2026-09-16").bodyDiffers(with))
        }
        #expect(NoteStatus.insert(Self.block, into: "# Arif\nArif is a friend.\n") == "# Arif\n\n" + Self.block + "\nArif is a friend.\n", "the block still sits under a blank line")
        #expect(NoteMeta.hash("# Arif\nArif is a friend.\n") == NoteMeta.hash("# Arif\n\n\nArif is a friend.\n"), "a blank line more or less is never an edit")
        #expect(NoteMeta.hash("# Arif\nArif is a friend.\n") != NoteMeta.hash("# Arif\nArif is a colleague.\n"))
        let replaced = NoteStatus.upsert(Self.block.replacingOccurrences(of: "lunch", with: "dinner"), into: "# Arif\n\n" + Self.block + "\n\nprose\n")
        #expect(replaced == "# Arif\n\n" + Self.block.replacingOccurrences(of: "lunch", with: "dinner") + "\n\nprose\n", "replaced in place, the lines around it untouched")
    }

    /// The brain opens and separates sections with horizontal rules; a rule at the top of a note is not a fence.
    @Test func aBodyThatOpensWithARuleIsBodyAndRoundTrips() throws {
        let prose = "---\n# Kanika\n\nA friend.\n\n---\n\nMore.\n"
        let bare = NoteMeta.parse(prose, path: "People/Kanika.md")
        #expect(bare.meta == nil && bare.body == prose, "nothing between those rules is a key, so nothing is front-matter")
        let stamped = NoteMeta.fresh(path: "People/Kanika.md", body: prose, today: "2026-09-16").render() + prose
        let (m, body) = NoteMeta.parse(stamped, path: "People/Kanika.md")
        #expect(m?.created == "2026-09-16" && body == prose, "with Brownie's block in front, the block closes at its own fence and the rules stay body")
        #expect(NoteMeta.parse("---\n\n---\nbody\n", path: "Work/A.md").meta == nil, "a fence with no key is not front-matter")
        #expect(NoteMeta.parse("---\n- a list\n---\nbody\n", path: "Work/A.md").meta == nil)
        #expect(NoteMeta.parse("---\nsee http://x.y\n---\nbody\n", path: "Work/A.md").meta == nil, "a colon inside prose does not make a key")
        let legit = NoteMeta.parse("---\ntags: [a]\ndue date: 2026-09-20\nnote:\n---\nbody\n", path: "Work/A.md")
        #expect(legit.meta?.extraOrder == ["tags", "due date", "note"] && legit.body == "body\n", "keys with spaces and empty values are still keys")
    }

    /// A file written on Windows or by a sync (CRLF, a BOM) or a properties-only note ending at its closing fence is still one with front-matter.
    @Test func aBOMCRLFOrAFenceAtTheEndOfTheFileIsStillFrontMatter() throws {
        let crlf = "\u{FEFF}---\r\ntags: [a]\r\nnotes:\r\n  - one\r\n---\r\n# T\r\n\r\nline\r\n"
        let (m, body) = NoteMeta.parse(crlf, path: "Work/T.md")
        let meta = try #require(m)
        #expect(meta.extra["tags"] == " [a]" && meta.extra["notes"] == "\n  - one" && meta.extraOrder == ["tags", "notes"])
        #expect(body == "# T\n\nline\n", "the body comes back with \\n endings, which is what goes back to disk")
        #expect(!(meta.render() + body).contains("\r") && !(meta.render() + body).contains("\u{FEFF}"))
        let atEnd = NoteMeta.parse("---\ntags: [x]\n---", path: "Work/P.md")
        #expect(atEnd.meta?.extra["tags"] == " [x]" && atEnd.body == "", "a closing fence with nothing after it still closes")
        #expect(NoteMeta.parse("# plain\r\ntext\r\n", path: "Work/P.md").body == "# plain\ntext\n", "no front-matter: the endings are still normalised")
        #expect(NoteMeta.parse("---\r\ntags: [x]\r\n---", path: "Work/P.md").meta?.extra["tags"] == " [x]")
    }

    /// YAML comments and blank lines in the user's block are theirs; a rewrite puts them back where they were, and a comment never becomes a key.
    @Test func commentAndBlankLinesInTheUsersBlockComeBackVerbatim() throws {
        let raw = """
        ---
        brownie: topic
        aliases: []
        sources: []
        created: 2026-09-01
        # stamped by hand
        updated: 2026-09-10
        user_edited: false
        content_hash: abc
        tags: [friend]
        # reviewed with Kanika

        cssclass: wide
        # note: remember this
        ---
        # T
        """
        let (m, body) = NoteMeta.parse(raw, path: "Work/T.md")
        let meta = try #require(m)
        #expect(meta.extraOrder == ["tags", "cssclass"] && meta.extra["cssclass"] == " wide", "a comment with a colon in it is not a key")
        #expect(meta.comments == ["created": "# stamped by hand", "tags": "# reviewed with Kanika\n", "cssclass": "# note: remember this"])
        #expect(meta.render() + body == raw, "byte for byte")
        // a comment above the first key, and one between the items of a list value, stay where they were too
        let user = "---\n# my properties\ntags:\n  - a\n  # the second\n\n  - b\n---\n# T\n"
        let (u, ubody) = NoteMeta.parse(user, path: "Work/U.md")
        let um = try #require(u)
        #expect(um.comments[""] == "# my properties" && um.extra["tags"] == "\n  - a\n  # the second\n\n  - b" && ubody == "# T\n")
        #expect(um.render().hasPrefix("---\n# my properties\nbrownie: topic\n") && um.render().hasSuffix("tags:\n  - a\n  # the second\n\n  - b\n---\n"))
        #expect(NoteMeta.parse(um.render() + ubody, path: "Work/U.md").meta == um, "and survive a second pass unchanged")
    }
}
