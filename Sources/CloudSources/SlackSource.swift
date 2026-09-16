import Foundation
import AppKit
import Domain
import Platform
import LocalSources
import Support

// MARK: - Sign-in

/// Slack sign-in as the user (a user token, `xoxp-`). Slack only redirects to https, so the callback lands on
/// the Brownie website, which hands it straight back to the app as `brownie://oauth/slack?code=…`.
/// Nothing is stored on the site; the token is exchanged here and kept in the Keychain.
public actor SlackAuth {
    public static let shared = SlackAuth()
    public static let callback = "https://www.usebrownie.com/oauth/slack"
    public static let scopes = ["channels:history", "channels:read", "groups:history", "groups:read", "im:history", "im:read", "mpim:history", "mpim:read", "users:read"]
    public static let tokenKey = "slack.token"
    public static var isConfigured: Bool { !(Secrets.value("SLACK_CLIENT_ID") ?? "").isEmpty }
    public static var isSignedIn: Bool { Keychain.get(tokenKey) != nil }
    public enum Error: Swift.Error { case notConfigured, cancelled, exchange(String) }

    private var pending: CheckedContinuation<[String: String], Swift.Error>?
    private var state = ""
    private let log = Log("slack.auth")

    /// Opens the browser; resolves when the app receives the `brownie://oauth/slack` callback.
    public func signIn(transport: any JSONTransport = URLSessionTransport()) async throws {
        guard let id = Secrets.value("SLACK_CLIENT_ID"), let secret = Secrets.value("SLACK_CLIENT_SECRET") else { throw Error.notConfigured }
        state = GoogleAuth.random(16)
        var c = URLComponents(string: "https://slack.com/oauth/v2/authorize")!
        c.queryItems = [.init(name: "client_id", value: id), .init(name: "user_scope", value: Self.scopes.joined(separator: ",")), .init(name: "redirect_uri", value: Self.callback), .init(name: "state", value: state)]
        await MainActor.run { NSWorkspace.shared.open(c.url!) }
        let params = try await withCheckedThrowingContinuation { (k: CheckedContinuation<[String: String], Swift.Error>) in pending = k }
        guard params["state"] == state, let code = params["code"] else { throw Error.cancelled }
        let form = ["code": code, "client_id": id, "client_secret": secret, "redirect_uri": Self.callback]
        let body = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }.joined(separator: "&").data(using: .utf8)
        let tok = try await transport.json(URL(string: "https://slack.com/api/oauth.v2.access")!, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: body)
        guard tok["ok"] as? Bool == true, let user = tok["authed_user"] as? [String: Any], let access = user["access_token"] as? String else { throw Error.exchange(tok["error"] as? String ?? "no token") }
        Keychain.set(Self.tokenKey, access)
        log.info("signed in")
    }
    /// The app calls this when `brownie://oauth/slack?…` arrives.
    public func receive(_ params: [String: String]) { pending?.resume(returning: params); pending = nil }
    public func cancel() { pending?.resume(throwing: Error.cancelled); pending = nil }
    /// A token pasted by hand (a user token from the user's own Slack app) — for workspaces where the Brownie app isn't approved.
    public static func useToken(_ t: String) { Keychain.set(tokenKey, t.trimmingCharacters(in: .whitespacesAndNewlines)) }
    public static func signOut() { Keychain.set(tokenKey, nil) }
}

// MARK: - Parsing (pure)

public enum SlackParsing {
    public struct Channel: Sendable, Equatable { public let id: String; public let name: String; public let isGroup: Bool; public let members: Int; public let detail: String }

    /// `conversations.list` → channels and DMs. DMs get the other person's name; group DMs their members.
    public static func channels(_ obj: [String: Any], names: [String: String]) -> [Channel] {
        (obj["channels"] as? [[String: Any]] ?? []).compactMap { c in
            guard let id = c["id"] as? String else { return nil }
            if c["is_archived"] as? Bool == true { return nil }
            if c["is_im"] as? Bool == true {
                let u = c["user"] as? String ?? ""
                return Channel(id: id, name: names[u] ?? u, isGroup: false, members: 2, detail: "Direct")
            }
            if c["is_mpim"] as? Bool == true {
                let raw = c["name"] as? String ?? ""   // "mpdm-alice--bob--carol-1"
                let who = raw.replacingOccurrences(of: "mpdm-", with: "").replacingOccurrences(of: "-1", with: "").components(separatedBy: "--")
                return Channel(id: id, name: "Group DM · " + who.joined(separator: ", "), isGroup: true, members: who.count, detail: "Group DM")
            }
            let n = c["num_members"] as? Int ?? 0
            return Channel(id: id, name: "#" + (c["name"] as? String ?? id), isGroup: true, members: n, detail: (c["is_private"] as? Bool == true ? "Private channel" : "Channel") + " · \(n) members")
        }
    }

    /// `users.list` → id → display name.
    public static func users(_ obj: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for u in obj["members"] as? [[String: Any]] ?? [] {
            guard let id = u["id"] as? String else { continue }
            let p = u["profile"] as? [String: Any]
            let name = [p?["display_name"] as? String, p?["real_name"] as? String, u["real_name"] as? String, u["name"] as? String].compactMap { $0 }.first { !$0.isEmpty } ?? id
            out[id] = name
        }
        return out
    }

    static let skipSubtypes: Set<String> = ["channel_join", "channel_leave", "group_join", "group_leave", "bot_add", "channel_topic", "channel_purpose", "pinned_item", "reminder_add", "tombstone"]

    /// `conversations.history` → messages, oldest first. Joins/leaves are dropped; mentions and links are made readable.
    public static func messages(_ obj: [String: Any], me: String, names: [String: String]) -> [ChatMessage] {
        (obj["messages"] as? [[String: Any]] ?? []).compactMap { m -> ChatMessage? in
            guard let ts = m["ts"] as? String, let t = Double(ts) else { return nil }
            if let st = m["subtype"] as? String, skipSubtypes.contains(st) { return nil }
            var text = m["text"] as? String ?? ""
            if text.isEmpty, let files = m["files"] as? [[String: Any]], !files.isEmpty { text = "[file: \(files.compactMap { $0["name"] as? String }.joined(separator: ", "))]" }
            guard !text.isEmpty else { return nil }
            let uid = m["user"] as? String ?? (m["bot_id"] as? String ?? "")
            let sender = m["username"] as? String ?? names[uid] ?? (uid.isEmpty ? "someone" : uid)
            return ChatMessage(rowID: Int64(t * 1_000_000), date: Date(timeIntervalSince1970: t), sender: sender, isMe: uid == me, text: unescape(text, names: names))
        }.sorted { $0.date < $1.date }
    }

    /// Slack's mrkdwn escapes: `<@U1>` → @Name, `<#C1|design>` → #design, `<https://x|label>` → label, `&amp;` → &.
    public static func unescape(_ s: String, names: [String: String]) -> String {
        var out = ""
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            out += rest[..<open]
            let inner = rest[rest.index(after: open)..<close]
            let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
            let head = parts[0], label = parts.count > 1 ? parts[1] : nil
            if head.hasPrefix("@") { let id = String(head.dropFirst()); out += "@" + (names[id] ?? label ?? id) }
            else if head.hasPrefix("#") { out += "#" + (label ?? String(head.dropFirst())) }
            else if head.hasPrefix("!") { out += "@" + (label ?? String(head.dropFirst())) }
            else { out += label ?? head }
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return out.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }
}

// MARK: - The source

/// Slack, read as the user: only the channels and DMs they pick; the first-read policy's window at first read, then only what is new.
public struct SlackSource: Source {
    public static let descriptor = SourceDescriptor(
        id: "slack", name: "Slack", detail: "Signed in as you · DMs and channels you choose",
        door: .userCloud, permissions: [], supportsPerBucketOptIn: true, isWork: true)
    /// Pages of 200 one listing fetches at most. The first-read caps are smaller, so only a busy channel between
    /// runs can hit it; when it does, the bucket says so instead of losing the rest quietly.
    public static let pageCap = 5
    let transport: any JSONTransport
    let token: @Sendable () -> String?
    let now: @Sendable () -> Date
    let policy: @Sendable () -> FirstRead
    private let log = Log("source.slack")

    public init(transport: any JSONTransport = URLSessionTransport(), token: @escaping @Sendable () -> String? = { Keychain.get(SlackAuth.tokenKey) },
                now: @escaping @Sendable () -> Date = { Date() }, policy: @escaping @Sendable () -> FirstRead = { FirstRead.current }) {
        self.transport = transport; self.token = token; self.now = now; self.policy = policy
    }

    public func availability() async -> Availability {
        guard let t = token() else { return .needsSignIn }
        do {
            let r = try await call("auth.test", t)
            return r["ok"] as? Bool == true ? .available : (r["error"] as? String == "invalid_auth" || r["error"] as? String == "token_revoked" ? .needsSignIn : .unavailable(r["error"] as? String ?? "Slack refused"))
        } catch { return .unavailable("\(error)") }
    }

    public func discoverBuckets() async throws -> [BucketInfo] {
        guard let t = token() else { throw SourceError.cannotRead("not signed in to Slack") }
        let names = try await users(t)
        var out: [BucketInfo] = []
        var cursor: String? = nil
        repeat {
            let r = try await call("conversations.list", t, ["types": "public_channel,private_channel,mpim,im", "exclude_archived": "true", "limit": "500", "cursor": cursor ?? ""])
            guard r["ok"] as? Bool == true else { throw SourceError.cannotRead("Slack: \(r["error"] as? String ?? "conversations.list failed")") }
            out += SlackParsing.channels(r, names: names).map { BucketInfo(id: BucketID("slack:\($0.id)"), name: $0.name, detail: $0.detail, isGroup: $0.isGroup, count: $0.members) }
            cursor = (r["response_metadata"] as? [String: Any])?["next_cursor"] as? String; if cursor?.isEmpty == true { cursor = nil }
        } while cursor != nil
        log.info("\(out.count) conversations discovered")
        return out
    }

    public func buckets(since marks: [BucketID: ItemKey], enabled: Set<BucketID>?) async throws -> [Bucket] {
        guard let t = token() else { return [] }
        let infos = try await discoverBuckets().filter { enabled?.contains($0.id) ?? false }
        guard !infos.isEmpty else { return [] }
        let names = try await users(t)
        let me = (try await call("auth.test", t))["user_id"] as? String ?? ""
        var out: [Bucket] = []
        let now = now(), policy = policy()
        for info in infos {
            var msgs: [ChatMessage], deferred: Int
            if let mark = marks[info.id] {
                // Read to the bottom before: everything since the last message seen.
                let h = try await historyPaged(channel(info.id), t, oldest: mark.order, latest: nil, me: me, names: names)
                msgs = h.messages; deferred = h.hitPageCap ? 1 : 0
            } else {
                // A first read: the policy's window, then only its cap of newest messages.
                let oldest = policy.window(for: Self.descriptor.id, now: now).timeIntervalSince1970
                let h = try await historyPaged(channel(info.id), t, oldest: oldest, latest: nil, me: me, names: names)
                let cut = ChatWindowing.firstReadSlice(h.messages, isGroup: info.isGroup, policy: policy, source: Self.descriptor.id, now: now)
                msgs = cut.messages; deferred = cut.deferred + (h.hitPageCap ? 1 : 0)
            }
            if deferred > 0 { log.info("\(info.name): \(deferred) messages set aside") }
            let items = CloudChat.candidates(source: Self.descriptor.id, bucket: info.id, name: info.name, isGroup: info.isGroup, members: info.count, messages: msgs)
            out.append(Bucket(id: info.id, name: info.name, items: Array(items), deferred: deferred))
        }
        return out
    }

    public func load(_ c: Candidate) async throws -> Artifact {
        guard let t = token() else { throw SourceError.cannotRead("not signed in to Slack") }
        let names = try await users(t)
        let me = (try await call("auth.test", t))["user_id"] as? String ?? ""
        let first = Double(c.metadata["firstDate"] ?? "") ?? 0, last = Double(c.metadata["lastDate"] ?? "")
        let msgs = try await history(channel(c.bucket), t, oldest: first - 0.001, latest: last.map { $0 + 0.001 }, me: me, names: names)
        return Artifact(candidate: c, text: CloudChat.text(name: c.metadata["chat"] ?? "Slack", isGroup: c.isGroup, members: Int(c.metadata["members"] ?? "") ?? 0, messages: msgs))
    }

    // MARK: calls

    func channel(_ b: BucketID) -> String { String(b.rawValue.dropFirst("slack:".count)) }

    struct History { let messages: [ChatMessage]; let hitPageCap: Bool }

    func history(_ channel: String, _ t: String, oldest: Double, latest: Double?, me: String, names: [String: String]) async throws -> [ChatMessage] {
        try await historyPaged(channel, t, oldest: oldest, latest: latest, me: me, names: names).messages
    }

    /// Ascending messages in the range, and whether the page cap stopped the listing with more still to fetch.
    func historyPaged(_ channel: String, _ t: String, oldest: Double, latest: Double?, me: String, names: [String: String]) async throws -> History {
        var all: [ChatMessage] = []
        var cursor: String? = nil, pages = 0
        repeat {
            var args = ["channel": channel, "oldest": String(format: "%.6f", oldest), "limit": "200", "inclusive": "true", "cursor": cursor ?? ""]
            if let latest { args["latest"] = String(format: "%.6f", latest) }
            let r = try await call("conversations.history", t, args)
            guard r["ok"] as? Bool == true else { throw SourceError.cannotRead("Slack: \(r["error"] as? String ?? "history failed") in \(channel)") }
            all += SlackParsing.messages(r, me: me, names: names)
            cursor = (r["response_metadata"] as? [String: Any])?["next_cursor"] as? String; if cursor?.isEmpty == true { cursor = nil }
            pages += 1
        } while cursor != nil && pages < Self.pageCap
        return History(messages: all.sorted { $0.date < $1.date }, hitPageCap: cursor != nil)
    }

    func users(_ t: String) async throws -> [String: String] {
        var names: [String: String] = [:]
        var cursor: String? = nil
        repeat {
            let r = try await call("users.list", t, ["limit": "500", "cursor": cursor ?? ""])
            guard r["ok"] as? Bool == true else { break }
            names.merge(SlackParsing.users(r)) { $1 }
            cursor = (r["response_metadata"] as? [String: Any])?["next_cursor"] as? String; if cursor?.isEmpty == true { cursor = nil }
        } while cursor != nil
        return names
    }

    func call(_ method: String, _ token: String, _ args: [String: String] = [:]) async throws -> [String: Any] {
        var c = URLComponents(string: "https://slack.com/api/\(method)")!
        c.queryItems = args.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return try await transport.json(c.url!, headers: ["Authorization": "Bearer \(token)"])
    }
}

extension SlackSource: ChatReader {
    public func chats() async throws -> [BucketInfo] { try await discoverBuckets() }
    public func messages(in bucket: BucketID, from: Date, to: Date) async throws -> [ChatMessage] {
        guard let t = token() else { throw SourceError.cannotRead("not signed in to Slack") }
        let names = try await users(t)
        let me = (try await call("auth.test", t))["user_id"] as? String ?? ""
        return try await history(channel(bucket), t, oldest: from.timeIntervalSince1970, latest: to.timeIntervalSince1970, me: me, names: names)
    }
}
extension SlackSource: AskScanning { public func recentAsks(enabled: Set<BucketID>?, since: Date) async throws -> [Ask] { try await scanAsks(enabled: enabled, since: since) } }
