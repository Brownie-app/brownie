import Testing
import Foundation
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
}
