import Foundation
import Domain
import LocalSources

/// The one seam between a cloud source and the network: a GET/POST that returns JSON. Tests hand in fixtures.
public protocol JSONTransport: Sendable {
    func request(_ url: URL, method: String, headers: [String: String], body: Data?) async throws -> (Data, Int)
}

public extension JSONTransport {
    func json(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) async throws -> [String: Any] {
        let (data, status) = try await request(url, method: method, headers: headers, body: body)
        guard (200..<300).contains(status) else {
            if status == 401 { throw SourceError.cannotRead("sign-in expired — sign in again in Settings → Sources") }
            let msg = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String ?? $0["error"] as? String }) ?? String(decoding: data.prefix(160), as: UTF8.self)
            throw SourceError.cannotRead("HTTP \(status): \(msg)")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

public struct URLSessionTransport: JSONTransport {
    public init() {}
    public func request(_ url: URL, method: String, headers: [String: String], body: Data?) async throws -> (Data, Int) {
        var req = URLRequest(url: url); req.httpMethod = method; req.httpBody = body; req.timeoutInterval = 60
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Shared by the chat-shaped cloud sources: a window of one conversation becomes one candidate.
enum CloudChat {
    static func candidates(source: SourceID, bucket: BucketID, name: String, isGroup: Bool, members: Int, messages: [ChatMessage], extra: [String: String] = [:]) -> [Candidate] {
        let chat = ChatInfo(id: bucket.rawValue, name: name, isGroup: isGroup, memberCount: members)
        return ChatWindowing.windows(messages, chat: chat).map { w in
            Candidate(source: source, bucket: bucket, key: ItemKey(order: w.lastDate.timeIntervalSince1970, tiebreak: String(w.lastRowID)), kind: isGroup ? .groupChat : .directMessage,
                      id: "\(bucket.rawValue):\(w.lastRowID)", itemDate: w.lastDate,
                      metadata: ["chat": name, "isGroup": isGroup ? "1" : "0", "members": String(members), "firstDate": String(w.firstDate.timeIntervalSince1970), "lastDate": String(w.lastDate.timeIntervalSince1970)].merging(extra) { $1 })
        }.reversed()
    }
    /// The text the reader sees for one candidate: the window's messages, clamped.
    static func text(name: String, isGroup: Bool, members: Int, messages: [ChatMessage]) -> String {
        let chat = ChatInfo(id: "", name: name, isGroup: isGroup, memberCount: members)
        return ChatWindowing.clamp(ChatWindowing.windows(messages, chat: chat).map(\.text).joined(separator: "\n\n"))
    }
    /// Messages between a candidate's window bounds, inclusive.
    static func slice(_ messages: [ChatMessage], of c: Candidate) -> [ChatMessage] {
        let first = Double(c.metadata["firstDate"] ?? "") ?? 0, last = Double(c.metadata["lastDate"] ?? "") ?? .greatestFiniteMagnitude
        return messages.filter { $0.date.timeIntervalSince1970 >= first - 0.001 && $0.date.timeIntervalSince1970 <= last + 0.001 }
    }
}
