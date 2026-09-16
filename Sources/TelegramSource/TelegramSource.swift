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
        let now = Date(), policy = FirstRead.current
        for info in infos {
            let chatID = Int64(info.id.rawValue.dropFirst("telegram:".count)) ?? 0
            var msgs: [ChatMessage], deferred: Int
            if let mark = marks[info.id] {
                // Read to the bottom before: page newest-first all the way down to the last message already seen.
                // The mark bounds the work, so no cap applies; stopping short would move the mark past messages never fetched.
                let h = try await Self.history(c, chatID: chatID, me: me, limit: nil) { $0.rowID <= Int64(mark.order) }
                msgs = h.messages; deferred = 0
            } else {
                // A first read: page until the policy's window edge or its cap, then keep the newest messages.
                let edge = policy.window(for: Self.descriptor.id, now: now)
                let h = try await Self.history(c, chatID: chatID, me: me, limit: policy.chatCap(isGroup: info.isGroup, for: Self.descriptor.id)) { $0.date < edge }
                let cut = ChatWindowing.firstReadSlice(h.messages, isGroup: info.isGroup, policy: policy, source: Self.descriptor.id, now: now)
                msgs = cut.messages; deferred = cut.deferred + (h.stoppedShort ? 1 : 0)
            }
            if deferred > 0 { log.info("\(info.name): \(deferred) messages set aside") }
            let chat = ChatInfo(id: info.id.rawValue, name: info.name, isGroup: info.isGroup, memberCount: 0)
            let items = ChatWindowing.windows(msgs, chat: chat).map { w in
                Candidate(source: Self.descriptor.id, bucket: info.id, key: ItemKey(rowID: w.lastRowID), kind: info.isGroup ? .groupChat : .directMessage,
                          id: "\(info.id.rawValue):\(w.lastRowID)", itemDate: w.lastDate, metadata: ["chat": info.name, "isGroup": info.isGroup ? "1" : "0", "text": w.text])
            }.reversed()
            out.append(Bucket(id: info.id, name: info.name, items: Array(items), deferred: deferred))
        }
        return out
    }

    /// An evidence lookup back to a date is bounded by this many messages.
    static let lookupCap = 1200
    static let pageSize = 100
    /// Pages of history a bounded call fetches at most; the message caps are all smaller, so a first read never hits it.
    static let pageCap = 20

    /// Ascending messages, and whether paging ended before it reached the stopping message or the start of the chat —
    /// by the message limit or the page cap — so there is more behind it the caller never saw.
    struct History { let messages: [ChatMessage]; let stoppedShort: Bool }

    public func load(_ c: Candidate) async throws -> Artifact {
        // The window text was captured at listing time (TDLib history is paged, not re-queryable by row range).
        var meta = c.metadata; let text = meta.removeValue(forKey: "text")
        return Artifact(candidate: Candidate(source: c.source, bucket: c.bucket, key: c.key, kind: c.kind, id: c.id, itemDate: c.itemDate, metadata: meta), text: ChatWindowing.clamp(text ?? ""))
    }

    /// Newest-first pages until `stop` matches a message (the window edge, or one already read), `limit` messages
    /// are in hand, or the page cap; the stopping message and everything behind it are left out. Ascending on return.
    /// A nil `limit` lifts both caps: paging goes on until the stopping message or the start of the chat, the shape
    /// of a read bounded by the mark.
    static func history(_ c: any TDSending, chatID: Int64, me: Int64, limit: Int?, stop: (ChatMessage) -> Bool) async throws -> History {
        var all: [ChatMessage] = []
        var from: Int64 = 0
        var names: [Int64: String] = [:]
        var pages = 0, done = false
        while !done, all.count < (limit ?? Int.max), limit == nil || pages < pageCap {
            pages += 1
            let r = try await c.send(["@type": "getChatHistory", "chat_id": chatID, "from_message_id": from, "offset": 0, "limit": pageSize, "only_local": false], timeout: 60)
            let msgs = (r["messages"] as? [[String: Any]]) ?? []
            guard let last = msgs.last, let lastID = (last["id"] as? Int64) ?? (last["id"] as? Int).map(Int64.init), lastID != from else { done = true; break }   // no progress ⇒ done
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
                let message = ChatMessage(rowID: id, date: Date(timeIntervalSince1970: TimeInterval(m["date"] as? Int ?? 0)), sender: isMe ? "Me" : name, isMe: isMe, text: text)
                if stop(message) { done = true; break }
                all.append(message)
            }
            from = lastID
        }
        // Only the stopping message or the start of the chat ends paging cleanly; any other exit left history unseen.
        return History(messages: all.sorted { $0.rowID < $1.rowID }, stoppedShort: !done)
    }
}

/// What paging history needs of a client: TDClient is the real one; tests hand in scripted pages.
protocol TDSending: Sendable {
    func send(_ req: [String: Any], timeout: TimeInterval) async throws -> [String: Any]
}
extension TDSending { func send(_ req: [String: Any]) async throws -> [String: Any] { try await send(req, timeout: 30) } }
extension TDClient: TDSending {}

extension TelegramSource: ChatReader {
    public func chats() async throws -> [BucketInfo] { try await discoverBuckets() }
    public func messages(in bucket: BucketID, from: Date, to: Date) async throws -> [ChatMessage] {
        guard let c = Self.shared, await c.authState == .ready else { throw SourceError.notAvailable(.needsSignIn) }
        let me = (try? await c.send(["@type": "getMe"]))?["id"] as? Int64 ?? 0
        let chatID = Int64(bucket.rawValue.dropFirst("telegram:".count)) ?? 0
        return try await Self.history(c, chatID: chatID, me: me, limit: Self.lookupCap) { $0.date < from }.messages.filter { $0.date <= to }
    }
}
extension TelegramSource: AskScanning { public func recentAsks(enabled: Set<BucketID>?, since: Date) async throws -> [Ask] { try await scanAsks(enabled: enabled, since: since) } }
