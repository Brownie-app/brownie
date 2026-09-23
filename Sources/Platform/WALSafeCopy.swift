import Foundation

/// Reads another app's SQLite database the WAL-safe way: copy the db plus its -wal and -shm to a
/// private temp dir, open the copy read-only, run the body, delete the copy immediately.
/// A plaintext copy of a whole message history must never linger; the live database is never opened.
public enum WALSafeCopy {
    public static func withCopy<T>(of database: URL, _ body: (SQLite) throws -> T) throws -> T {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("brownie-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        let dest = dir.appendingPathComponent(database.lastPathComponent)
        try fm.copyItem(at: database, to: dest)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: database.path + suffix)
            if fm.fileExists(atPath: side.path) { try? fm.copyItem(at: side, to: URL(fileURLWithPath: dest.path + suffix)) }
        }
        let db = try SQLite(path: dest.path, readOnly: true)
        return try body(db)
    }

    /// Full Disk Access probe: can we even stat/read the file?
    public static func isReadable(_ url: URL) -> Bool {
        FileManager.default.isReadableFile(atPath: url.path) && (try? FileHandle(forReadingFrom: url)) != nil
    }
}
