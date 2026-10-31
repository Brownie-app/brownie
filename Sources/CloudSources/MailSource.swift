import Foundation
import Domain
import Platform
import Support

// MARK: - Which server, from the address alone

/// The handful of providers worth knowing by heart, so nobody is ever asked for a hostname and a port.
///
/// This is a table rather than a lookup against Mozilla's autoconfig service on purpose: asking a third party
/// where someone's mail lives, before they have agreed to anything, is the sort of small leak this app exists
/// to avoid. A domain that is not here falls through to the Advanced fields, which is the honest answer.
public struct MailProvider: Sendable, Equatable {
    public let name: String
    public let host: String
    public let port: UInt16
    /// What the sheet says about getting in. Nil when an ordinary password is expected to work.
    public let credentialNote: String?
    /// The page that mints an app password, opened for the user rather than described to them.
    public let appPasswordURL: String?

    public init(name: String, host: String, port: UInt16 = 993, credentialNote: String? = nil, appPasswordURL: String? = nil) {
        self.name = name; self.host = host; self.port = port; self.credentialNote = credentialNote; self.appPasswordURL = appPasswordURL
    }

    static let google = MailProvider(
        name: "Gmail", host: "imap.gmail.com",
        credentialNote: "Google asks for a one-time app password. Sixteen characters, it works only for mail, and you can revoke it from your Google account at any time — Brownie never sees your real password.",
        appPasswordURL: "https://myaccount.google.com/apppasswords")

    static let table: [String: MailProvider] = [
        "gmail.com": google, "googlemail.com": google,
        "icloud.com": .init(name: "iCloud", host: "imap.mail.me.com",
                            credentialNote: "Apple asks for an app-specific password, made at appleid.apple.com.",
                            appPasswordURL: "https://appleid.apple.com/account/manage"),
        "me.com": .init(name: "iCloud", host: "imap.mail.me.com", credentialNote: "Apple asks for an app-specific password.", appPasswordURL: "https://appleid.apple.com/account/manage"),
        "mac.com": .init(name: "iCloud", host: "imap.mail.me.com", credentialNote: "Apple asks for an app-specific password.", appPasswordURL: "https://appleid.apple.com/account/manage"),
        "outlook.com": .init(name: "Outlook", host: "outlook.office365.com"),
        "hotmail.com": .init(name: "Outlook", host: "outlook.office365.com"),
        "live.com": .init(name: "Outlook", host: "outlook.office365.com"),
        "fastmail.com": .init(name: "Fastmail", host: "imap.fastmail.com",
                              credentialNote: "Fastmail asks for an app password from Settings → Privacy & Security.",
                              appPasswordURL: "https://app.fastmail.com/settings/security/apppasswords"),
        "yahoo.com": .init(name: "Yahoo", host: "imap.mail.yahoo.com", credentialNote: "Yahoo asks for an app password."),
        "proton.me": .init(name: "Proton", host: "127.0.0.1", port: 1143, credentialNote: "Proton needs its Bridge app running on this Mac; Brownie talks to the Bridge, not to Proton."),
        "protonmail.com": .init(name: "Proton", host: "127.0.0.1", port: 1143, credentialNote: "Proton needs its Bridge app running on this Mac.")
    ]

    /// The provider for an address, by its domain. Nil for a work server nobody can guess.
    public static func forAddress(_ address: String) -> MailProvider? {
        guard let at = address.firstIndex(of: "@") else { return nil }
        return table[String(address[address.index(after: at)...]).lowercased().trimmingCharacters(in: .whitespaces)]
    }
}

// MARK: - The account

/// One mailbox, remembered in the Keychain and nowhere else.
///
/// There is no Brownie account to attach this to, so it is stored the way Slack's token is: in the user's own
/// Keychain, removable from Settings, and gone entirely after a panic wipe.
public enum MailAccount {
    static let addressKey = "mail.address", passwordKey = "mail.password", hostKey = "mail.host", portKey = "mail.port"

    public static var address: String? { Keychain.get(addressKey) }
    public static var password: String? { Keychain.get(passwordKey) }
    public static var isSignedIn: Bool { !(address ?? "").isEmpty && !(password ?? "").isEmpty }

    /// Where to connect for the stored address: the remembered override first, then the table.
    public static var server: (host: String, port: UInt16)? {
        if let h = Keychain.get(hostKey), !h.isEmpty { return (h, UInt16(Keychain.get(portKey) ?? "") ?? 993) }
        guard let a = address, let p = MailProvider.forAddress(a) else { return nil }
        return (p.host, p.port)
    }

    public static func save(address: String, password: String, host: String? = nil, port: UInt16? = nil) {
        Task { await MailConversations.shared.forget() }
        Keychain.set(addressKey, address.trimmingCharacters(in: .whitespaces))
        // An app password is shown in groups of four; people paste it as shown, and every server wants it joined.
        Keychain.set(passwordKey, password.filter { !$0.isWhitespace })
        Keychain.set(hostKey, host); Keychain.set(portKey, port.map(String.init))
    }

    public static func forget() {
        for k in [addressKey, passwordKey, hostKey, portKey] { Keychain.set(k, nil) }
        Task { await MailConversations.shared.forget() }
    }

    /// What is stored now, so a failed attempt at a second mailbox can put the working one back.
    public struct Saved: Sendable, Equatable {
        let address: String?, password: String?, host: String?, port: UInt16?
    }
    public static func snapshot() -> Saved {
        Saved(address: Keychain.get(addressKey), password: Keychain.get(passwordKey),
              host: Keychain.get(hostKey), port: UInt16(Keychain.get(portKey) ?? ""))
    }
    public static func restore(_ s: Saved) {
        guard let a = s.address, let p = s.password else { forget(); return }
        save(address: a, password: p, host: s.host, port: s.port)
    }
}

// MARK: - The source

/// Mail over IMAP, straight from this Mac to the provider.
///
/// Nothing stands between the two: no API key, no quota, no yearly re-verification, and no vendor who can
/// change a policy and switch the feature off. It is also not a Gmail feature — the same code reads iCloud,
/// Outlook, Fastmail and a work server, because they all speak the same protocol.
public struct MailSource: Source {
    public static let descriptor = SourceDescriptor(
        id: "mail", name: "Mail", detail: "Your inbox, read-only · Gmail, iCloud, Outlook, Fastmail or any IMAP",
        door: .userCloud, permissions: [])

    static let bucket = BucketID("mail:inbox")
    private let log = Log("source.mail")
    let pool: MailPool
    let policy: @Sendable () -> FirstRead

    public init(pool: MailPool = .shared, policy: @escaping @Sendable () -> FirstRead = { FirstRead.current }) {
        self.pool = pool; self.policy = policy
    }

    public func availability() async -> Availability {
        guard MailAccount.isSignedIn else { return .needsSignIn }
        guard MailAccount.server != nil else { return .unavailable("No IMAP server known for that address — set one under Advanced") }
        return .available
    }

    public func buckets(since marks: [BucketID: ItemKey], enabled: Set<BucketID>?) async throws -> [Bucket] {
        let first = marks[Self.bucket] == nil
        let days = first ? policy().days(for: Self.descriptor.id) : 7
        let cap = first ? policy().mailThreads : 100
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        let (headers, found) = try await pool.withSession { s -> ([IMAPSession.Header], Int) in
            _ = try await s.examine("INBOX")
            let seqs = try await s.search(since: since)
            // Newest first, then capped: a long first read keeps the most recent mail rather than the oldest.
            let wanted = Array(seqs.suffix(cap)).sorted(by: >)
            return (try await s.headers(wanted), seqs.count)
        }

        var items: [Candidate] = []
        for h in headers {
            let subject = h.fields["subject"] ?? "(no subject)"
            let from = h.fields["from"] ?? ""
            // A list posting is mail the user receives but nobody wrote to them: still read, never a promise.
            let order = h.date.map(\.timeIntervalSince1970) ?? Double(h.seq)
            items.append(Candidate(source: Self.descriptor.id, bucket: Self.bucket,
                                   key: ItemKey(order: order, tiebreak: h.uid), kind: .mail, id: h.uid,
                                   itemDate: h.date,
                                   metadata: ["name": subject, "displayPath": "Mail/Inbox",
                                              "from": MailParsing.displayName(from),
                                              "fromAddress": MailParsing.address(from) ?? ""]))
        }
        // What the cap left behind, counted exactly, so the run never shows a silent gap.
        let deferred = max(0, found - cap)
        if deferred > 0 { log.info("inbox: \(deferred) messages set aside past the cap of \(cap)") }
        return [Bucket(id: Self.bucket, name: "Inbox", items: items.sorted { $0.key > $1.key }, deferred: deferred)]
    }

    public func load(_ c: Candidate) async throws -> Artifact {
        let raw = try await pool.withSession { s in
            _ = try await s.examine("INBOX")
            return try await s.message(uid: c.id, limit: 64 * 1024)
        }
        let h = MailParsing.headers(raw)
        let blank = raw.range(of: "\r\n\r\n") ?? raw.range(of: "\n\n")
        let bodyRaw = blank.map { String(raw[$0.upperBound...]) } ?? ""
        let text = MailParsing.body(bodyRaw, headers: h)
        var meta = c.metadata
        meta["name"] = h["subject"] ?? meta["name"] ?? "(no subject)"
        let out = """
        From: \(h["from"] ?? "")
        To: \(h["to"] ?? "")
        Date: \(h["date"] ?? "")
        Subject: \(h["subject"] ?? "")

        \(text.prefix(6000))
        """
        let date = h["date"].flatMap(MailParsing.date) ?? c.itemDate
        return Artifact(candidate: Candidate(source: c.source, bucket: c.bucket, key: c.key, kind: c.kind, id: c.id, itemDate: date, metadata: meta), text: out)
    }
}

// MARK: - Holding the connection open

/// One TLS connection for a whole run, rather than one per message.
///
/// A night reads a few hundred messages; opening a fresh TLS session for each would spend longer shaking
/// hands than reading. The pool keeps one open, reconnects if the server drops it, and is closed by `done()`
/// when the run finishes.
public actor MailPool {
    public static let shared = MailPool()
    private var session: IMAPSession?
    private let make: @Sendable () -> any IMAPTransport
    private let idle: TimeInterval
    private var reaper: Task<Void, Never>?

    public init(transport: @escaping @Sendable () -> any IMAPTransport = { NWIMAPTransport() }, idleSeconds: TimeInterval = 120) {
        self.make = transport; self.idle = idleSeconds
    }

    /// Closes the connection once nothing has used it for a while.
    ///
    /// `Pipeline` does not know this type exists — the layering runs inward and sources are injected — so
    /// there is no end-of-run hook to hang this on, and a socket left open until the app quits is nobody's
    /// idea of tidy. The pool watches itself instead.
    private func touch() {
        reaper?.cancel()
        let seconds = idle
        reaper = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.done()
        }
    }

    func open() async throws -> IMAPSession {
        if let s = session { return s }
        guard let address = MailAccount.address, let password = MailAccount.password, let server = MailAccount.server else { throw SourceError.cannotRead("Mail isn't connected yet — add an account in Settings → Sources") }
        let s = IMAPSession(transport: make())
        try await s.connect(host: server.host, port: server.port)
        do { try await s.login(user: address, password: password) }
        catch let e as IMAPError {
            await s.logout()
            throw SourceError.cannotRead(Self.explain(e, address: address))
        }
        session = s
        return s
    }

    public func withSession<T: Sendable>(_ body: (IMAPSession) async throws -> T) async throws -> T {
        let s = try await open()
        defer { touch() }
        do { return try await body(s) }
        catch IMAPError.closed {
            // The server hung up between commands, which long-running IMAP connections do. One retry, then give up.
            session = nil
            let fresh = try await open()
            return try await body(fresh)
        }
    }

    public func done() async { reaper?.cancel(); reaper = nil; await session?.logout(); session = nil }

    /// What to say when the server says no. Every provider returns the same opaque failure for a wrong
    /// password, a missing app password and an administrator who has switched them off, so the message has to
    /// name all three rather than repeat the server's word for it.
    public static func explain(_ e: IMAPError, address: String) -> String {
        guard case .rejected(let said) = e else {
            if case .cannotConnect(let why) = e { return "Could not reach the mail server — \(why)" }
            return "The mail server closed the connection before signing in"
        }
        let provider = MailProvider.forAddress(address)
        if provider?.name == "Gmail" {
            return "Google turned that password down. An app password is sixteen characters and only exists once 2-Step Verification is on — an ordinary Google password will not work here. If this is a work account, your administrator may have switched app passwords off."
        }
        if let note = provider?.credentialNote { return "The server turned that password down. \(note)" }
        return "The server turned that password down — it said: \(said)"
    }
}
