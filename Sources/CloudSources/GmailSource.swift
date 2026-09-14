import Foundation
import Domain
import Support

/// Gmail via the user's own Google account (readonly scope). Threads from the last 7 days,
/// fetched to the Mac and judged by the local reader like everything else.
public struct GmailSource: Source {
    public static let descriptor = SourceDescriptor(
        id: "gmail", name: "Gmail", detail: "Last 7 days, via your own Google sign-in",
        door: .userCloud, permissions: [])

    private let log = Log("source.gmail")
    static let bucket = BucketID("gmail:inbox")
    public init() {}

    public func availability() async -> Availability {
        guard GoogleAuth.isConfigured else { return .unavailable("Needs a Google OAuth client (docs/launch-setup.md)") }
        return await GoogleAuth.shared.isSignedIn ? .available : .needsSignIn
    }

    public func buckets(since marks: [BucketID: ItemKey], enabled: Set<BucketID>?) async throws -> [Bucket] {
        let token = try await GoogleAuth.shared.accessToken()
        let list = try await Self.get("https://gmail.googleapis.com/gmail/v1/users/me/threads?q=newer_than:7d%20-category:promotions&maxResults=100", token)
        let threads = (list["threads"] as? [[String: Any]]) ?? []
        var items: [Candidate] = []
        for (i, t) in threads.enumerated() {
            guard let id = t["id"] as? String else { continue }
            // historyId is monotonic; use it as the order so the cursor works without a second fetch.
            let order = Double((t["historyId"] as? String).flatMap(Int64.init) ?? Int64(threads.count - i))
            items.append(Candidate(source: Self.descriptor.id, bucket: Self.bucket, key: ItemKey(order: order, tiebreak: id), kind: .mail, id: id, itemDate: nil,
                                   metadata: ["name": "thread \(id)", "displayPath": "Gmail/inbox"]))
        }
        return [Bucket(id: Self.bucket, name: "Inbox", items: items.sorted { $0.key > $1.key })]
    }

    public func load(_ c: Candidate) async throws -> Artifact {
        let token = try await GoogleAuth.shared.accessToken()
        let t = try await Self.get("https://gmail.googleapis.com/gmail/v1/users/me/threads/\(c.id)?format=full", token)
        let msgs = (t["messages"] as? [[String: Any]]) ?? []
        var out = ""
        var date: Date?
        for m in msgs.prefix(8) {
            let headers = ((m["payload"] as? [String: Any])?["headers"] as? [[String: Any]]) ?? []
            func h(_ n: String) -> String { headers.first { ($0["name"] as? String)?.lowercased() == n }?["value"] as? String ?? "" }
            if date == nil, let ms = (m["internalDate"] as? String).flatMap(Double.init) { date = Date(timeIntervalSince1970: ms / 1000) }
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

    static func get(_ url: String, _ token: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!); req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String ?? String(decoding: data.prefix(160), as: UTF8.self)
            if msg.contains("has not been used in project") || msg.contains("is disabled") { throw SourceError.cannotRead("the Gmail API isn't enabled for your Google project yet — enable it in Google Cloud Console, then run again") }
            if (resp as? HTTPURLResponse)?.statusCode == 401 { throw SourceError.cannotRead("Google sign-in expired — sign in again in Settings → Sources") }
            throw SourceError.cannotRead(msg)
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
