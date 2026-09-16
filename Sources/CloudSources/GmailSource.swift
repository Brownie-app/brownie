import Foundation
import Domain
import Support

/// Gmail via the user's own Google account (readonly scope). Recent threads — the first-read policy's window
/// the first time, the last week after that — fetched to the Mac and judged by the local reader like everything else.
public struct GmailSource: Source {
    public static let descriptor = SourceDescriptor(
        id: "gmail", name: "Gmail", detail: "Via your own Google sign-in · read-only",
        door: .userCloud, permissions: [])

    private let log = Log("source.gmail")
    static let bucket = BucketID("gmail:inbox")
    let transport: any JSONTransport
    let token: @Sendable () async throws -> String
    let policy: @Sendable () -> FirstRead
    public init(transport: any JSONTransport = URLSessionTransport(), token: @escaping @Sendable () async throws -> String = { try await GoogleAuth.shared.accessToken() },
                policy: @escaping @Sendable () -> FirstRead = { FirstRead.current }) {
        self.transport = transport; self.token = token; self.policy = policy
    }

    public func availability() async -> Availability {
        guard GoogleAuth.isConfigured else { return .unavailable("Needs a Google OAuth client (docs/launch-setup.md)") }
        return await GoogleAuth.shared.isSignedIn ? .available : .needsSignIn
    }

    /// What one listing asks Gmail for. A first read covers the policy's mail window and thread cap; once the inbox
    /// has been read to the bottom, a week is plenty between runs and the core keeps only what is newer than the mark.
    public struct Listing: Equatable, Sendable { public let query: String; public let maxThreads: Int }
    public static func listing(firstRead: Bool, policy: FirstRead) -> Listing {
        let days = firstRead ? policy.days(for: descriptor.id) : 7
        return Listing(query: "newer_than:\(days)d -category:promotions", maxThreads: firstRead ? policy.mailThreads : 100)
    }

    public func buckets(since marks: [BucketID: ItemKey], enabled: Set<BucketID>?) async throws -> [Bucket] {
        let token = try await token()
        let listing = Self.listing(firstRead: marks[Self.bucket] == nil, policy: policy())
        let q = listing.query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? listing.query
        var threads: [[String: Any]] = []
        var pageToken: String? = nil
        // Gmail hands back at most 500 threads a page; keep asking until the cap or the end of the window.
        repeat {
            let page = "https://gmail.googleapis.com/gmail/v1/users/me/threads?q=\(q)&maxResults=\(min(500, listing.maxThreads - threads.count))" + (pageToken.map { "&pageToken=\($0)" } ?? "")
            let list = try await get(page, token)
            threads += (list["threads"] as? [[String: Any]]) ?? []
            pageToken = list["nextPageToken"] as? String
        } while pageToken != nil && threads.count < listing.maxThreads
        // What the cap left behind: threads a page handed over past it, counted exactly, and a page never
        // asked for, counted as one — so the run never shows a silent gap.
        let deferred = max(0, threads.count - listing.maxThreads) + (pageToken != nil ? 1 : 0)
        threads = Array(threads.prefix(listing.maxThreads))
        if deferred > 0 { log.info("inbox: \(deferred) threads set aside past the cap of \(listing.maxThreads)") }
        var items: [Candidate] = []
        for (i, t) in threads.enumerated() {
            guard let id = t["id"] as? String else { continue }
            // historyId is monotonic; use it as the order so the cursor works without a second fetch.
            let order = Double((t["historyId"] as? String).flatMap(Int64.init) ?? Int64(threads.count - i))
            items.append(Candidate(source: Self.descriptor.id, bucket: Self.bucket, key: ItemKey(order: order, tiebreak: id), kind: .mail, id: id, itemDate: nil,
                                   metadata: ["name": "thread \(id)", "displayPath": "Gmail/inbox"]))
        }
        return [Bucket(id: Self.bucket, name: "Inbox", items: items.sorted { $0.key > $1.key }, deferred: deferred)]
    }

    public func load(_ c: Candidate) async throws -> Artifact {
        let token = try await token()
        let t = try await get("https://gmail.googleapis.com/gmail/v1/users/me/threads/\(c.id)?format=full", token)
        let msgs = (t["messages"] as? [[String: Any]]) ?? []
        var out = ""
        var date: Date?
        // The newest few messages carry the thread's live state; the reader does not need the opener from weeks ago.
        for m in msgs.suffix(policy().mailNewestMessages) {
            let headers = ((m["payload"] as? [String: Any])?["headers"] as? [[String: Any]]) ?? []
            func h(_ n: String) -> String { headers.first { ($0["name"] as? String)?.lowercased() == n }?["value"] as? String ?? "" }
            if let ms = (m["internalDate"] as? String).flatMap(Double.init) { date = Date(timeIntervalSince1970: ms / 1000) }   // ends on the newest
            out += "From: \(h("from"))\nTo: \(h("to"))\nDate: \(h("date"))\nSubject: \(h("subject"))\n\n\(Self.body(m["payload"] as? [String: Any]).prefix(6000))\n\n---\n"
        }
        var meta = c.metadata; meta["name"] = msgs.first.flatMap { (($0["payload"] as? [String: Any])?["headers"] as? [[String: Any]])?.first { ($0["name"] as? String) == "Subject" }?["value"] as? String } ?? "thread"
        return Artifact(candidate: Candidate(source: c.source, bucket: c.bucket, key: c.key, kind: c.kind, id: c.id, itemDate: date, metadata: meta), text: out)
    }

    static func body(_ payload: [String: Any]?) -> String {
        guard let payload else { return "" }
        if let parts = payload["parts"] as? [[String: Any]] {
            if let plain = parts.first(where: { ($0["mimeType"] as? String) == "text/plain" }) { return body(plain) }
            return parts.map(body).joined(separator: "\n")
        }
        guard let data = (payload["body"] as? [String: Any])?["data"] as? String else { return "" }
        let b64 = data.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = b64 + String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let d = Data(base64Encoded: padded), let s = String(data: d, encoding: .utf8) else { return "" }
        return (payload["mimeType"] as? String) == "text/html" ? s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression) : s
    }

    func get(_ url: String, _ token: String) async throws -> [String: Any] {
        let (data, status) = try await transport.request(URL(string: url)!, method: "GET", headers: ["Authorization": "Bearer \(token)"], body: nil)
        guard status == 200 else {
            let msg = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String ?? String(decoding: data.prefix(160), as: UTF8.self)
            if msg.contains("has not been used in project") || msg.contains("is disabled") { throw SourceError.cannotRead("the Gmail API isn't enabled for your Google project yet — enable it in Google Cloud Console, then run again") }
            if status == 401 { throw SourceError.cannotRead("Google sign-in expired — sign in again in Settings → Sources") }
            throw SourceError.cannotRead(msg)
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
