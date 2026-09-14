import Foundation
import Domain
import Platform
import Support

/// Apple Notes: `NoteStore.sqlite` in the Notes group container (needs Full Disk Access).
/// Bodies are gzip-compressed protobuf; we extract plain text. Keyed by creation date, so an edit
/// does not re-trigger a read (v1 trade-off).
public struct NotesSource: Source {
    public static let descriptor = SourceDescriptor(
        id: "notes", name: "Apple Notes", detail: "Every note you write · needs Full Disk Access",
        door: .localDatabase, permissions: [.fullDiskAccess])

    static var database: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite") }
    static let bucket = BucketID("notes")
    private let log = Log("source.notes")
    public init() {}

    public func availability() async -> Availability {
        guard FileManager.default.fileExists(atPath: Self.database.path) else { return .notInstalled }
        return WALSafeCopy.isReadable(Self.database) ? .available : .needsPermission(.fullDiskAccess)
    }

    /// Notes' Core Data table and column names vary by macOS version (ZTITLE vs ZTITLE1, etc.).
    /// Discover them once per open instead of hard-coding.
    struct Schema { let table: String; let title: String; let ident: String; let created: String; let modified: String; let noteData: String; let folder: String?; let deleted: String? }
    static func schema(_ db: SQLite) throws -> Schema {
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"].text }
        guard let table = ["ZICCLOUDSYNCINGOBJECT", "ZICCLOUDSTATEOBJECT"].first(where: tables.contains) else { throw SourceError.cannotRead("unknown Notes schema: \(tables.filter { $0.hasPrefix("ZIC") }.joined(separator: ","))") }
        let cols = try db.query("PRAGMA table_info(\(table))").compactMap { $0["name"].text }
        // Several columns share a prefix (ZTITLE, ZTITLE1, …) across entities; take the one with the most data.
        func pick(_ prefix: String) -> String? {
            let cands = cols.filter { $0 == prefix || ($0.hasPrefix(prefix) && $0.dropFirst(prefix.count).allSatisfy(\.isNumber)) }
            return cands.max { a, b in
                let na = (try? db.query("SELECT COUNT(*) AS n FROM \(table) WHERE \(a) IS NOT NULL").first?["n"].int) ?? 0
                let nb = (try? db.query("SELECT COUNT(*) AS n FROM \(table) WHERE \(b) IS NOT NULL").first?["n"].int) ?? 0
                return na < nb
            }
        }
        guard let title = pick("ZTITLE"), let ident = pick("ZIDENTIFIER"), let created = pick("ZCREATIONDATE"), let modified = pick("ZMODIFICATIONDATE"), let noteData = pick("ZNOTEDATA") else {
            throw SourceError.cannotRead("Notes columns not recognised: \(cols.prefix(40).joined(separator: ","))")
        }
        return Schema(table: table, title: title, ident: ident, created: created, modified: modified, noteData: noteData, folder: pick("ZFOLDER"), deleted: pick("ZMARKEDFORDELETION"))
    }

    public func buckets(since marks: [BucketID: ItemKey], enabled: Set<BucketID>?) async throws -> [Bucket] {
        let items = try WALSafeCopy.withCopy(of: Self.database) { db in
            let sc = try Self.schema(db)
            let folderJoin = sc.folder.map { "LEFT JOIN \(sc.table) f ON f.Z_PK=n.\($0)" } ?? ""
            let folderCol = sc.folder != nil ? "f.\(sc.title) AS folder," : "NULL AS folder,"
            let notDeleted = sc.deleted.map { "AND COALESCE(n.\($0),0)=0" } ?? ""
            return try db.query("""
            SELECT n.Z_PK AS pk, n.\(sc.ident) AS uuid, n.\(sc.title) AS title, n.\(sc.created) AS created, n.\(sc.modified) AS modified, \(folderCol) 1 AS one
            FROM \(sc.table) n \(folderJoin)
            WHERE n.\(sc.noteData) IS NOT NULL \(notDeleted) ORDER BY n.\(sc.created) DESC
            """).compactMap { r -> Candidate? in
                guard let uuid = r["uuid"].text, let created = r["created"].real else { return nil }
                let date = AppleDates.fromReference(created)
                return Candidate(source: Self.descriptor.id, bucket: Self.bucket, key: ItemKey(order: created, tiebreak: "notes:\(uuid)"),
                                 kind: .document, id: uuid, itemDate: date,
                                 metadata: ["name": r["title"].text ?? "Untitled", "displayPath": "Notes/\(r["folder"].text ?? "Notes")/\(r["title"].text ?? "Untitled")",
                                            "created": ISO8601DateFormatter().string(from: date), "pk": String(r["pk"].int ?? 0)])
            }
        }
        if items.isEmpty {
            let diag = try WALSafeCopy.withCopy(of: Self.database) { db -> String in
                let sc = try Self.schema(db)
                let total = try db.query("SELECT COUNT(*) AS n FROM \(sc.table)").first?["n"].int ?? 0
                let withData = try db.query("SELECT COUNT(*) AS n FROM \(sc.table) WHERE \(sc.noteData) IS NOT NULL").first?["n"].int ?? 0
                let withTitle = try db.query("SELECT COUNT(*) AS n FROM \(sc.table) WHERE \(sc.title) IS NOT NULL").first?["n"].int ?? 0
                let ents = try db.query("SELECT Z_ENT AS e, COUNT(*) AS n FROM \(sc.table) GROUP BY Z_ENT ORDER BY n DESC LIMIT 8").map { "\($0["e"].int ?? 0):\($0["n"].int ?? 0)" }
                let noteDataRows = try db.query("SELECT COUNT(*) AS n FROM ZICNOTEDATA").first?["n"].int ?? 0
                return "table \(sc.table) rows=\(total) withNoteData(\(sc.noteData))=\(withData) withTitle(\(sc.title))=\(withTitle) ents=\(ents) ZICNOTEDATA rows=\(noteDataRows) cols: title=\(sc.title) ident=\(sc.ident) created=\(sc.created)"
            }
            log.warn("0 notes listed — \(diag)")
        } else { log.info("\(items.count) notes listed") }
        return [Bucket(id: Self.bucket, name: "Apple Notes", items: items)]
    }

    public func load(_ c: Candidate) async throws -> Artifact {
        let text = try WALSafeCopy.withCopy(of: Self.database) { db -> String? in
            let sc = try Self.schema(db)
            let rows = try db.query("SELECT d.ZDATA AS data FROM ZICNOTEDATA d JOIN \(sc.table) n ON n.\(sc.noteData)=d.Z_PK WHERE n.\(sc.ident)=?", [.text(c.id)])
            guard let blob = rows.first?["data"].blob else { return nil }
            return NoteBody.text(fromGzippedProtobuf: blob)
        }
        return Artifact(candidate: c, text: text.map { String($0.prefix(24_000)) })
    }
}

enum NoteBody {
    static func text(fromGzippedProtobuf gz: Data) -> String? {
        guard let raw = gunzip(gz) else { return nil }
        return Protobuf.longestString(in: raw, depth: 4)
    }

    /// gzip = 10-byte header (+ optional fields) + raw deflate + 8-byte trailer.
    static func gunzip(_ d: Data) -> Data? {
        guard d.count > 18, d[d.startIndex] == 0x1f, d[d.startIndex + 1] == 0x8b else { return nil }
        let flags = d[d.startIndex + 3]
        var i = 10
        if flags & 0x04 != 0 { let xlen = Int(d[d.startIndex + i]) | Int(d[d.startIndex + i + 1]) << 8; i += 2 + xlen }
        if flags & 0x08 != 0 { while i < d.count, d[d.startIndex + i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < d.count, d[d.startIndex + i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        guard i < d.count - 8 else { return nil }
        let body = d.subdata(in: (d.startIndex + i)..<(d.endIndex - 8))
        return try? (body as NSData).decompressed(using: .zlib) as Data
    }
}

/// Minimal protobuf walker: finds the longest human-text string field at any nesting depth.
enum Protobuf {
    static func longestString(in data: Data, depth: Int) -> String? {
        var best: String?
        walk([UInt8](data), depth: depth) { s in if s.count > (best?.count ?? 0) { best = s } }
        return best
    }

    private static func walk(_ b: [UInt8], depth: Int, _ visit: (String) -> Void) {
        var i = 0
        while i < b.count {
            guard let (tag, n1) = varint(b, i) else { return }; i += n1
            let wire = tag & 7
            switch wire {
            case 0: guard let (_, n) = varint(b, i) else { return }; i += n
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let (len, n2) = varint(b, i) else { return }; i += n2
                let end = i + Int(len); guard end <= b.count, len >= 0 else { return }
                let slice = Array(b[i..<end])
                if let s = String(bytes: slice, encoding: .utf8), isText(s) { visit(s) }
                else if depth > 0 { walk(slice, depth: depth - 1, visit) }
                i = end
            default: return
            }
        }
    }

    private static func isText(_ s: String) -> Bool {
        guard s.count >= 2 else { return false }
        let printable = s.unicodeScalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\t" }.count
        return Double(printable) / Double(s.unicodeScalars.count) > 0.95
    }

    private static func varint(_ b: [UInt8], _ start: Int) -> (UInt64, Int)? {
        var v: UInt64 = 0; var shift: UInt64 = 0; var i = start
        while i < b.count, shift < 64 {
            v |= UInt64(b[i] & 0x7f) << shift
            if b[i] & 0x80 == 0 { return (v, i - start + 1) }
            shift += 7; i += 1
        }
        return nil
    }
}
