import Foundation
import Domain
import Platform
import LocalSources
import Support

/// Telegram via TDLib with the user's own account. Chats are picked one by one; messages ride the
/// shared chat windowing and the direct-message / group-chat reader prompts.
public struct TelegramSource: Source {
    public static let descriptor = SourceDescriptor(
        id: "telegram", name: "Telegram", detail: "Your own sign-in · pick chats",
        door: .userCloud, permissions: [], supportsPerBucketOptIn: true)

    public static var isConfigured: Bool { (Secrets.value("TELEGRAM_API_ID") ?? "").isEmpty == false }

    /// One shared client for the app.
    public static let shared: TDClient? = {
        guard let id = Secrets.value("TELEGRAM_API_ID").flatMap(Int32.init), let hash = Secrets.value("TELEGRAM_API_HASH") else { return nil }
        let dir = Paths.ensure(Paths.applicationSupport.appendingPathComponent("Telegram", isDirectory: true))
        return TDClient(apiID: id, apiHash: hash, databaseDir: dir)
    }()

    private let log = Log("source.telegram")
    public init() {}

    public func availability() async -> Availability {
        guard Self.isConfigured, let c = Self.shared else { return .unavailable("Needs Telegram API credentials (docs/launch-setup.md)") }
        await c.start()
        return await c.authState == .ready ? .available : .needsSignIn
    }

    public func discoverBuckets() async throws -> [BucketInfo] {
        guard let c = Self.shared, await c.authState == .ready else { throw SourceError.notAvailable(.needsSignIn) }
        let r = try await c.send(["@type": "getChats", "limit": 200], timeout: 60)
        let ids = (r["chat_ids"] as? [Int64]) ?? ((r["chat_ids"] as? [Int]) ?? []).map(Int64.init)
        var out: [BucketInfo] = []
        for id in ids {
            guard let chat = try? await c.send(["@type": "getChat", "chat_id": id]) else { continue }
            let type = (chat["type"] as? [String: Any])?["@type"] as? String ?? ""
            let isGroup = type == "chatTypeBasicGroup" || type == "chatTypeSupergroup"
            if type == "chatTypeSupergroup", ((chat["type"] as? [String: Any])?["is_channel"] as? Bool) == true { continue }   // broadcast channels: skip
            out.append(BucketInfo(id: BucketID("telegram:\(id)"), name: chat["title"] as? String ?? "Chat", detail: isGroup ? "Group" : "Direct", isGroup: isGroup, count: 0))
        }
        return out
    }

    public func buckets(since marks: [BucketID: ItemKey], enabled: Set<BucketID>?) async throws -> [Bucket] {
        guard let c = Self.shared, await c.authState == .ready else { throw SourceError.notAvailable(.needsSignIn) }
        let infos = try await discoverBuckets().filter { enabled?.contains($0.id) ?? false }
        let me = (try? await c.send(["@type": "getMe"]))?["id"] as? Int64 ?? 0
        var out: [Bucket] = []
        for info in infos {
            let chatID = Int64(info.id.rawValue.dropFirst("telegram:".count)) ?? 0
            let msgs = try await Self.history(c, chatID: chatID, me: me, limit: 400)
            let chat = ChatInfo(id: info.id.rawValue, name: info.name, isGroup: info.isGroup, memberCount: 0)
            let items = ChatWindowing.windows(msgs, chat: chat).map { w in
                Candidate(source: Self.descriptor.id, bucket: info.id, key: ItemKey(rowID: w.lastRowID), kind: info.isGroup ? .groupChat : .directMessage,
                          id: "\(info.id.rawValue):\(w.lastRowID)", itemDate: w.lastDate, metadata: ["chat": info.name, "isGroup": info.isGroup ? "1" : "0", "text": w.text])
            }.reversed()
            out.append(Bucket(id: info.id, name: info.name, items: Array(items)))
        }
        return out
    }

    public func load(_ c: Candidate) async throws -> Artifact {
        // The window text was captured at listing time (TDLib history is paged, not re-queryable by row range).
        var meta = c.metadata; let text = meta.removeValue(forKey: "text")
        return Artifact(candidate: Candidate(source: c.source, bucket: c.bucket, key: c.key, kind: c.kind, id: c.id, itemDate: c.itemDate, metadata: meta), text: ChatWindowing.clamp(text ?? ""))
    }

    static func history(_ c: TDClient, chatID: Int64, me: Int64, limit: Int) async throws -> [ChatMessage] {
        var all: [ChatMessage] = []
        var from: Int64 = 0
        var names: [Int64: String] = [:]
        var pages = 0
        while all.count < limit, pages < 12 {
            pages += 1
            let r = try await c.send(["@type": "getChatHistory", "chat_id": chatID, "from_message_id": from, "offset": 0, "limit": 100, "only_local": false], timeout: 60)
            let msgs = (r["messages"] as? [[String: Any]]) ?? []
            guard let last = msgs.last, let lastID = (last["id"] as? Int64) ?? (last["id"] as? Int).map(Int64.init), lastID != from else { break }   // no progress ⇒ done
            for m in msgs {
                guard let id = (m["id"] as? Int64) ?? (m["id"] as? Int).map(Int64.init), let content = m["content"] as? [String: Any] else { continue }
                let text = (content["text"] as? [String: Any])?["text"] as? String ?? (content["caption"] as? [String: Any])?["text"] as? String ?? ""
                guard !text.isEmpty else { continue }
                let sender = m["sender_id"] as? [String: Any]
                let senderID = (sender?["user_id"] as? Int64) ?? (sender?["user_id"] as? Int).map(Int64.init) ?? 0
                let isMe = senderID == me
                var name = "?"
                if !isMe, senderID != 0 {
                    if let n = names[senderID] { name = n }
                    else if let u = try? await c.send(["@type": "getUser", "user_id": senderID]) { name = [u["first_name"] as? String ?? "", u["last_name"] as? String ?? ""].filter { !$0.isEmpty }.joined(separator: " "); names[senderID] = name }
                }
                all.append(ChatMessage(rowID: id, date: Date(timeIntervalSince1970: TimeInterval(m["date"] as? Int ?? 0)), sender: isMe ? "Me" : name, isMe: isMe, text: text))
            }
            from = lastID
        }
        return all.sorted { $0.rowID < $1.rowID }
    }
}

extension TelegramSource: ChatReader {
    public func chats() async throws -> [BucketInfo] { try await discoverBuckets() }
    public func messages(in bucket: BucketID, from: Date, to: Date) async throws -> [ChatMessage] {
        guard let c = Self.shared, await c.authState == .ready else { throw SourceError.notAvailable(.needsSignIn) }
        let me = (try? await c.send(["@type": "getMe"]))?["id"] as? Int64 ?? 0
        let chatID = Int64(bucket.rawValue.dropFirst("telegram:".count)) ?? 0
        return try await Self.history(c, chatID: chatID, me: me, limit: 400).filter { $0.date >= from && $0.date <= to }
    }
}
extension TelegramSource: AskScanning { public func recentAsks(enabled: Set<BucketID>?, since: Date) async throws -> [Ask] { try await scanAsks(enabled: enabled, since: since) } }
