import Foundation
import Contacts
import Domain
import Platform
import Support

/// Reads `~/Library/Messages/chat.db` (needs Full Disk Access). One bucket per chat; item = a window.
public struct iMessageSource: Source {
    public static let descriptor = SourceDescriptor(
        id: "imessage", name: "iMessage", detail: "Pick chats · needs Full Disk Access",
        door: .localDatabase, permissions: [.fullDiskAccess, .contacts], supportsPerBucketOptIn: true)

    static var database: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db") }
    private let log = Log("source.imessage")
    public init() {}

    public func availability() async -> Availability {
        guard FileManager.default.fileExists(atPath: Self.database.path) else { return .notInstalled }
        return WALSafeCopy.isReadable(Self.database) ? .available : .needsPermission(.fullDiskAccess)
    }

    /// The handles (numbers, addresses) and their contact names in a chat, for the household's eligibility check.
    public func members(of bucket: BucketID) async throws -> [String] {
        let chatID = Int64(bucket.rawValue.dropFirst("imessage:".count)) ?? 0
        return try WALSafeCopy.withCopy(of: Self.database) { db in
            let names = ContactNames()
            return try db.query("SELECT h.id AS id FROM chat_handle_join j JOIN handle h ON h.ROWID=j.handle_id WHERE j.chat_id=?", [.int(chatID)]).flatMap { r -> [String] in
                guard let id = r["id"].text else { return [] }
                return [id, names.resolve(id)]
            }
        }
    }

    public func discoverBuckets() async throws -> [BucketInfo] {
        try WALSafeCopy.withCopy(of: Self.database) { db in
            let rows = try db.query("""
            SELECT c.ROWID AS id, c.chat_identifier AS ident, c.display_name AS name, c.room_name AS room,
                   (SELECT COUNT(*) FROM chat_message_join j WHERE j.chat_id=c.ROWID) AS n,
                   (SELECT COUNT(*) FROM chat_handle_join h WHERE h.chat_id=c.ROWID) AS members
            FROM chat c ORDER BY n DESC
            """)
            let names = ContactNames()
            return rows.compactMap { r in
                guard let id = r["id"].int, let n = r["n"].int, n > 0 else { return nil }
                let ident = r["ident"].text ?? ""
                let isGroup = (r["room"].text ?? "").isEmpty == false || (r["members"].int ?? 0) > 1
                let name = (r["name"].text ?? "").isEmpty ? (isGroup ? "Group (\(r["members"].int ?? 0))" : names.resolve(ident)) : r["name"].text!
                return BucketInfo(id: BucketID("imessage:\(id)"), name: name, detail: isGroup ? "Group · \(r["members"].int ?? 0) people" : "Direct", isGroup: isGroup, count: Int(n))
            }
        }
    }

    public func buckets(since marks: [BucketID: ItemKey], enabled: Set<BucketID>?) async throws -> [Bucket] {
        let infos = try await discoverBuckets().filter { enabled?.contains($0.id) ?? false }
        guard !infos.isEmpty else { return [] }
        let now = Date(), policy = FirstRead.current
        return try WALSafeCopy.withCopy(of: Self.database) { db in
            let names = ContactNames()
            return try infos.map { info in
                let chatID = Int64(info.id.rawValue.dropFirst("imessage:".count)) ?? 0
                let rows = try db.query("""
                SELECT m.ROWID AS id, m.date AS d, m.is_from_me AS me, m.text AS t, m.attributedBody AS body, h.id AS handle
                FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID LEFT JOIN handle h ON h.ROWID=m.handle_id
                WHERE j.chat_id=? ORDER BY m.ROWID ASC
                """, [.int(chatID)])
                let msgs: [ChatMessage] = rows.compactMap { r in
                    let text = r["t"].text.flatMap { $0.isEmpty ? nil : $0 } ?? r["body"].blob.flatMap(TypedStream.extractString)
                    guard let text, !text.isEmpty, let id = r["id"].int else { return nil }
                    let me = (r["me"].int ?? 0) == 1
                    return ChatMessage(rowID: id, date: AppleDates.fromMessagesDate(r["d"].int ?? 0), sender: me ? "Me" : names.resolve(r["handle"].text ?? "?"), isMe: me, text: text)
                }
                let chat = ChatInfo(id: info.id.rawValue, name: info.name, isGroup: info.isGroup, memberCount: info.isGroup ? (Int(info.detail.split(separator: " ").dropFirst(2).first ?? "0") ?? 0) : 2)
                // A chat without a mark has never been read to the bottom: the first-read policy bounds what is listed.
                var capped = msgs, deferred = 0
                if marks[info.id] == nil {
                    let cut = ChatWindowing.firstReadSlice(msgs, isGroup: info.isGroup, policy: policy, source: Self.descriptor.id, now: now)
                    capped = cut.messages; deferred = cut.deferred
                }
                let windows = ChatWindowing.windows(capped, chat: chat)
                let items = windows.map { w in
                    Candidate(source: Self.descriptor.id, bucket: info.id, key: ItemKey(rowID: w.lastRowID), kind: info.isGroup ? .groupChat : .directMessage,
                              id: "\(info.id.rawValue):\(w.lastRowID)", itemDate: w.lastDate,
                              metadata: ["chat": info.name, "isGroup": info.isGroup ? "1" : "0", "firstRow": String(w.firstRowID), "lastRow": String(w.lastRowID)])
                }.reversed()
                return Bucket(id: info.id, name: info.name, items: Array(items), deferred: deferred)
            }
        }
    }

    public func load(_ c: Candidate) async throws -> Artifact {
        // Re-derive the exact window from the row range (cheap; keeps `Candidate` small and storable).
        let chatID = Int64(c.bucket.rawValue.dropFirst("imessage:".count)) ?? 0
        let first = Int64(c.metadata["firstRow"] ?? "") ?? 0, last = Int64(c.metadata["lastRow"] ?? "") ?? 0
        return try WALSafeCopy.withCopy(of: Self.database) { db in
            let names = ContactNames()
            let rows = try db.query("""
            SELECT m.ROWID AS id, m.date AS d, m.is_from_me AS me, m.text AS t, m.attributedBody AS body, h.id AS handle
            FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID LEFT JOIN handle h ON h.ROWID=m.handle_id
            WHERE j.chat_id=? AND m.ROWID BETWEEN ? AND ? ORDER BY m.ROWID ASC
            """, [.int(chatID), .int(first), .int(last)])
            let msgs: [ChatMessage] = rows.compactMap { r in
                let text = r["t"].text.flatMap { $0.isEmpty ? nil : $0 } ?? r["body"].blob.flatMap(TypedStream.extractString)
                guard let text, !text.isEmpty, let id = r["id"].int else { return nil }
                let me = (r["me"].int ?? 0) == 1
                return ChatMessage(rowID: id, date: AppleDates.fromMessagesDate(r["d"].int ?? 0), sender: me ? "Me" : names.resolve(r["handle"].text ?? "?"), isMe: me, text: text)
            }
            let chat = ChatInfo(id: c.bucket.rawValue, name: c.metadata["chat"] ?? "Chat", isGroup: c.isGroup, memberCount: 0)
            let text = ChatWindowing.windows(msgs, chat: chat).map(\.text).joined(separator: "\n\n")
            return Artifact(candidate: c, text: ChatWindowing.clamp(text))
        }
    }
}

/// Modern Messages rows keep the text in an NSArchiver typedstream blob. The string payload sits
/// after the "NSString" class marker: a `+` tag, a length (1 byte, or 0x81 + 2-byte LE, or 0x82 +
/// 4-byte LE), then UTF-8 bytes.
enum TypedStream {
    static func extractString(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let marker = find([UInt8]("NSString".utf8), in: bytes) else { return nil }
        var i = marker + 8
        while i < bytes.count - 2 {
            if bytes[i] == 0x2B { // '+'
                var len = 0; var j = i + 1
                switch bytes[j] {
                case 0x81: guard j + 2 < bytes.count else { return nil }; len = Int(bytes[j+1]) | Int(bytes[j+2]) << 8; j += 3
                case 0x82: guard j + 4 < bytes.count else { return nil }; len = Int(bytes[j+1]) | Int(bytes[j+2]) << 8 | Int(bytes[j+3]) << 16 | Int(bytes[j+4]) << 24; j += 5
                default: len = Int(bytes[j]); j += 1
                }
                guard len > 0, j + len <= bytes.count else { return nil }
                return String(decoding: bytes[j..<j+len], as: UTF8.self)
            }
            i += 1
        }
        return nil
    }
    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] {
            if Array(hay[i..<i+needle.count]) == needle { return i }
        }
        return nil
    }
}

/// Handle (phone/email) → contact name, when Contacts permission is granted; otherwise the handle.
final class ContactNames {
    private var cache: [String: String] = [:]
    private let store = CNContactStore()
    private let granted: Bool

    init() { granted = CNContactStore.authorizationStatus(for: .contacts) == .authorized }

    func resolve(_ handle: String) -> String {
        if let c = cache[handle] { return c }
        var name = handle
        if granted {
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey] as [CNKeyDescriptor]
            let predicate = handle.contains("@") ? CNContact.predicateForContacts(matchingEmailAddress: handle) : CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: handle))
            if let c = try? store.unifiedContacts(matching: predicate, keysToFetch: keys).first {
                let n = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                if !n.isEmpty { name = n }
            }
        }
        cache[handle] = name
        return name
    }
}
