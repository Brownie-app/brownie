import Testing
import Foundation
@testable import Knowledge

/// Two-way vault sync: the phone's words come back, Brownie's night's work goes out, and a real conflict keeps both.
@Suite struct VaultSyncTests {
    let fm = FileManager.default
    func fresh() throws -> (mac: URL, phone: URL) {
        let mac = fm.temporaryDirectory.appendingPathComponent("sync-mac-\(UUID().uuidString)")
        let phone = fm.temporaryDirectory.appendingPathComponent("sync-phone-\(UUID().uuidString)")
        try fm.createDirectory(at: mac.appendingPathComponent("People"), withIntermediateDirectories: true)
        return (mac, phone)
    }
    func put(_ text: String, _ rel: String, in root: URL) throws {
        let u = root.appendingPathComponent(rel)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }
    func read(_ rel: String, in root: URL) -> String? { try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) }

    @Test func firstSyncSendsEverythingToThePhoneAndRecordsTheBase() throws {
        let (mac, phone) = try fresh()
        try put("# Nayan\nfriend", "People/Nayan.md", in: mac)
        try put("index", "index.sqlite", in: mac)
        let r = try Vault.sync(mac, to: phone)
        #expect(r.toPhone == 1 && r.fromPhone == 0 && r.conflicts == 0)
        #expect(read("People/Nayan.md", in: phone) == "# Nayan\nfriend")
        #expect(read("People/Nayan.md", in: mac.appendingPathComponent(".sync")) == "# Nayan\nfriend", "the base copy is what both sides last agreed on")
        #expect(read("index.sqlite", in: phone) == nil, "only notes travel")
        let again = try Vault.sync(mac, to: phone)
        #expect(again.toPhone == 0 && again.fromPhone == 0 && again.conflicts == 0, "nothing changed → nothing moves")
    }

    @Test func phoneOnlyChangeWins() throws {
        let (mac, phone) = try fresh()
        try put("v1", "People/A.md", in: mac)
        _ = try Vault.sync(mac, to: phone)
        try put("v1 + my note from the phone", "People/A.md", in: phone)
        let r = try Vault.sync(mac, to: phone)
        #expect(r.fromPhone == 1 && r.conflicts == 0 && r.toPhone == 0)
        #expect(read("People/A.md", in: mac) == "v1 + my note from the phone")
        #expect(read("People/A.md", in: mac.appendingPathComponent(".sync")) == "v1 + my note from the phone")
    }

    @Test func macOnlyChangeGoesToThePhone() throws {
        let (mac, phone) = try fresh()
        try put("v1", "People/A.md", in: mac)
        _ = try Vault.sync(mac, to: phone)
        try put("v2 written at 3 AM", "People/A.md", in: mac)
        let r = try Vault.sync(mac, to: phone)
        #expect(r.toPhone == 1 && r.fromPhone == 0 && r.conflicts == 0)
        #expect(read("People/A.md", in: phone) == "v2 written at 3 AM")
    }

    @Test func changedOnBothKeepsYourTextOnTopAndBrowniesUnderAHeading() throws {
        let (mac, phone) = try fresh()
        try put("v1", "People/A.md", in: mac)
        _ = try Vault.sync(mac, to: phone)
        try put("mine from the phone", "People/A.md", in: phone)
        try put("Brownie's rewrite", "People/A.md", in: mac)
        let r = try Vault.sync(mac, to: phone, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(r.conflicts == 1 && r.fromPhone == 1)
        let merged = read("People/A.md", in: mac)!
        #expect(merged.hasPrefix("mine from the phone\n\n## Brownie's version ("), "what you wrote stays as the note")
        #expect(merged.hasSuffix("Brownie's rewrite\n"))
        #expect(read("People/A.md", in: phone) == merged, "both sides end up identical")
        #expect(read("People/A.md", in: mac.appendingPathComponent(".sync")) == merged)
        #expect(try Vault.sync(mac, to: phone).conflicts == 0, "a resolved conflict does not come back")
    }

    @Test func newOnThePhoneIsAdded() throws {
        let (mac, phone) = try fresh()
        try put("v1", "People/A.md", in: mac)
        _ = try Vault.sync(mac, to: phone)
        try put("# Idea\nwritten on the train", "Ideas/Train.md", in: phone)
        let r = try Vault.sync(mac, to: phone)
        #expect(r.fromPhone == 1)
        #expect(read("Ideas/Train.md", in: mac) == "# Idea\nwritten on the train")
    }

    @Test func deletedOnThePhoneIsRestoredFromTheMac() throws {
        let (mac, phone) = try fresh()
        try put("v1", "People/A.md", in: mac)
        _ = try Vault.sync(mac, to: phone)
        try fm.removeItem(at: phone.appendingPathComponent("People/A.md"))
        let r = try Vault.sync(mac, to: phone)
        #expect(r.removedOnPhone == 1 && r.toPhone == 1)
        #expect(read("People/A.md", in: phone) == "v1", "the Mac is the truth for deletions")
    }

    @Test func deletedOnTheMacIsTakenOffThePhoneNotCopiedBack() throws {
        let (mac, phone) = try fresh()
        try put("v1", "People/A.md", in: mac)
        try put("keep", "People/B.md", in: mac)
        _ = try Vault.sync(mac, to: phone)
        try fm.removeItem(at: mac.appendingPathComponent("People/A.md"))
        let r = try Vault.sync(mac, to: phone)
        #expect(r.deletedOnMac == 1 && r.fromPhone == 0 && r.toPhone == 0)
        #expect(read("People/A.md", in: mac) == nil, "the note does not come back")
        #expect(read("People/A.md", in: phone) == nil, "and it is gone from the phone")
        #expect(read("People/A.md", in: mac.appendingPathComponent(".sync")) == nil, "its base copy is dropped")
        #expect(read("People/B.md", in: phone) == "keep")
        let again = try Vault.sync(mac, to: phone)
        #expect(again.deletedOnMac == 0 && again.fromPhone == 0 && again.toPhone == 0)
    }

    @Test func goneOnBothSidesDropsTheBase() throws {
        let (mac, phone) = try fresh()
        try put("v1", "People/A.md", in: mac)
        _ = try Vault.sync(mac, to: phone)
        #expect(read("People/A.md", in: mac.appendingPathComponent(".sync")) == "v1")
        try fm.removeItem(at: mac.appendingPathComponent("People/A.md"))
        try fm.removeItem(at: phone.appendingPathComponent("People/A.md"))
        let r = try Vault.sync(mac, to: phone)
        #expect(r.toPhone == 0 && r.fromPhone == 0 && r.deletedOnMac == 0)
        #expect(read("People/A.md", in: mac.appendingPathComponent(".sync")) == nil)
        #expect(read("People/A.md", in: mac) == nil && read("People/A.md", in: phone) == nil, "nothing is resurrected")
    }

    @Test func aReportSavedBeforeDeletedOnMacExistedStillReads() throws {
        let old = #"{"toPhone":1,"fromPhone":2,"conflicts":0,"removedOnPhone":0,"at":0}"#
        let r = try JSONDecoder().decode(SyncReport.self, from: Data(old.utf8))
        #expect(r.toPhone == 1 && r.fromPhone == 2 && r.deletedOnMac == 0)
    }

    @Test func mergeShape() {
        let m = Vault.merge(yours: "yours\n\n", brownies: "\nbrownies", at: Date(timeIntervalSince1970: 0))
        #expect(m.hasPrefix("yours\n\n## Brownie's version ("))
        #expect(m.contains("you edited this note on your phone at the same time"))
        #expect(m.hasSuffix("\n\nbrownies\n"))
    }

    @Test func reportLine() {
        var r = SyncReport(at: Date())
        #expect(r.line == "0 conflicts")
        r.fromPhone = 1; r.conflicts = 1
        #expect(r.line == "1 note came back from your iPhone and was merged · 1 conflict")
        r.fromPhone = 2; r.toPhone = 3; r.conflicts = 0
        #expect(r.line == "2 notes came back from your iPhone and were merged · 3 sent to the phone · 0 conflicts")
    }

    @Test func reportRoundTripsThroughJSON() throws {
        var r = SyncReport(at: Date(timeIntervalSince1970: 1_700_000_000)); r.toPhone = 4; r.conflicts = 2
        let back = try JSONDecoder().decode(SyncReport.self, from: JSONEncoder().encode(r))
        #expect(back == r)
    }
}
