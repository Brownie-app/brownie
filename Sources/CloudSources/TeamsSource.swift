import Foundation
import AppKit
import Domain
import Platform
import LocalSources
import Support

// MARK: - Sign-in

/// Microsoft sign-in as the user: a public client with PKCE and a loopback redirect — no client secret at all.
/// Needs MICROSOFT_CLIENT_ID (an Entra app registered as "Mobile and desktop", redirect http://localhost).
/// The user's admin may have to consent once for chat and channel reading.
public actor MicrosoftAuth {
    public static let shared = MicrosoftAuth()
    public static let scopes = ["User.Read", "Chat.Read", "ChannelMessage.Read.All", "Team.ReadBasic.All", "Channel.ReadBasic.All", "offline_access"]
    public static var isConfigured: Bool { !(Secrets.value("MICROSOFT_CLIENT_ID") ?? "").isEmpty }
    public static var isSignedIn: Bool { Keychain.get("microsoft.refreshToken") != nil }
    public enum Error: Swift.Error { case notConfigured, cancelled, exchange(String), noRefreshToken }
    private let log = Log("microsoft.auth")

    public func signIn(transport: any JSONTransport = URLSessionTransport()) async throws {
        guard let clientID = Secrets.value("MICROSOFT_CLIENT_ID") else { throw Error.notConfigured }
        let verifier = GoogleAuth.random(64), state = GoogleAuth.random(16)
        let challenge = GoogleAuth.base64url(GoogleAuth.sha256(Data(verifier.utf8)))
        let server = try LoopbackServer()
        let redirect = "http://localhost:\(server.port)"
        var c = URLComponents(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        c.queryItems = [.init(name: "client_id", value: clientID), .init(name: "response_type", value: "code"), .init(name: "redirect_uri", value: redirect),
                        .init(name: "scope", value: Self.scopes.joined(separator: " ")), .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
                        .init(name: "state", value: state), .init(name: "prompt", value: "select_account")]
        await MainActor.run { NSWorkspace.shared.open(c.url!) }
        let params = try await server.waitForCallback()
        guard params["state"] == state, let code = params["code"] else { throw Error.cancelled }
        let tok = try await Self.token(["client_id": clientID, "grant_type": "authorization_code", "code": code, "redirect_uri": redirect, "code_verifier": verifier, "scope": Self.scopes.joined(separator: " ")], transport)
        guard let refresh = tok["refresh_token"] as? String else { throw Error.noRefreshToken }
        Self.store(tok, refresh: refresh)
        log.info("signed in")
    }

    public static func signOut() { for k in ["microsoft.refreshToken", "microsoft.accessToken", "microsoft.accessExpiry"] { Keychain.set(k, nil) } }

    public func accessToken(transport: any JSONTransport = URLSessionTransport()) async throws -> String {
        if let t = Keychain.get("microsoft.accessToken"), let e = Keychain.get("microsoft.accessExpiry").flatMap(Double.init), e - 60 > Date().timeIntervalSince1970 { return t }
        guard let refresh = Keychain.get("microsoft.refreshToken") else { throw Error.noRefreshToken }
        guard let clientID = Secrets.value("MICROSOFT_CLIENT_ID") else { throw Error.notConfigured }
        let tok = try await Self.token(["client_id": clientID, "grant_type": "refresh_token", "refresh_token": refresh, "scope": Self.scopes.joined(separator: " ")], transport)
        guard let access = tok["access_token"] as? String else { throw Error.exchange("no access token") }
        Self.store(tok, refresh: tok["refresh_token"] as? String ?? refresh)
        return access
    }

    static func store(_ tok: [String: Any], refresh: String) {
        Keychain.set("microsoft.refreshToken", refresh)
        Keychain.set("microsoft.accessToken", tok["access_token"] as? String)
        Keychain.set("microsoft.accessExpiry", String(Date().timeIntervalSince1970 + ((tok["expires_in"] as? Double) ?? 3000)))
    }
    static func token(_ form: [String: String], _ transport: any JSONTransport) async throws -> [String: Any] {
        let body = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }.joined(separator: "&").data(using: .utf8)
        return try await transport.json(URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: body)
    }
}

// MARK: - Parsing (pure)

public enum TeamsParsing {
    public struct Conversation: Sendable, Equatable { public let id: BucketID; public let name: String; public let isGroup: Bool; public let members: Int; public let detail: String; public var handle: String? = nil }

    static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    static let isoPlain = ISO8601DateFormatter()
    static func date(_ s: String?) -> Date? { s.flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) } }

    /// `/me/chats?$expand=members` → one-to-one chats named after the other person, group chats after their topic or members.
    public static func chats(_ obj: [String: Any], me: String) -> [Conversation] {
        (obj["value"] as? [[String: Any]] ?? []).compactMap { c in
            guard let id = c["id"] as? String else { return nil }
            let members = (c["members"] as? [[String: Any]] ?? []).compactMap { m -> (id: String, name: String)? in
                guard let n = m["displayName"] as? String else { return nil }
                return (m["userId"] as? String ?? "", n)
            }
            let others = members.filter { $0.id != me }
            let type = c["chatType"] as? String ?? "group"
            if type == "oneOnOne" { return Conversation(id: BucketID("teams:chat:\(id)"), name: others.first?.name ?? "Chat", isGroup: false, members: 2, detail: "Direct", handle: others.first.flatMap { $0.id.isEmpty ? nil : PersonHandle.teams(userID: $0.id) }) }
            let topic = (c["topic"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let name = topic ?? (type == "meeting" ? "Meeting chat" : "Group · " + others.prefix(3).map(\.name).joined(separator: ", "))
            return Conversation(id: BucketID("teams:chat:\(id)"), name: name, isGroup: true, members: members.count, detail: type == "meeting" ? "Meeting chat" : "Group chat · \(members.count) people")
        }
    }

    /// `/teams/{id}/channels` → channels, prefixed with the team's name.
    public static func channels(_ obj: [String: Any], teamID: String, teamName: String) -> [Conversation] {
        (obj["value"] as? [[String: Any]] ?? []).compactMap { c in
            guard let id = c["id"] as? String, let n = c["displayName"] as? String else { return nil }
            return Conversation(id: BucketID("teams:channel:\(teamID)/\(id)"), name: "\(teamName) · \(n)", isGroup: true, members: 0, detail: (c["membershipType"] as? String == "private" ? "Private channel" : "Channel") + " in \(teamName)")
        }
    }

    /// `/chats/{id}/messages` or `/teams/{t}/channels/{c}/messages` → messages, oldest first. System events and empty bodies are dropped; HTML is flattened.
    public static func messages(_ obj: [String: Any], me: String) -> [ChatMessage] {
        (obj["value"] as? [[String: Any]] ?? []).compactMap { m -> ChatMessage? in
            guard let id = m["id"] as? String, let d = date(m["createdDateTime"] as? String) else { return nil }
            if m["messageType"] as? String != "message" { return nil }
            if m["deletedDateTime"] != nil, !(m["deletedDateTime"] is NSNull) { return nil }
            let body = m["body"] as? [String: Any]
            var text = body?["content"] as? String ?? ""
            if body?["contentType"] as? String == "html" { text = stripHTML(text) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty, let att = m["attachments"] as? [[String: Any]], !att.isEmpty { text = "[attachment: \(att.compactMap { $0["name"] as? String }.joined(separator: ", "))]" }
            guard !text.isEmpty else { return nil }
            let user = (m["from"] as? [String: Any])?["user"] as? [String: Any]
            let uid = user?["id"] as? String ?? ""
            let sender = user?["displayName"] as? String ?? ((m["from"] as? [String: Any])?["application"] as? [String: Any])?["displayName"] as? String ?? "someone"
            return ChatMessage(rowID: Int64(id) ?? Int64(d.timeIntervalSince1970 * 1000), date: d, sender: sender, isMe: !uid.isEmpty && uid == me, text: text)
        }.sorted { $0.date < $1.date }
    }

    public static func stripHTML(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>", with: "\n", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "<at[^>]*>", with: "@", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
        return t.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - The source

/// Microsoft Teams through Graph, as the user: the chats and channels they pick; the first-read policy's window at first read.
public struct TeamsSource: Source {
    public static let descriptor = SourceDescriptor(
        id: "teams", name: "Microsoft Teams", detail: "Sign in with your work account · chats and channels you choose · needs your admin's consent once",
        door: .userCloud, permissions: [], supportsPerBucketOptIn: true, isWork: true)
    /// Pages of 50 one listing fetches at most: enough to cover the first-read caps, so only a busy chat between
    /// runs can hit it; when it does, the bucket says so instead of losing the rest quietly.
    public static let pageCap = 14
    static let graph = "https://graph.microsoft.com/v1.0"
    let transport: any JSONTransport
    let token: @Sendable () async throws -> String
    let now: @Sendable () -> Date
    let policy: @Sendable () -> FirstRead
    private let log = Log("source.teams")

    public init(transport: any JSONTransport = URLSessionTransport(), token: @escaping @Sendable () async throws -> String = { try await MicrosoftAuth.shared.accessToken() },
                now: @escaping @Sendable () -> Date = { Date() }, policy: @escaping @Sendable () -> FirstRead = { FirstRead.current }) {
        self.transport = transport; self.token = token; self.now = now; self.policy = policy
    }

    public func availability() async -> Availability {
        let t = try? await token()
        guard MicrosoftAuth.isSignedIn || t != nil else { return .needsSignIn }
        do { _ = try await me(); return .available } catch { return .unavailable("\(error)") }
    }

    public func discoverBuckets() async throws -> [BucketInfo] {
        let myID = try await me()
        var out: [BucketInfo] = []
        for c in TeamsParsing.chats(try await get("/me/chats?$expand=members&$top=50"), me: myID) { out.append(BucketInfo(id: c.id, name: c.name, detail: c.detail, isGroup: c.isGroup, count: c.members, handle: c.handle)) }
        for team in (try await get("/me/joinedTeams"))["value"] as? [[String: Any]] ?? [] {
            guard let tid = team["id"] as? String else { continue }
            let tname = team["displayName"] as? String ?? "Team"
            let chans = (try? await get("/teams/\(tid)/channels")) ?? [:]
            for c in TeamsParsing.channels(chans, teamID: tid, teamName: tname) { out.append(BucketInfo(id: c.id, name: c.name, detail: c.detail, isGroup: true, count: c.members)) }
        }
        log.info("\(out.count) conversations discovered")
        return out
    }

    public func buckets(since marks: [BucketID: ItemKey], enabled: Set<BucketID>?) async throws -> [Bucket] {
        let infos = try await discoverBuckets().filter { enabled?.contains($0.id) ?? false }
        guard !infos.isEmpty else { return [] }
        let myID = try await me()
        var out: [Bucket] = []
        let now = now(), policy = policy()
        for info in infos {
            var msgs: [ChatMessage], deferred: Int
            if let mark = marks[info.id] {
                // Read to the bottom before: everything since the last message seen.
                let h = try await messagesPaged(of: info.id, me: myID, newerThan: Date(timeIntervalSince1970: mark.order))
                msgs = h.messages; deferred = h.hitPageCap ? 1 : 0
            } else {
                // A first read: the policy's window, then only its cap of newest messages.
                let h = try await messagesPaged(of: info.id, me: myID, newerThan: policy.window(for: Self.descriptor.id, now: now))
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
        let myID = try await me()
        let first = Date(timeIntervalSince1970: (Double(c.metadata["firstDate"] ?? "") ?? 0) - 1)
        let msgs = CloudChat.slice(try await messages(of: c.bucket, me: myID, newerThan: first), of: c)
        return Artifact(candidate: c, text: CloudChat.text(name: c.metadata["chat"] ?? "Teams", isGroup: c.isGroup, members: Int(c.metadata["members"] ?? "") ?? 0, messages: msgs))
    }

    // MARK: calls

    static func path(for b: BucketID) -> String {
        let raw = b.rawValue
        if raw.hasPrefix("teams:chat:") { return "/me/chats/\(raw.dropFirst("teams:chat:".count))/messages?$top=50" }
        let pair = raw.dropFirst("teams:channel:".count).split(separator: "/", maxSplits: 1)
        return "/teams/\(pair.first ?? "")/channels/\(pair.count > 1 ? pair[1] : "")/messages?$top=50"
    }

    struct History { let messages: [ChatMessage]; let hitPageCap: Bool }

    func messages(of b: BucketID, me: String, newerThan: Date) async throws -> [ChatMessage] {
        try await messagesPaged(of: b, me: me, newerThan: newerThan).messages
    }

    /// Newest-first pages until one is older than `newerThan`, capped; says whether the cap stopped it with more still to fetch.
    func messagesPaged(of b: BucketID, me: String, newerThan: Date) async throws -> History {
        var all: [ChatMessage] = []
        var next: String? = Self.graph + Self.path(for: b)
        var pages = 0, done = false
        while let url = next, !done, pages < Self.pageCap {
            let t = try await token()
            let r = try await transport.json(URL(string: url)!, headers: ["Authorization": "Bearer \(t)"])
            let page = TeamsParsing.messages(r, me: me)
            all += page.filter { $0.date > newerThan }
            done = page.contains(where: { $0.date <= newerThan })
            next = r["@odata.nextLink"] as? String; pages += 1
        }
        return History(messages: all.sorted { $0.date < $1.date }, hitPageCap: !done && next != nil)
    }

    func me() async throws -> String {
        guard let id = (try await get("/me"))["id"] as? String else { throw SourceError.cannotRead("Microsoft didn't say who you are") }
        return id
    }
    func get(_ path: String) async throws -> [String: Any] {
        let t = try await token()
        return try await transport.json(URL(string: Self.graph + path.replacingOccurrences(of: "$", with: "%24"))!, headers: ["Authorization": "Bearer \(t)"])
    }
}

extension TeamsSource: ChatReader {
    public func chats() async throws -> [BucketInfo] { try await discoverBuckets() }
    public func messages(in bucket: BucketID, from: Date, to: Date) async throws -> [ChatMessage] {
        try await messages(of: bucket, me: try await me(), newerThan: from).filter { $0.date <= to }
    }
}
extension TeamsSource: AskScanning { public func recentAsks(enabled: Set<BucketID>?, since: Date) async throws -> [Ask] { try await scanAsks(enabled: enabled, since: since) } }
