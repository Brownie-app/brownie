import Testing
import Foundation
@testable import Support

/// The two folders FINISH tidies outside the store: the log files, which rotate past a size, and the transcript
/// cache, which forgets what nobody has asked for in half a year.
@Suite struct LogRotateTests {
    static func folder() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func write(_ text: String, _ name: String, in dir: URL) throws { try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    static func read(_ name: String, in dir: URL) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }
    static func names(in dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

    @Test func onlyAFileOverTheLimitRotatesAndTheCopiesShiftUpToKeep() throws {
        let dir = try Self.folder()
        try Self.write(String(repeating: "a", count: 200), "store.log", in: dir)
        try Self.write("small", "app.log", in: dir)
        try Self.write("not a log", "notes.txt", in: dir)
        #expect(Log.rotate(in: dir, maxBytes: 100, keep: 2) == ["store"])
        #expect(Self.names(in: dir) == ["app.log", "notes.txt", "store.log.1"], "the big one moved aside; the small one and the stranger stayed")
        #expect(Self.read("store.log.1", in: dir)?.count == 200)

        try Self.write(String(repeating: "b", count: 200), "store.log", in: dir)
        #expect(Log.rotate(in: dir, maxBytes: 100, keep: 2) == ["store"])
        #expect(Self.names(in: dir) == ["app.log", "notes.txt", "store.log.1", "store.log.2"])
        #expect(Self.read("store.log.1", in: dir)?.first == "b" && Self.read("store.log.2", in: dir)?.first == "a", "newest copy is .1")

        try Self.write(String(repeating: "c", count: 200), "store.log", in: dir)
        #expect(Log.rotate(in: dir, maxBytes: 100, keep: 2) == ["store"])
        #expect(Self.names(in: dir) == ["app.log", "notes.txt", "store.log.1", "store.log.2"], "never more than `keep` copies")
        #expect(Self.read("store.log.1", in: dir)?.first == "c" && Self.read("store.log.2", in: dir)?.first == "b", "the oldest copy is the one that went")
    }

    @Test func aFileExactlyAtTheLimitStaysAndAnEmptyOrMissingFolderIsNothing() throws {
        let dir = try Self.folder()
        try Self.write(String(repeating: "a", count: 100), "store.log", in: dir)
        #expect(Log.rotate(in: dir, maxBytes: 100, keep: 2).isEmpty && Self.names(in: dir) == ["store.log"])
        #expect(Log.rotate(in: dir.appendingPathComponent("missing"), maxBytes: 1, keep: 2).isEmpty)
    }

    @Test func keepZeroSimplyDeletesTheBigFile() throws {
        let dir = try Self.folder()
        try Self.write(String(repeating: "a", count: 200), "store.log", in: dir)
        #expect(Log.rotate(in: dir, maxBytes: 100, keep: 0) == ["store"] && Self.names(in: dir).isEmpty)
    }
}

@Suite struct TranscriptCacheTests {
    let now = Date(timeIntervalSince1970: 1_789_560_000)   // 2026-09-16

    static func folder() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("transcripts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func file(_ name: String, in dir: URL, modified: Date) throws {
        let u = dir.appendingPathComponent(name)
        try "{}".write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: u.path)
    }

    @Test func aTranscriptOlderThanKeepDaysGoesAndTheRestStay() throws {
        let dir = try Self.folder()
        try Self.file("old.json", in: dir, modified: now.addingTimeInterval(-181 * 86400))
        try Self.file("edge.json", in: dir, modified: now.addingTimeInterval(-179 * 86400))
        try Self.file("fresh.json", in: dir, modified: now.addingTimeInterval(-3600))
        try Self.file("stranger.txt", in: dir, modified: now.addingTimeInterval(-400 * 86400))
        #expect(TranscriptCache.prune(in: dir, now: now) == 1)
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        #expect(left == ["edge.json", "fresh.json", "stranger.txt"], "only cache files, only the old one")
        #expect(TranscriptCache.prune(in: dir, now: now) == 0, "a second pass finds nothing")
    }

    @Test func aMissingFolderPrunesNothing() throws {
        #expect(TranscriptCache.prune(in: try Self.folder().appendingPathComponent("missing"), now: now) == 0)
    }
}
