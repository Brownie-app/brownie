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
}
