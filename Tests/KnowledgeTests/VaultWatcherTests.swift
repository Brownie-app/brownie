import Testing
import Foundation
@testable import Knowledge

/// The Notes screen learns of a note changed on disk: one call per burst of changes, hidden folders ignored.
@Suite struct VaultWatcherTests {
    actor Box { var bursts: [[String]] = []; func add(_ p: [String]) { bursts.append(p) } }
    func temp() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("vw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u.appendingPathComponent("People"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: u.appendingPathComponent(".sync/People"), withIntermediateDirectories: true)
        return u
    }

    @Test func firesOncePerChangeAndNeverForHiddenFolders() async throws {
        let d = try temp()
        try "# Arif\nold\n".write(to: d.appendingPathComponent("People/Arif.md"), atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 1_200_000_000)   // FSEvents may still hand over a write from the last moment before the watch began
        let w = VaultWatcher(), box = Box()
        w.start(d, settle: 0.4) { paths in Task { await box.add(paths) } }
        try await Task.sleep(nanoseconds: 500_000_000)
        try "# Arif\nnew\n".write(to: d.appendingPathComponent("People/Arif.md"), atomically: true, encoding: .utf8)   // Obsidian's save
        try await Task.sleep(nanoseconds: 2_500_000_000)
        var got = await box.bursts
        #expect(got.count == 1, "one save, one reload: \(got)")
        #expect(got.first?.map { ($0 as NSString).lastPathComponent } == ["Arif.md"])
        try "base".write(to: d.appendingPathComponent(".sync/People/Arif.md"), atomically: true, encoding: .utf8)   // the sync's base copy
        try "junk".write(to: d.appendingPathComponent("People/notes.txt"), atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        got = await box.bursts
        #expect(got.count == 1, "hidden folders and non-Markdown never count")
        w.stop()
    }

    @Test func mattersIsTheRule() {
        #expect(VaultWatcher.matters("/v/People/Arif.md", root: "/v"))
        #expect(!VaultWatcher.matters("/v/.sync/People/Arif.md", root: "/v"))
        #expect(!VaultWatcher.matters("/v/.brownie/people.json", root: "/v"))
        #expect(!VaultWatcher.matters("/v/People/a.txt", root: "/v"))
        #expect(!VaultWatcher.matters("/elsewhere/People/Arif.md", root: "/v"))
        #expect(!VaultWatcher.matters("/v2/People/Arif.md", root: "/v"), "a sibling folder with the same prefix is not the vault")
        #expect(VaultWatcher.matters("/private/var/x/People/Arif.md", root: "/var/x"), "FSEvents says /private/var; Foundation says /var")
    }
}
