import Foundation
import Domain
import LocalSources
import Support

/// Mail read as a conversation, so the ask ledger can reach it.
///
/// Until this existed `GmailSource` was a `Source` and nothing more: the nightly ask scan never asked it for
/// anything, so nothing anyone mailed the user was ever a request, and nothing they mailed back could close one.
/// A thread is a chat — the other people in it are the people, each message is a line, and the user's own address
/// decides which lines are theirs. Everything downstream (the verdicts, the ledger, the status block) is unchanged.
extension GmailSource: ChatReader, AskScanning {
    /// Threads read for asks in one night. Mail is listed in one call and then fetched one thread at a time, so
    /// this is the nightly cost in requests; the cap keeps a busy inbox from turning the scan into a crawl.
    static let askThreadCap = 60
    /// How far back the listing reaches, whatever the ledger asks for — an ask waiting since March does not make
    /// Brownie re-read March every night.
    static let askMaxDays = 60

    public func chats() async throws -> [BucketInfo] {
        let token = try await token()
        let me = try await address(token)
        var out: [BucketInfo] = []
        for id in try await threadIDs(token, days: 30, cap: Self.askThreadCap) {
            guard let t = try? await thread(id, token) else { continue }
            let msgs = Self.messages(in: t, me: me)
            guard let (name, address, others) = Self.correspondent(t, me: me), !msgs.isEmpty else { continue }
            out.append(BucketInfo(id: Self.threadBucket(id), name: name, detail: Self.subject(t), isGroup: others > 1,
                                  count: msgs.count, handle: others > 1 ? nil : PersonHandle.mail(address)))
        }
        return out
    }

    public func messages(in bucket: BucketID, from: Date, to: Date) async throws -> [ChatMessage] {
        guard let id = Self.threadID(bucket) else { return [] }
        let token = try await token()
        let me = try await address(token)
        return Self.messages(in: try await thread(id, token), me: me).filter { $0.date >= from && $0.date <= to }
    }

    /// One listing, then one fetch per thread, then the same detector every other channel uses. A thread with more
    /// than one other person in it is a group: only a line that names the user counts there, as in any group chat.
    public func recentAsks(enabled: Set<BucketID>?, scan: AskScan) async throws -> [Ask] {
        guard enabled?.contains(Self.bucket) ?? false else { return [] }
        let token = try await token()
        let me = try await address(token)
        let now = Date()
        let oldest = min(scan.since, scan.sinceByBucket.filter { $0.key.rawValue.hasPrefix("gmail:") }.values.min() ?? scan.since)
        let days = min(Self.askMaxDays, max(1, Int(ceil(now.timeIntervalSince(oldest) / 86400)) + 1))
        var out: [Ask] = []
        for id in try await threadIDs(token, days: days, cap: Self.askThreadCap) {
            let bucket = Self.threadBucket(id)
            guard let t = try? await thread(id, token) else { continue }
            guard let (name, address, others) = Self.correspondent(t, me: me) else { continue }
            let since = scan.since(bucket)
            out += AskDetector.detect(Self.messages(in: t, me: me), person: name, bucket: bucket, since: since,
                                      handle: others > 1 ? nil : PersonHandle.mail(address), judged: scan.judgedReplies,
                                      isGroup: others > 1, selfNames: scan.selfNames)
        }
        return out
    }

    // MARK: - The wire

    static func threadBucket(_ id: String) -> BucketID { BucketID("gmail:\(id)") }
    /// The thread id inside a bucket, or nil for the inbox bucket the reading pipeline uses.
    static func threadID(_ b: BucketID) -> String? {
        let id = String(b.rawValue.dropFirst("gmail:".count))
        return b.rawValue.hasPrefix("gmail:") && id != "inbox" && !id.isEmpty ? id : nil
    }

    func threadIDs(_ token: String, days: Int, cap: Int) async throws -> [String] {
        let q = "newer_than:\(days)d -category:promotions".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let list = try await get("https://gmail.googleapis.com/gmail/v1/users/me/threads?q=\(q)&maxResults=\(cap)", token)
        return ((list["threads"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
    }
    func thread(_ id: String, _ token: String) async throws -> [String: Any] {
        try await get("https://gmail.googleapis.com/gmail/v1/users/me/threads/\(id)?format=full", token)
    }
    /// The signed-in address, which is what makes a line the user's own.
    func address(_ token: String) async throws -> String {
        ((try await get("https://gmail.googleapis.com/gmail/v1/users/me/profile", token))["emailAddress"] as? String ?? "").lowercased()
    }

    // MARK: - Reading a thread

    static func header(_ m: [String: Any], _ name: String) -> String {
        let hs = ((m["payload"] as? [String: Any])?["headers"] as? [[String: Any]]) ?? []
        return hs.first { ($0["name"] as? String)?.lowercased() == name }?["value"] as? String ?? ""
    }
    static func subject(_ t: [String: Any]) -> String {
        ((t["messages"] as? [[String: Any]]) ?? []).first.map { header($0, "subject") } ?? ""
    }

    /// A name and an address out of one header value: `Devika Ranganathan <devika@raghavan-co.in>`, or a bare
    /// address, in which case the part before the @ stands in as a name.
    static func parse(_ value: String) -> (name: String, address: String)? {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return nil }
        if let open = v.lastIndex(of: "<"), let close = v[open...].firstIndex(of: ">") {
            let address = String(v[v.index(after: open)..<close]).trimmingCharacters(in: .whitespaces).lowercased()
            let name = String(v[..<open]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")).trimmingCharacters(in: .whitespaces)
            guard address.contains("@") else { return nil }
            return (name.isEmpty ? String(address.prefix { $0 != "@" }) : name, address)
        }
        guard v.contains("@") else { return nil }
        let address = v.lowercased()
        return (String(address.prefix { $0 != "@" }), address)
    }

    /// Who the thread is with, and how many people that is besides the user. The first address in it that is not
    /// the user's own names the thread, the way a chat is named after the person in it.
    static func correspondent(_ t: [String: Any], me: String) -> (name: String, address: String, others: Int)? {
        var first: (String, String)?
        var addresses = Set<String>()
        for m in (t["messages"] as? [[String: Any]]) ?? [] {
            for value in [header(m, "from"), header(m, "to"), header(m, "cc")] {
                for part in value.split(separator: ",") {
                    guard let p = parse(String(part)), p.address != me, !p.address.isEmpty else { continue }
                    addresses.insert(p.address)
                    if first == nil, !header(m, "from").isEmpty, parse(header(m, "from"))?.address == p.address { first = (p.name, p.address) }
                }
            }
        }
        guard let first = first ?? addresses.sorted().first.map({ (String($0.prefix { $0 != "@" }), $0) }) else { return nil }
        return (first.0, first.1, addresses.count)
    }

    /// The thread as chat lines, oldest first. The subject rides on the first message only, because it is context
    /// and not something anyone said twice; quoted history is cut, or every reply would read as a repeat of the
    /// question it answers.
    static func messages(in t: [String: Any], me: String) -> [ChatMessage] {
        let all = (t["messages"] as? [[String: Any]]) ?? []
        var out: [ChatMessage] = []
        for (i, m) in all.enumerated() {
            guard let ms = (m["internalDate"] as? String).flatMap(Double.init) else { continue }
            let from = parse(header(m, "from"))
            let body = unquote(GmailSource.body(m["payload"] as? [String: Any]))
            let subject = header(m, "subject").trimmingCharacters(in: .whitespaces)
            var text = body
            if i == 0, !subject.isEmpty { text = text.isEmpty ? subject : subject + "\n" + text }
            text = String(text.prefix(4000)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            out.append(ChatMessage(rowID: Int64(ms), date: Date(timeIntervalSince1970: ms / 1000),
                                   sender: from?.address == me ? "Me" : (from?.name ?? "someone"),
                                   isMe: from?.address == me, text: text))
        }
        return out.sorted { $0.date < $1.date }
    }

    /// A reply without the mail it is replying to: quoted lines, the "On … wrote:" attribution that introduces
    /// them, the Outlook divider, and a trailing signature block.
    static func unquote(_ s: String) -> String {
        var kept: [String] = []
        for raw in s.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(">") { continue }
            let lower = t.lowercased()
            if lower.hasPrefix("-----original message"), true { break }
            if lower.hasPrefix("________________________________") { break }
            if lower.hasPrefix("on "), lower.hasSuffix("wrote:") { break }
            if t == "--" || t == "-- " { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
