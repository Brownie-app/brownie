import Testing
import Foundation
@testable import Knowledge

@Suite struct VaultTests {
    @Test func testMirrorCopiesChangedAndRemovesDeleted() throws {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("v-src-\(UUID().uuidString)")
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("v-dst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("People"), withIntermediateDirectories: true)
        try "a".write(to: src.appendingPathComponent("People/A.md"), atomically: true, encoding: .utf8)
        try "b".write(to: src.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)
        try "not markdown".write(to: src.appendingPathComponent("index.sqlite"), atomically: true, encoding: .utf8)
        #expect(try Vault.mirror(src, to: dst) == 2)
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("People/A.md").path))
        #expect(!(FileManager.default.fileExists(atPath: dst.appendingPathComponent("index.sqlite").path)), "only notes are mirrored")
        #expect(try Vault.mirror(src, to: dst) == 0, "nothing changed → nothing copied")
        try FileManager.default.removeItem(at: src.appendingPathComponent("B.md"))
        _ = try Vault.mirror(src, to: dst)
        #expect(!(FileManager.default.fileExists(atPath: dst.appendingPathComponent("B.md").path)), "deleted on the Mac → gone from the mirror")
    }
}
