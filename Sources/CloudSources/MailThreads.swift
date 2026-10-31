import Foundation

/// Grouping a mailbox into conversations, which is the one thing IMAP will not do for you.
///
/// Gmail's API handed back a `threadId` with every message, and losing that is what took asks and loops out
/// of mail when the OAuth source went. It turns out IMAP gives it back two different ways, and this picks
/// whichever the server offers:
///
///   1. **Gmail, exactly.** `X-GM-THRID` is the same 64-bit thread id the API returns, available over IMAP to
///      any client that sees `X-GM-EXT-1` in CAPABILITY. When it is there, there is nothing to work out.
///   2. **Everyone else, by the headers RFC 5322 already requires.** A reply carries `In-Reply-To` and
///      `References` naming the mail it answers. Union those and the chains fall out — iCloud, Outlook,
///      Fastmail and a work server all thread the same way, which Gmail's API never did for them.
///
/// Pure, and tested on its own: the shapes that break threading are real mailers' output, not protocol.
public enum MailThreads {

    /// One message, as far as threading is concerned.
    public struct Message: Sendable, Equatable {
        public let uid: String
        public let date: Date?
        public let fields: [String: String]
        /// Gmail's own thread id, when the server offered it.
        public let threadID: String?
        public init(uid: String, date: Date?, fields: [String: String], threadID: String? = nil) {
            self.uid = uid; self.date = date; self.fields = fields; self.threadID = threadID
        }
        var messageID: String? { MailThreads.id(fields["message-id"]) }
    }

    /// A conversation: its stable key and its messages, oldest first.
    public struct Thread: Sendable, Equatable {
        public let key: String
        public let messages: [Message]
        /// The newest thing in it, which is how threads are ordered and capped.
        public var last: Date? { messages.compactMap(\.date).max() }
    }

    // MARK: - Grouping

    /// Conversations, newest-last message first, so a cap keeps the threads that are still alive.
    public static func group(_ messages: [Message]) -> [Thread] {
        var union = Union()

        // Gmail's id, where it exists, is authoritative: it is the same number the web interface threads on.
        for m in messages {
            let own = key(for: m)
            if let t = m.threadID { union.merge(own, "gm:" + t); continue }
            // Otherwise every id this message mentions belongs to one conversation with this message.
            for other in references(m) { union.merge(own, other) }
        }

        // Mailers that drop References entirely — some phone clients, most "reply" buttons in web apps — leave
        // a reply stranded from its question. JWZ's rule: join two conversations on an identical subject only
        // when one of them is visibly a reply, so "Hi" and "Hi" from two strangers stay apart.
        var bySubject: [String: [String]] = [:]
        for m in messages where references(m).isEmpty || m.threadID == nil {
            let s = normalisedSubject(m.fields["subject"] ?? "")
            guard !s.isEmpty else { continue }
            bySubject[s, default: []].append(key(for: m))
        }
        for (subject, keys) in bySubject where keys.count > 1 {
            guard messages.contains(where: { normalisedSubject($0.fields["subject"] ?? "") == subject && isReply($0.fields["subject"] ?? "") }) else { continue }
            for k in keys.dropFirst() { union.merge(keys[0], k) }
        }

        var grouped: [String: [Message]] = [:]
        for m in messages { grouped[union.find(key(for: m)), default: []].append(m) }
        return grouped.values
            .map { msgs in
                let sorted = msgs.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
                return Thread(key: stable(root(of: sorted)), messages: sorted)
            }
            .sorted { ($0.last ?? .distantPast) > ($1.last ?? .distantPast) }
    }

    /// The conversation's name for itself, which has to survive the conversation growing and the window sliding.
    ///
    /// Not the union-find root: that is whichever id the merges happened to settle on, and it moves when a reply
    /// arrives. A thread whose key moves is a thread whose asks all reopen as new ones the next night — which is
    /// the one failure that would make this feature worse than not having it.
    ///
    /// So: of every id the thread mentions, take one that nothing in the thread claims as its own while also
    /// citing a parent. That is the message the chain started from. It keeps working after the original itself
    /// ages out of the window, because every reply still names it in `References`.
    static func root(of messages: [Message]) -> String {
        if let t = messages.compactMap(\.threadID).first { return "gm:" + t }
        var mentioned = Set<String>(), replies = Set<String>()
        for m in messages {
            let own = key(for: m)
            mentioned.insert(own)
            let refs = references(m)
            mentioned.formUnion(refs)
            if !refs.isEmpty { replies.insert(own) }
        }
        let origins = mentioned.subtracting(replies)
        return (origins.isEmpty ? mentioned : origins).min() ?? key(for: messages[0])
    }

    /// What this message calls itself. A mail with no `Message-ID` — rare, but a few mailers really do omit it —
    /// still has to be its own conversation rather than joining everyone else's.
    static func key(for m: Message) -> String { m.messageID ?? "uid:" + m.uid }

    /// Every message id this one names, `In-Reply-To` and `References` together.
    static func references(_ m: Message) -> [String] {
        var out: [String] = []
        for field in ["in-reply-to", "references"] {
            guard let v = m.fields[field] else { continue }
            out += ids(v)
        }
        return out
    }

    /// `<a@x> <b@y>` → `["a@x", "b@y"]`. Anything not in angle brackets is ignored: `References` is defined as a
    /// list of msg-ids, and the junk some mailers put there is not one.
    static func ids(_ value: String) -> [String] {
        value.split(separator: "<").compactMap { part in
            guard let close = part.firstIndex(of: ">") else { return nil }
            let id = String(part[..<close]).trimmingCharacters(in: .whitespaces)
            return id.isEmpty ? nil : id
        }
    }

    /// One id out of a `Message-ID` header, brackets off.
    static func id(_ value: String?) -> String? {
        guard let value else { return nil }
        return ids(value).first ?? {
            let t = value.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }()
    }

    /// `Re: Fwd: [team] the figures` → `the figures`. Repeated because real subjects stack the prefixes up.
    public static func normalisedSubject(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            if let m = try? #/^(?:[Rr][Ee]|[Ff][Ww]|[Ff][Ww][Dd]|[Aa][Nn][Tt][Ww]|[Ss][Vv])\s*(?:\[\d+\])?\s*:\s*/#.prefixMatch(in: t) {
                t = String(t[m.range.upperBound...]); changed = true
            }
            if let m = try? #/^\[[^\]]{1,40}\]\s*/#.prefixMatch(in: t) {
                t = String(t[m.range.upperBound...]); changed = true
            }
        }
        return t.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Whether the subject says, in any of the spellings mailers use, that this is a reply.
    static func isReply(_ s: String) -> Bool {
        (try? #/^\s*(?:[Rr][Ee]|[Ff][Ww]|[Ff][Ww][Dd]|[Aa][Nn][Tt][Ww]|[Ss][Vv])\s*(?:\[\d+\])?\s*:/#.prefixMatch(in: s)) != nil
    }

    /// A conversation key short enough to live in a `BucketID` and stable across runs: the same thread read
    /// tonight and tomorrow night has to produce the same id, or every ask reopens as a new one.
    static func stable(_ raw: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325                               // FNV-1a, because it needs to be stable, not secret
        for b in raw.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 36)
    }

    // MARK: - Union-find

    /// Small and non-generic on purpose: the whole threading pass runs over one night's inbox.
    struct Union {
        private var parent: [String: String] = [:]
        mutating func find(_ a: String) -> String {
            var root = a
            while let p = parent[root], p != root { root = p }
            var walk = a                                                 // path compression, so a long chain is paid for once
            while let p = parent[walk], p != walk { parent[walk] = root; walk = p }
            return root
        }
        mutating func merge(_ a: String, _ b: String) {
            parent[a] = parent[a] ?? a; parent[b] = parent[b] ?? b
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }
    }
}
