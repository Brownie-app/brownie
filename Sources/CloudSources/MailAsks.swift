import Foundation
import Domain
import LocalSources
import Support

/// Mail read as a conversation, so the ask ledger can reach it.
///
/// Without this `MailSource` is a `Source` and nothing more: the nightly ask scan never asks it for anything,
/// so nothing anyone mails the user is ever a request, and nothing they mail back can close one. A thread is a
/// chat — the other people in it are the people, each message is a line, and the user's own address decides
/// which lines are theirs. Everything downstream (the verdicts, the ledger, the status block) is unchanged.
///
/// This existed over Gmail's API and was lost when that source went. It is back over IMAP, which means it now
/// works for iCloud, Outlook, Fastmail and a work server too — none of which Gmail's API ever covered.
extension MailSource: ChatReader, AskScanning {

    /// Threads read for asks in one night. The cap keeps a busy inbox from turning the scan into a crawl.
    static let askThreadCap = 60
    /// How far back the scan reaches, whatever the ledger asks for — an ask waiting since March does not make
    /// Brownie re-read March every night.
    static let askMaxDays = 60
    /// Per message, for the conversation read. Enough for a long mail and its quoted history, which `unquote`
    /// then cuts away; the reading pipeline's own `load` is separate and larger.
    static let askBodyBytes = 32 * 1024

    // MARK: - ChatReader

    public func chats() async throws -> [BucketInfo] {
        try await conversations(days: Self.askMaxDays).map(\.info)
    }

    public func messages(in bucket: BucketID, from: Date, to: Date) async throws -> [ChatMessage] {
        guard Self.threadKey(bucket) != nil else { return [] }
        let found = try await conversations(days: Self.askMaxDays).first { $0.info.id == bucket }
        return (found?.messages ?? []).filter { $0.date >= from && $0.date <= to }
    }

    // MARK: - AskScanning

    /// One SEARCH, one header FETCH, one body FETCH, then the same detector every other channel uses. A thread
    /// with more than one other person in it is a group: only a line that names the user counts there.
    public func recentAsks(enabled: Set<BucketID>?, scan: AskScan) async throws -> [Ask] {
        guard MailAccount.isSignedIn else { return [] }
        let now = Date()
        let oldest = min(scan.since, scan.sinceByBucket.filter { $0.key.rawValue.hasPrefix("mail:") }.values.min() ?? scan.since)
        let days = min(Self.askMaxDays, max(1, Int(ceil(now.timeIntervalSince(oldest) / 86400)) + 1))

        var out: [Ask] = []
        for c in try await conversations(days: days) {
            // `enabled` is nil for a source with no per-bucket opt-in, and mail has none: the user chose a
            // mailbox, not a list of threads. A set, when one is given, still decides.
            if let enabled, !enabled.contains(c.info.id) { continue }
            let since = scan.since(c.info.id)
            out += AskDetector.detect(c.messages, person: c.info.name, bucket: c.info.id, since: since,
                                      handle: c.info.handle, judged: scan.judgedReplies,
                                      isGroup: c.info.isGroup, selfNames: scan.selfNames)
        }
        return out
    }

    // MARK: - Reading the mailbox as conversations

    struct Conversation: Sendable {
        let info: BucketInfo
        let messages: [ChatMessage]
    }

    static func threadBucket(_ key: String) -> BucketID { BucketID("mail:thread:\(key)") }
    static func threadKey(_ b: BucketID) -> String? {
        let p = "mail:thread:"
        guard b.rawValue.hasPrefix(p) else { return nil }
        let k = String(b.rawValue.dropFirst(p.count))
        return k.isEmpty ? nil : k
    }

    /// The whole of it, in one connection: what is there, who it is with, and what was said.
    ///
    /// Three commands, not three per thread. The headers come back for every message in the window at once and
    /// the threading is worked out on this Mac; only the capped set of live conversations has its bodies
    /// fetched, and those arrive in a single UID FETCH.
    ///
    /// Held briefly afterwards, because the callers ask repeatedly. The evidence gate looks a person up once
    /// per open loop, and a busy week has twenty — without the cache that is twenty whole mailbox reads over
    /// TLS to answer twenty questions, which is the same mistake `SourceLines.Directory` exists to avoid for
    /// the chat sources.
    func conversations(days: Int) async throws -> [Conversation] {
        if let had = await MailConversations.shared.get(days) { return had }
        let fresh = try await readConversations(days: days)
        await MailConversations.shared.put(days, fresh)
        return fresh
    }

    private func readConversations(days: Int) async throws -> [Conversation] {
        guard let me = MailAccount.address?.lowercased(), !me.isEmpty else { return [] }
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        let (heads, bodies) = try await pool.withSession { s -> ([IMAPSession.Header], [String: String]) in
            _ = try await s.examine("INBOX")
            let gmail = (try? await s.capabilities().contains("X-GM-EXT-1")) ?? false
            // Gmail can filter its own categories; nobody else can, and a plain SINCE is the honest fallback.
            var seqs: [Int] = []
            if gmail { seqs = (try? await s.search(gmailRaw: "newer_than:\(days)d -category:promotions")) ?? [] }
            if seqs.isEmpty { seqs = try await s.search(since: since) }
            guard !seqs.isEmpty else { return ([], [:]) }
            let heads = try await s.headers(seqs, threadIDs: gmail)

            // Thread first, cap second: the cap has to fall on conversations, not on messages, or a thread
            // arrives with its question read and its answer missing.
            let threads = MailThreads.group(heads.map {
                MailThreads.Message(uid: $0.uid, date: $0.date, fields: $0.fields, threadID: $0.threadID)
            }).prefix(Self.askThreadCap)
            let uids = threads.flatMap { $0.messages.map(\.uid) }
            return (heads, try await s.messages(uids: uids, limit: Self.askBodyBytes))
        }
        guard !heads.isEmpty else { return [] }

        let threads = MailThreads.group(heads.map {
            MailThreads.Message(uid: $0.uid, date: $0.date, fields: $0.fields, threadID: $0.threadID)
        }).prefix(Self.askThreadCap)

        return threads.compactMap { t in
            guard let who = Self.correspondent(t, me: me) else { return nil }
            let msgs = Self.lines(t, bodies: bodies, me: me)
            guard !msgs.isEmpty else { return nil }
            let info = BucketInfo(id: Self.threadBucket(t.key), name: who.name,
                                  detail: t.messages.first?.fields["subject"] ?? "", isGroup: who.others > 1,
                                  count: msgs.count, handle: who.others > 1 ? nil : PersonHandle.mail(who.address))
            return Conversation(info: info, messages: msgs)
        }
    }

    /// Who the thread is with, and how many people that is besides the user. The first address in it that is
    /// not the user's own names the thread, the way a chat is named after the person in it.
    static func correspondent(_ t: MailThreads.Thread, me: String) -> (name: String, address: String, others: Int)? {
        var first: (String, String)?
        var addresses = Set<String>()
        for m in t.messages {
            let fromAddress = MailParsing.address(m.fields["from"] ?? "")
            for value in [m.fields["from"], m.fields["to"], m.fields["cc"]].compactMap({ $0 }) {
                for part in value.split(separator: ",") {
                    let piece = String(part)
                    guard let address = MailParsing.address(piece)?.lowercased(), address != me, !address.isEmpty else { continue }
                    addresses.insert(address)
                    if first == nil, fromAddress?.lowercased() == address {
                        first = (MailParsing.decodeWords(MailParsing.displayName(piece)), address)
                    }
                }
            }
        }
        guard let first = first ?? addresses.sorted().first.map({ (String($0.prefix { $0 != "@" }), $0) }) else { return nil }
        return (first.0, first.1, addresses.count)
    }

    /// The thread as chat lines, oldest first. The subject rides on the first message only, because it is
    /// context and not something anyone said twice; quoted history is cut, or every reply would read as a
    /// repeat of the question it answers.
    static func lines(_ t: MailThreads.Thread, bodies: [String: String], me: String) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for (i, m) in t.messages.enumerated() {
            guard let date = m.date else { continue }
            let raw = bodies[m.uid] ?? ""
            let headers = MailParsing.headers(raw)
            let blank = raw.range(of: "\r\n\r\n") ?? raw.range(of: "\n\n")
            let body = unquote(MailParsing.body(blank.map { String(raw[$0.upperBound...]) } ?? "", headers: headers))
            let subject = MailParsing.decodeWords(m.fields["subject"] ?? "").trimmingCharacters(in: .whitespaces)
            var text = body
            if i == 0, !subject.isEmpty { text = text.isEmpty ? subject : subject + "\n" + text }
            text = String(text.prefix(4000)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let from = MailParsing.address(m.fields["from"] ?? "")?.lowercased()
            out.append(ChatMessage(rowID: Int64(date.timeIntervalSince1970), date: date,
                                   sender: from == me ? "Me" : MailParsing.decodeWords(MailParsing.displayName(m.fields["from"] ?? "")),
                                   isMe: from == me, text: text))
        }
        return out
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
            if lower.hasPrefix("-----original message") { break }
            if lower.hasPrefix("________________________________") { break }
            if lower.hasPrefix("on "), lower.hasSuffix("wrote:") { break }
            if t == "--" || t == "-- " { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A few minutes of memory, so one night's questions cost one night's reading.
///
/// Deliberately not a permanent store: mail that arrives mid-run should be seen by the next run, and a cache
/// that outlived the run would be a second copy of the user's inbox for no reason.
actor MailConversations {
    static let shared = MailConversations()
    private var entries: [Int: (at: Date, value: [MailSource.Conversation])] = [:]
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 180) { self.ttl = ttl }

    func get(_ days: Int) -> [MailSource.Conversation]? {
        guard let e = entries[days], Date().timeIntervalSince(e.at) < ttl else { return nil }
        return e.value
    }
    func put(_ days: Int, _ value: [MailSource.Conversation]) { entries[days] = (Date(), value) }
    /// Dropped when the account changes, so a second mailbox never answers for the first.
    func forget() { entries.removeAll() }
}
