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

    /// Mailboxes the account has, as `LIST` reports them. Used to find where mail actually lives, since Gmail
    /// calls the inbox INBOX but keeps everything else behind `[Gmail]/All Mail`.
    public func list() async throws -> [String] {
        let lines = try await command("LIST \"\" \"*\"")
        return lines.compactMap { line in
            guard line.hasPrefix("* LIST") else { return nil }
            // The name is the last token, quoted when it has a space in it.
            if let q = line.range(of: "\"", options: .backwards), let o = line.range(of: "\"", options: .backwards, range: line.startIndex..<q.lowerBound) {
                return String(line[o.upperBound..<q.lowerBound])
            }
            return line.split(separator: " ").last.map(String.init)
        }.filter { !$0.isEmpty && $0 != "/" }
    }

    /// One batch of headers. Deliberately not the whole message: this runs over every message in the window.
    public struct Header: Sendable, Equatable {
        public let seq: Int
        public let uid: String
        public let date: Date?
        public let fields: [String: String]
    }

    public func headers(_ seqs: [Int]) async throws -> [Header] {
        guard !seqs.isEmpty else { return [] }
        let set = seqs.map(String.init).joined(separator: ",")
        let lines = try await command("FETCH \(set) (UID INTERNALDATE BODY.PEEK[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID LIST-ID)])")
        return lines.compactMap { line in
            guard let m = try? #/^\* (\d+) FETCH /#.firstMatch(in: line), let seq = Int(m.1) else { return nil }
            let uid = (try? #/UID (\d+)/#.firstMatch(in: line)).map { String($0.1) } ?? String(seq)
            let date = (try? #/INTERNALDATE "([^"]+)"/#.firstMatch(in: line)).flatMap { MailParsing.internalDate(String($0.1)) }
            // Everything after the last `]` of the BODY section is the folded-in literal.
            guard let bracket = line.range(of: "]", options: .backwards) else { return nil }
            let raw = String(line[bracket.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " )"))
            return Header(seq: seq, uid: uid, date: date, fields: MailParsing.headers(raw))
        }
    }

    /// One whole message, capped. Peeked, so reading it does not mark it seen.
    public func message(uid: String, limit: Int) async throws -> String {
        let lines = try await command("UID FETCH \(uid) (BODY.PEEK[]<0.\(limit)>)")
        guard let line = lines.first(where: { $0.contains(" FETCH ") }), let bracket = line.range(of: ">", options: .backwards) ?? line.range(of: "]", options: .backwards) else { return "" }
        return String(line[bracket.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " )"))
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
