import Foundation
import Network
import Domain
import Support

/// Enough IMAP4rev1 to read a mailbox, and deliberately no more.
///
/// Brownie talks to the mail server the way it talks to a chat database: straight from this Mac, with no API
/// key, no quota and nobody in between. That is also why this is hand-written rather than pulled in — a mail
/// client that reads someone's inbox should be a file you can read in one sitting.
///
/// Two commands do all the work, and they split along the same line the `Source` protocol does: SEARCH and a
/// header FETCH list what is there (cheap, every message), and a second FETCH pulls one whole message
/// (expensive, only the ones the reader will actually judge). No body is ever downloaded for a message that
/// gets dropped on its subject line.

// MARK: - The wire

/// The bytes, so the protocol above can be tested without a server.
public protocol IMAPTransport: Sendable {
    func connect(host: String, port: UInt16) async throws
    func write(_ s: String) async throws
    /// One line, CRLF consumed and removed.
    func readLine() async throws -> String
    /// Exactly `count` bytes, for an IMAP literal.
    func read(_ count: Int) async throws -> String
    func disconnect() async
}

public enum IMAPError: Error, Equatable {
    /// The server said NO or BAD. `text` is its own words, which are worth showing: they are often the clearest
    /// thing the user will see, and Gmail in particular hides the real cause behind a URL in this string.
    case rejected(String)
    case closed
    case timedOut
    case cannotConnect(String)
}

// MARK: - The session

/// One connection, one mailbox. Not reusable across runs: open it, read, close it.
public actor IMAPSession {
    private let t: any IMAPTransport
    private var n = 0
    private let log = Log("source.mail")

    public init(transport: any IMAPTransport) { self.t = transport }

    private func tag() -> String { n += 1; return String(format: "a%03d", n) }

    /// Sends one command and gathers everything until its tagged completion.
    ///
    /// An IMAP line can end in a literal — `{1234}` — meaning the next 1234 bytes are data rather than
    /// protocol, and the line continues after them. Folding those in here is what lets everything above treat
    /// a response as plain text.
    @discardableResult
    private func command(_ body: String, logging: String? = nil) async throws -> [String] {
        let tg = tag()
        try await t.write("\(tg) \(body)\r\n")
        var lines: [String] = [], current = ""
        while true {
            let line = try await t.readLine()
            if let m = try? #/\{(\d+)\}$/#.firstMatch(in: line), let count = Int(m.1) {
                current += String(line.dropLast(m.0.count)) + (try await t.read(count))
                continue
            }
            current += line
            if current.hasPrefix(tg + " ") {
                let rest = String(current.dropFirst(tg.count + 1))
                if rest.hasPrefix("OK") { return lines }
                throw IMAPError.rejected(String(rest.dropFirst(rest.hasPrefix("NO") ? 3 : 4)).trimmingCharacters(in: .whitespaces))
            }
            lines.append(current); current = ""
        }
    }

    public func connect(host: String, port: UInt16) async throws {
        try await t.connect(host: host, port: port)
        _ = try await t.readLine()                                  // the greeting, which we only need to have arrived
    }

    /// LOGIN with the password quoted, because an app password is sixteen characters of anything.
    public func login(user: String, password: String) async throws {
        try await command("LOGIN \(quoted(user)) \(quoted(password))")
    }

    /// Selects read-only. EXAMINE rather than SELECT so nothing is ever marked as read by Brownie having
    /// looked — the user's unread count is theirs, and a background job must not touch it.
    @discardableResult
    public func examine(_ mailbox: String) async throws -> Int {
        let lines = try await command("EXAMINE \(quoted(mailbox))")
        for l in lines { if let m = try? #/^\* (\d+) EXISTS/#.firstMatch(in: l) { return Int(m.1) ?? 0 } }
        return 0
    }

    /// The sequence numbers of everything since a day, newest last. IMAP's SINCE is by date, not by instant.
    public func search(since: Date) async throws -> [Int] {
        let lines = try await command("SEARCH SINCE \(MailParsing.searchDay(since))")
        guard let hit = lines.first(where: { $0.hasPrefix("* SEARCH") }) else { return [] }
        return hit.dropFirst("* SEARCH".count).split(separator: " ").compactMap { Int($0) }
    }

    /// A mailbox and what the server says it is for.
    public struct Mailbox: Sendable, Equatable {
        public let name: String
        /// The LIST attributes, upper-cased: `\HASNOCHILDREN`, and for a SPECIAL-USE server `\SENT`, `\DRAFTS`…
        public let attributes: Set<String>
    }

    /// Mailboxes the account has, as `LIST` reports them. Used to find where mail actually lives, since every
    /// server names its folders differently and only the inbox is called INBOX by the standard.
    public func list() async throws -> [Mailbox] {
        let lines = try await command("LIST \"\" \"*\"")
        return lines.compactMap { line -> Mailbox? in
            guard line.hasPrefix("* LIST") else { return nil }
            let attrs = (try? #/^\* LIST \(([^)]*)\)/#.firstMatch(in: line)).map {
                Set(String($0.1).split(separator: " ").map { $0.uppercased() })
            } ?? []
            // The name is the last token, quoted when it has a space in it.
            let name: String?
            if let q = line.range(of: "\"", options: .backwards), let o = line.range(of: "\"", options: .backwards, range: line.startIndex..<q.lowerBound) {
                name = String(line[o.upperBound..<q.lowerBound])
            } else {
                name = line.split(separator: " ").last.map(String.init)
            }
            guard let name, !name.isEmpty, name != "/" else { return nil }
            return Mailbox(name: name, attributes: attrs)
        }
    }

    /// Where this server keeps the mail the user sent.
    ///
    /// It has to be found rather than assumed, and it is not optional: a reply lives here and nowhere else, so
    /// without it Brownie sees the question it was asked and never the answer it gave — an ask that opens and
    /// can never close. `\Sent` is the SPECIAL-USE attribute (RFC 6154) and is what most servers now publish;
    /// the names are the fallback for the ones that do not, Gmail's localised `[Gmail]/Sent Mail` included.
    public func sentMailbox() async throws -> String? {
        let boxes = try await list()
        if let flagged = boxes.first(where: { $0.attributes.contains("\\SENT") }) { return flagged.name }
        let known = ["sent", "sent items", "sent messages", "sent mail", "[gmail]/sent mail", "inbox.sent", "inbox/sent"]
        return boxes.first { known.contains($0.name.lowercased()) }?.name
    }

    /// What the server says it can do. Only one answer is acted on — `X-GM-EXT-1`, which is Gmail offering its
    /// own thread ids and its own search syntax over plain IMAP.
    public func capabilities() async throws -> Set<String> {
        let lines = try await command("CAPABILITY")
        guard let line = lines.first(where: { $0.uppercased().hasPrefix("* CAPABILITY") }) else { return [] }
        return Set(line.dropFirst("* CAPABILITY".count).split(separator: " ").map { $0.uppercased() })
    }

    /// Gmail's search, over IMAP. `X-GM-RAW` takes the same syntax as the web interface, which is the only way
    /// to say `-category:promotions` — there is no IMAP SEARCH key for a Gmail category, and without it a
    /// night reads every newsletter that arrived.
    public func search(gmailRaw query: String) async throws -> [Int] {
        let lines = try await command("SEARCH X-GM-RAW \(quoted(query))")
        guard let hit = lines.first(where: { $0.hasPrefix("* SEARCH") }) else { return [] }
        return hit.dropFirst("* SEARCH".count).split(separator: " ").compactMap { Int($0) }
    }

    /// One batch of headers. Deliberately not the whole message: this runs over every message in the window.
    public struct Header: Sendable, Equatable {
        public let seq: Int
        public let uid: String
        public let date: Date?
        public let fields: [String: String]
        /// Gmail's `X-GM-THRID`, when it was asked for and the server is Gmail. Nil everywhere else, and the
        /// threading falls back to `References`.
        public let threadID: String?
        public init(seq: Int, uid: String, date: Date?, fields: [String: String], threadID: String? = nil) {
            self.seq = seq; self.uid = uid; self.date = date; self.fields = fields; self.threadID = threadID
        }
    }

    /// `IN-REPLY-TO` and `REFERENCES` ride along with the rest: they cost a few bytes a message on a fetch that
    /// is already happening, and they are the whole of threading on a server that is not Gmail.
    static let headerFields = "FROM TO CC SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES LIST-ID"

    public func headers(_ seqs: [Int], threadIDs: Bool = false) async throws -> [Header] {
        guard !seqs.isEmpty else { return [] }
        let set = seqs.map(String.init).joined(separator: ",")
        let items = (threadIDs ? "X-GM-THRID " : "") + "UID INTERNALDATE BODY.PEEK[HEADER.FIELDS (\(Self.headerFields))]"
        let lines = try await command("FETCH \(set) (\(items))")
        return lines.compactMap { line in
            guard let m = try? #/^\* (\d+) FETCH /#.firstMatch(in: line), let seq = Int(m.1) else { return nil }
            let uid = (try? #/UID (\d+)/#.firstMatch(in: line)).map { String($0.1) } ?? String(seq)
            let date = (try? #/INTERNALDATE "([^"]+)"/#.firstMatch(in: line)).flatMap { MailParsing.internalDate(String($0.1)) }
            let thrid = (try? #/X-GM-THRID (\d+)/#.firstMatch(in: line)).map { String($0.1) }
            // Everything after the last `]` of the BODY section is the folded-in literal.
            guard let bracket = line.range(of: "]", options: .backwards) else { return nil }
            let raw = String(line[bracket.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " )"))
            return Header(seq: seq, uid: uid, date: date, fields: MailParsing.headers(raw), threadID: thrid)
        }
    }

    /// One whole message, capped. Peeked, so reading it does not mark it seen.
    public func message(uid: String, limit: Int) async throws -> String {
        let lines = try await command("UID FETCH \(uid) (BODY.PEEK[]<0.\(limit)>)")
        guard let line = lines.first(where: { $0.contains(" FETCH ") }), let bracket = line.range(of: ">", options: .backwards) ?? line.range(of: "]", options: .backwards) else { return "" }
        return String(line[bracket.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " )"))
    }

    /// Whole messages for a set of UIDs, in one command rather than one each.
    ///
    /// Reading a conversation needs every message in it, and a thread scan needs a few dozen conversations. One
    /// round trip per message would make the ask scan the slowest thing in the night; the server is perfectly
    /// happy to answer a UID set, and `command` already folds each reply's literal in.
    public func messages(uids: [String], limit: Int) async throws -> [String: String] {
        guard !uids.isEmpty else { return [:] }
        let lines = try await command("UID FETCH \(uids.joined(separator: ",")) (UID BODY.PEEK[]<0.\(limit)>)")
        var out: [String: String] = [:]
        for line in lines {
            guard line.contains(" FETCH "), let u = (try? #/UID (\d+)/#.firstMatch(in: line)).map({ String($0.1) }) else { continue }
            guard let bracket = line.range(of: ">", options: .backwards) ?? line.range(of: "]", options: .backwards) else { continue }
            out[u] = String(line[bracket.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " )"))
        }
        return out
    }

    public func logout() async { _ = try? await command("LOGOUT"); await t.disconnect() }

    /// IMAP quoting: backslash and double quote are escaped, everything else goes as written.
    func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
}

// MARK: - A real connection

/// IMAPS over TLS on 993. Implicit TLS only: there is no StartTLS path here, because a mail client that can be
/// talked down to plaintext is a mail client that will be.
public actor NWIMAPTransport: IMAPTransport {
    private var conn: NWConnection?
    private var buffer = Data()
    private var ended = false
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 30) { self.timeout = timeout }

    public func connect(host: String, port: UInt16) async throws {
        let params = NWParameters(tls: .init(), tcp: .init())
        let c = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: params)
        conn = c
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            var done = false
            c.stateUpdateHandler = { state in
                guard !done else { return }
                switch state {
                case .ready: done = true; k.resume()
                case .failed(let e): done = true; k.resume(throwing: IMAPError.cannotConnect(e.localizedDescription))
                case .cancelled: done = true; k.resume(throwing: IMAPError.closed)
                default: break
                }
            }
            c.start(queue: .global(qos: .utility))
        }
    }

    public func write(_ s: String) async throws {
        guard let c = conn else { throw IMAPError.closed }
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            c.send(content: Data(s.utf8), completion: .contentProcessed { e in
                if let e { k.resume(throwing: IMAPError.cannotConnect(e.localizedDescription)) } else { k.resume() }
            })
        }
    }

    public func readLine() async throws -> String {
        while true {
            if let r = buffer.firstRange(of: Data("\r\n".utf8)) {
                let line = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                return String(decoding: line, as: UTF8.self)
            }
            try await fill()
        }
    }

    public func read(_ count: Int) async throws -> String {
        while buffer.count < count { try await fill() }
        let d = buffer.prefix(count)
        buffer.removeFirst(count)
        return String(decoding: d, as: UTF8.self)
    }

    private func fill() async throws {
        guard let c = conn, !ended else { throw IMAPError.closed }
        let chunk: Data = try await withCheckedThrowingContinuation { k in
            c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error { k.resume(throwing: IMAPError.cannotConnect(error.localizedDescription)); return }
                if complete && (data?.isEmpty ?? true) { k.resume(throwing: IMAPError.closed); return }
                k.resume(returning: data ?? Data())
            }
        }
        if chunk.isEmpty { ended = true; throw IMAPError.closed }
        buffer.append(chunk)
    }

    public func disconnect() async { conn?.cancel(); conn = nil; ended = true; buffer.removeAll() }
}
