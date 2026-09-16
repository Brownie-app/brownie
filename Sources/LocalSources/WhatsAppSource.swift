import Foundation
import AppKit
import Domain
import Platform
import Support

/// WhatsApp Desktop keeps history in plaintext SQLite in its group container (needs Full Disk
/// Access). One bucket per chat; item = a window; key = last message row id.
public struct WhatsAppSource: Source {
    public static let descriptor = SourceDescriptor(
        id: "whatsapp", name: "WhatsApp", detail: "Reads the desktop app's history · pick chats",
        door: .localDatabase, permissions: [.fullDiskAccess], supportsPerBucketOptIn: true)

    static let bundleID = "net.whatsapp.WhatsApp"
    static var database: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite") }
    public init() {}

    public static var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }

    public func availability() async -> Availability {
        guard Self.isInstalled, FileManager.default.fileExists(atPath: Self.database.path) else { return .notInstalled }
        return WALSafeCopy.isReadable(Self.database) ? .available : .needsPermission(.fullDiskAccess)
    }

    private let log = Log("source.whatsapp")

    /// The members of a group chat — names where WhatsApp has them, else the phone from the JID — for the household's eligibility check.
    public func members(of bucket: BucketID) async throws -> [String] {
        let pk = Int64(bucket.rawValue.dropFirst("whatsapp:".count)) ?? 0
        return try WALSafeCopy.withCopy(of: Self.database) { db in
            try db.query("SELECT ZCONTACTNAME AS n, ZMEMBERJID AS j FROM ZWAGROUPMEMBER WHERE ZCHATSESSION=?", [.int(pk)]).flatMap { r -> [String] in
                let jid = r["j"].text ?? "", phone = String(jid.split(separator: "@").first ?? "")
                return [r["n"].text, phone.isEmpty ? nil : "+" + phone].compactMap { $0 }
            }
        }
    }

    public func discoverBuckets() async throws -> [BucketInfo] {
        try WALSafeCopy.withCopy(of: Self.database) { db in
            do { return try Self.sessions(db) }
            catch {
                let tables = (try? db.query("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'ZWA%'").compactMap { $0["name"].text }) ?? []
                log.warn("WhatsApp schema mismatch (\(error)); tables: \(tables.joined(separator: ", "))")
                for t in ["ZWACHATSESSION", "ZWAMESSAGE", "ZWAGROUPMEMBER"] where tables.contains(t) {
                    let c = (try? db.query("PRAGMA table_info(\(t))").compactMap { $0["name"].text }) ?? []
                    log.warn("  \(t): \(c.joined(separator: ","))")
                }
                throw SourceError.cannotRead("WhatsApp schema mismatch (logged to source.whatsapp.log)")
            }
        }
    }

    static func sessions(_ db: SQLite) throws -> [BucketInfo] {
        return try db.query("""
            SELECT s.Z_PK AS pk, s.ZPARTNERNAME AS name, s.ZCONTACTJID AS jid, s.ZSESSIONTYPE AS type,
                   (SELECT COUNT(*) FROM ZWAMESSAGE m WHERE m.ZCHATSESSION=s.Z_PK AND m.ZTEXT IS NOT NULL) AS n,
                   (SELECT COUNT(*) FROM ZWAGROUPMEMBER g WHERE g.ZCHATSESSION=s.Z_PK) AS members
            FROM ZWACHATSESSION s ORDER BY n DESC
            """).compactMap { r in
                guard let pk = r["pk"].int, let n = r["n"].int, n > 0 else { return nil }
                let jid = r["jid"].text ?? ""
                let isGroup = jid.hasSuffix("@g.us") || (r["type"].int ?? 0) == 1
                let members = Int(r["members"].int ?? 0)
                let phone = isGroup ? "" : String(jid.split(separator: "@").first ?? "")
                return BucketInfo(id: BucketID("whatsapp:\(pk)"), name: r["name"].text ?? "Chat", detail: isGroup ? "Group · \(members) people" : "Direct" + (phone.isEmpty ? "" : " · +\(phone)"), isGroup: isGroup, count: Int(n),
                                  handle: isGroup || phone.isEmpty ? nil : PersonHandle.whatsapp(phoneDigits: phone))
            }
    }

    public func buckets(since marks: [BucketID: ItemKey], enabled: Set<BucketID>?) async throws -> [Bucket] {
        let infos = try await discoverBuckets().filter { enabled?.contains($0.id) ?? false }
        guard !infos.isEmpty else { return [] }
        let now = Date(), policy = FirstRead.current
        return try WALSafeCopy.withCopy(of: Self.database) { db in
            try infos.map { info in
                let pk = Int64(info.id.rawValue.dropFirst("whatsapp:".count)) ?? 0
                // Future-dated rows are dropped inside ChatWindowing.windows; the first-read policy bounds a chat never read to the bottom.
                var msgs = try Self.messages(db, session: pk)
                var deferred = 0
                if marks[info.id] == nil {
                    let cut = ChatWindowing.firstReadSlice(msgs, isGroup: info.isGroup, policy: policy, source: Self.descriptor.id, now: now)
                    msgs = cut.messages; deferred = cut.deferred
                }
                let chat = ChatInfo(id: info.id.rawValue, name: info.name, isGroup: info.isGroup, memberCount: 0)
                // A freshly synced WhatsApp Desktop assigns row ids newest-first, so order and key by DATE, not id.
                let items = ChatWindowing.windows(msgs, chat: chat).map { w in
                    Candidate(source: Self.descriptor.id, bucket: info.id, key: ItemKey(order: w.lastDate.timeIntervalSince1970, tiebreak: String(w.lastRowID)), kind: info.isGroup ? .groupChat : .directMessage,
                              id: "\(info.id.rawValue):\(w.lastRowID)", itemDate: w.lastDate,
                              metadata: ["chat": info.name, "isGroup": info.isGroup ? "1" : "0", "phone": info.detail.split(separator: "+").last.map { String($0) } ?? "", "firstDate": String(w.firstDate.timeIntervalSinceReferenceDate), "lastDate": String(w.lastDate.timeIntervalSinceReferenceDate)])
                }.reversed()
                return Bucket(id: info.id, name: info.name, items: Array(items), deferred: deferred)
            }
        }
    }

    public func load(_ c: Candidate) async throws -> Artifact {
        let pk = Int64(c.bucket.rawValue.dropFirst("whatsapp:".count)) ?? 0
        let first = Double(c.metadata["firstDate"] ?? ""), last = Double(c.metadata["lastDate"] ?? "")
        return try WALSafeCopy.withCopy(of: Self.database) { db in
            let msgs = try Self.messages(db, session: pk, fromDate: first, toDate: last)
            let chat = ChatInfo(id: c.bucket.rawValue, name: c.metadata["chat"] ?? "Chat", isGroup: c.isGroup, memberCount: 0)
            let text = ChatWindowing.windows(msgs, chat: chat).map(\.text).joined(separator: "\n\n")
            return Artifact(candidate: c, text: ChatWindowing.clamp(text))
        }
    }

    static func messages(_ db: SQLite, session: Int64, fromDate: Double? = nil, toDate: Double? = nil) throws -> [ChatMessage] {
        var sql = """
        SELECT m.Z_PK AS id, m.ZTEXT AS t, m.ZMESSAGEDATE AS d, m.ZISFROMME AS me, m.ZFROMJID AS jid,
               (SELECT g.ZCONTACTNAME FROM ZWAGROUPMEMBER g WHERE g.ZMEMBERJID=m.ZFROMJID AND g.ZCHATSESSION=m.ZCHATSESSION LIMIT 1) AS member
        FROM ZWAMESSAGE m WHERE m.ZCHATSESSION=? AND m.ZTEXT IS NOT NULL
        """
        var params: [SQLite.Value] = [.int(session)]
        if let fromDate, let toDate { sql += " AND m.ZMESSAGEDATE BETWEEN ? AND ?"; params += [.real(fromDate), .real(toDate)] }
        sql += " ORDER BY m.ZMESSAGEDATE ASC, m.Z_PK ASC"
        return try db.query(sql, params).compactMap { r in
            guard let id = r["id"].int, let t = r["t"].text, !t.isEmpty else { return nil }
            let me = (r["me"].int ?? 0) == 1
            let sender = me ? "Me" : (r["member"].text ?? (r["jid"].text.map { String($0.split(separator: "@").first ?? "?") } ?? "?"))
            return ChatMessage(rowID: id, date: AppleDates.fromReference(r["d"].real ?? 0), sender: sender, isMe: me, text: t)
        }
    }
}
