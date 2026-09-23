import Testing
import Foundation
import Domain
@testable import Knowledge

/// Only Household/ and the shared groups' notes cross to the shared folder; People/ never does.
@Suite struct HouseholdVaultTests {
    @Test func whatCrosses() {
        let shared: Set<String> = ["Groups/Upreti Family.md"]
        #expect(HouseholdVault.isShared("Household/Amma's 70th.md", sharedGroupNotes: shared))
        #expect(HouseholdVault.isShared("Groups/Upreti Family.md", sharedGroupNotes: shared))
        #expect(!HouseholdVault.isShared("Groups/Founders.md", sharedGroupNotes: shared))
        #expect(!HouseholdVault.isShared("People/Kanika Pandey.md", sharedGroupNotes: shared))
        #expect(!HouseholdVault.isShared("README.md", sharedGroupNotes: shared))
    }

    @Test func syncMovesOnlySharedNotesBothWaysWithItsOwnBase() throws {
        let fm = FileManager.default
        let mac = fm.temporaryDirectory.appendingPathComponent("hv-mac-\(UUID().uuidString)"), shared = fm.temporaryDirectory.appendingPathComponent("hv-shared-\(UUID().uuidString)")
        func put(_ t: String, _ rel: String, in root: URL) throws { let u = root.appendingPathComponent(rel); try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true); try t.write(to: u, atomically: true, encoding: .utf8) }
        func read(_ rel: String, in root: URL) -> String? { try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) }
        try put("plan", "Household/Amma's 70th.md", in: mac)
        try put("family chat", "Groups/Upreti Family.md", in: mac)
        try put("private", "People/Kanika.md", in: mac)
        try put("work", "Groups/Founders.md", in: mac)
        try put("from priya's mac", "Household/The plumber.md", in: shared)
        let r = try HouseholdVault.sync(mac, to: shared, sharedGroupNotes: ["Groups/Upreti Family.md"])
        #expect(r.toPhone == 2 && r.fromPhone == 1 && r.conflicts == 0)
        #expect(read("Household/Amma's 70th.md", in: shared) == "plan" && read("Groups/Upreti Family.md", in: shared) == "family chat")
        #expect(read("People/Kanika.md", in: shared) == nil && read("Groups/Founders.md", in: shared) == nil, "never")
        #expect(read("Household/The plumber.md", in: mac) == "from priya's mac", "hers came home")
        #expect(fm.fileExists(atPath: mac.appendingPathComponent(".household-sync/Household/Amma's 70th.md").path), "its own base copies, apart from the phone sync's")
        #expect(!fm.fileExists(atPath: mac.appendingPathComponent(".sync").path))
        // an edit on her Mac comes back; a conflict keeps both
        try put("plan — Priya: cake ordered", "Household/Amma's 70th.md", in: shared)
        try put("plan — table booked", "Household/Amma's 70th.md", in: mac)
        let r2 = try HouseholdVault.sync(mac, to: shared, sharedGroupNotes: ["Groups/Upreti Family.md"])
        #expect(r2.conflicts == 1 && read("Household/Amma's 70th.md", in: mac)!.contains("## Brownie's version"))
    }

    /// Each member's Brownie stamps its own front-matter on its own copy (its own `created`, its own hash). Two blocks
    /// over the same words are one note, not a conflict; what comes home keeps this Mac's block; and a real merge is
    /// of bodies, so no `---` block ever lands in the middle of a note.
    @Test func twoMacsThatEachStampTheirOwnFrontMatterDoNotConflict() throws {
        let fm = FileManager.default
        let mac = fm.temporaryDirectory.appendingPathComponent("hv-b-\(UUID().uuidString)"), shared = fm.temporaryDirectory.appendingPathComponent("hv-shared-\(UUID().uuidString)")
        func put(_ t: String, _ rel: String, in root: URL) throws { let u = root.appendingPathComponent(rel); try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true); try t.write(to: u, atomically: true, encoding: .utf8) }
        func read(_ rel: String, in root: URL) -> String? { try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) }
        let rel = "Household/Groceries.md", body = "# Groceries\n\n- milk\n"
        let a = NoteMeta.fresh(path: rel, body: body, today: "2026-09-10"), b = NoteMeta.fresh(path: rel, body: body, today: "2026-09-14")
        try put(body, rel, in: mac.appendingPathComponent(".household-sync"))   // last agreed on, before either Mac stamped
        try put(b.render() + body, rel, in: mac)                                 // B's launch stamped B's copy
        try put(a.render() + body, rel, in: shared)                              // A's launch stamped A's, and A's night sent it
        let now = Date(timeIntervalSince1970: 1_789_560_000)
        let r = try HouseholdVault.sync(mac, to: shared, sharedGroupNotes: [], now: now)
        #expect(r.conflicts == 0 && r.fromPhone == 0 && r.toPhone == 0, "the same words under two blocks is nothing to merge")
        #expect(read(rel, in: mac) == b.render() + body, "B keeps its own block")
        // A adds a line: it comes home under B's block, not A's
        try put(a.render() + body + "- eggs\n", rel, in: shared)
        let r2 = try HouseholdVault.sync(mac, to: shared, sharedGroupNotes: [], now: now)
        #expect(r2.fromPhone == 1 && r2.conflicts == 0 && read(rel, in: mac) == b.render() + body + "- eggs\n")
        // both add a line: a merge of the bodies, under B's block, with no second block in the note
        try put(a.render() + body + "- eggs\n- bread\n", rel, in: shared)
        try put(b.render() + body + "- eggs\n- rice\n", rel, in: mac)
        let r3 = try HouseholdVault.sync(mac, to: shared, sharedGroupNotes: [], now: now)
        let merged = try #require(read(rel, in: mac))
        let (m, mbody) = NoteMeta.parse(merged, path: rel)
        #expect(r3.conflicts == 1 && m?.created == "2026-09-14" && mbody.contains("## Brownie's version") && mbody.contains("- bread") && mbody.contains("- rice"))
        #expect(!mbody.contains("---\nbrownie:") && read(rel, in: shared) == merged)
    }
}
