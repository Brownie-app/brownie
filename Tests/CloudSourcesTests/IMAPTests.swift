import Testing
import Foundation
import Domain
@testable import CloudSources

/// UNIT. The protocol half, driven against a scripted server.
///
/// The fake is a byte stream rather than a list of canned replies, because the thing most likely to break is
/// the literal: IMAP answers a FETCH with `{418}` and then 418 bytes that are data rather than protocol, and
/// a client that miscounts them reads the next command's reply as part of this one. Feeding real bytes is the
/// only way that bug shows up in a test instead of against somebody's inbox.
actor FakeIMAP: IMAPTransport {
    private var incoming: [UInt8]
    private(set) var written: [String] = []
    private(set) var connected: (host: String, port: UInt16)?

    init(_ stream: String) { incoming = Array(stream.utf8) }

    func connect(host: String, port: UInt16) async throws { connected = (host, port) }
    func write(_ s: String) async throws { written.append(s) }

    func readLine() async throws -> String {
        guard let r = find(Array("\r\n".utf8)) else { throw IMAPError.closed }
        let line = Array(incoming[0..<r]); incoming.removeFirst(r + 2)
        return String(decoding: line, as: UTF8.self)
    }

    func read(_ count: Int) async throws -> String {
        guard incoming.count >= count else { throw IMAPError.closed }
        let d = Array(incoming[0..<count]); incoming.removeFirst(count)
        return String(decoding: d, as: UTF8.self)
    }

    func disconnect() async { incoming.removeAll() }

    private func find(_ needle: [UInt8]) -> Int? {
        guard incoming.count >= needle.count else { return nil }
        for i in 0...(incoming.count - needle.count) where Array(incoming[i..<i + needle.count]) == needle { return i }
        return nil
    }
}

/// A FETCH response carrying a literal, with the byte count computed rather than written by hand — a count
/// that is wrong by one is exactly the bug this is here to catch, and it should fail in the client, not here.
func literalFetch(seq: Int, uid: String, date: String, headers: String, tag: String) -> String {
    let n = headers.utf8.count
    return "* \(seq) FETCH (UID \(uid) INTERNALDATE \"\(date)\" BODY[HEADER.FIELDS (FROM SUBJECT)] {\(n)}\r\n\(headers))\r\n\(tag) OK FETCH completed\r\n"
}

@Suite struct IMAPTests {

    let greeting = "* OK Gimap ready for requests\r\n"

    @Test func signingInSendsAQuotedLoginAndAcceptsTheOK() async throws {
        let t = FakeIMAP(greeting + "a001 OK welcome\r\n")
        let s = IMAPSession(transport: t)
        try await s.connect(host: "imap.gmail.com", port: 993)
        try await s.login(user: "lalita@tideline.test", password: "abcd efgh ijkl mnop")
        let sent = await t.written
        #expect(sent == ["a001 LOGIN \"lalita@tideline.test\" \"abcd efgh ijkl mnop\"\r\n"])
        #expect(await t.connected?.port == 993)
    }

    @Test func aRejectedLoginCarriesTheServersOwnWords() async throws {
        let t = FakeIMAP(greeting + "a001 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\n")
        let s = IMAPSession(transport: t)
        try await s.connect(host: "h", port: 993)
        await #expect(throws: IMAPError.rejected("[AUTHENTICATIONFAILED] Invalid credentials (Failure)")) {
            try await s.login(user: "a@x.test", password: "nope")
        }
    }

    @Test func aBadCommandIsAlsoAnError() async throws {
        let t = FakeIMAP(greeting + "a001 BAD cannot parse command\r\n")
        let s = IMAPSession(transport: t)
        try await s.connect(host: "h", port: 993)
        await #expect(throws: IMAPError.rejected("cannot parse command")) { try await s.login(user: "a", password: "b") }
    }

    @Test func examineReportsHowMuchIsThereAndNeverMarksAnythingRead() async throws {
        let t = FakeIMAP(greeting + "* 4821 EXISTS\r\n* 0 RECENT\r\na001 OK [READ-ONLY] EXAMINE completed\r\n")
        let s = IMAPSession(transport: t)
        try await s.connect(host: "h", port: 993)
        #expect(try await s.examine("INBOX") == 4821)
        let sent = await t.written
        #expect(sent[0].hasPrefix("a001 EXAMINE"), "EXAMINE, not SELECT — a background read must not touch the unread count")
    }

    @Test func searchComesBackAsNumbers() async throws {
        let t = FakeIMAP(greeting + "* SEARCH 11 12 15 19\r\na001 OK SEARCH completed\r\n")
        let s = IMAPSession(transport: t)
        try await s.connect(host: "h", port: 993)
        #expect(try await s.search(since: Date(timeIntervalSince1970: 1788739200)) == [11, 12, 15, 19])
        let sent = await t.written
        #expect(sent[0] == "a001 SEARCH SINCE 7-Sep-2026\r\n")
    }

    @Test func anEmptySearchIsEmptyRatherThanAnError() async throws {
        let t = FakeIMAP(greeting + "* SEARCH\r\na001 OK SEARCH completed\r\n")
        let s = IMAPSession(transport: t)
        try await s.connect(host: "h", port: 993)
        #expect(try await s.search(since: Date()) == [])
    }

    // MARK: - The literal

    @Test func aFetchLiteralIsFoldedInAndTheHeadersParsed() async throws {
        let headers = "From: \"Lalita Pathak\" <lalita@tideline.test>\r\nSubject: the quarterly figures\r\n\r\n"
        let t = FakeIMAP(greeting + literalFetch(seq: 3, uid: "908", date: " 7-Sep-2026 10:00:00 +0000", headers: headers, tag: "a001"))
        let s = IMAPSession(transport: t)
        try await s.connect(host: "h", port: 993)
        let out = try await s.headers([3])
        #expect(out.count == 1)
        let h = try #require(out.first)
        #expect(h.seq == 3 && h.uid == "908")
        #expect(h.fields["subject"] == "the quarterly figures")
        #expect(h.fields["from"] == "\"Lalita Pathak\" <lalita@tideline.test>")
        #expect(h.date != nil, "INTERNALDATE is IMAP's own spelling and still has to parse")
    }

    @Test func aSecondResponseAfterALiteralIsStillReadCorrectly() async throws {
        // The bug a miscounted literal causes: the next message is swallowed into this one.
        let one = "From: a@x.test\r\nSubject: first\r\n\r\n"
        let two = "From: b@x.test\r\nSubject: second\r\n\r\n"
        let stream = greeting
            + "* 1 FETCH (UID 1 INTERNALDATE \" 7-Sep-2026 10:00:00 +0000\" BODY[HEADER.FIELDS (FROM SUBJECT)] {\(one.utf8.count)}\r\n\(one))\r\n"
            + "* 2 FETCH (UID 2 INTERNALDATE \" 8-Sep-2026 10:00:00 +0000\" BODY[HEADER.FIELDS (FROM SUBJECT)] {\(two.utf8.count)}\r\n\(two))\r\n"
            + "a001 OK FETCH completed\r\n"
        let s = IMAPSession(transport: FakeIMAP(stream))
        try await s.connect(host: "h", port: 993)
        let out = try await s.headers([1, 2])
        #expect(out.map(\.uid) == ["1", "2"])
        #expect(out.map { $0.fields["subject"] ?? "" } == ["first", "second"])
    }

    @Test func aLiteralHoldingNonAsciiIsCountedInBytesNotCharacters() async throws {
        // The count in `{n}` is octets. A subject with an é in it is one character and two bytes, and a
        // client that counts characters loses the rest of the response from here on.
        let headers = "From: a@x.test\r\nSubject: café, £40, 日本\r\n\r\n"
        let t = FakeIMAP(greeting + literalFetch(seq: 1, uid: "7", date: " 7-Sep-2026 10:00:00 +0000", headers: headers, tag: "a001"))
        let s = IMAPSession(transport: t)
        try await s.connect(host: "h", port: 993)
        let out = try await s.headers([1])
        #expect(out.first?.fields["subject"] == "café, £40, 日本")
    }

    @Test func oneWholeMessageComesBackFromAUidFetch() async throws {
        let msg = "From: a@x.test\r\nSubject: hello\r\n\r\nthe body itself\r\n"
        let stream = greeting + "* 1 FETCH (UID 908 BODY[]<0> {\(msg.utf8.count)}\r\n\(msg))\r\na001 OK FETCH completed\r\n"
        let s = IMAPSession(transport: FakeIMAP(stream))
        try await s.connect(host: "h", port: 993)
        let raw = try await s.message(uid: "908", limit: 65536)
        #expect(raw.contains("the body itself"))
        #expect(raw.hasPrefix("From: a@x.test"))
    }

    @Test func noFetchResponseAtAllIsEmptyRatherThanACrash() async throws {
        let s = IMAPSession(transport: FakeIMAP(greeting + "a001 OK FETCH completed\r\n"))
        try await s.connect(host: "h", port: 993)
        #expect(try await s.message(uid: "1", limit: 10) == "")
    }

    // MARK: - Gmail's own extensions, over plain IMAP

    @Test func gmailAdvertisesItsExtensionsInTheCapabilityReply() async throws {
        let t = FakeIMAP(greeting + "* CAPABILITY IMAP4rev1 UNSELECT IDLE X-GM-EXT-1 AUTH=XOAUTH2\r\na001 OK Success\r\n")
        let s = IMAPSession(transport: t)
        try await s.connect(host: "h", port: 993)
        let caps = try await s.capabilities()
        #expect(caps.contains("X-GM-EXT-1"), "this is what says the thread id and the raw search are available")
        #expect(!caps.contains("X-GM-THRID"), "the capability names the set, not each command")
    }

    @Test func aServerThatIsNotGmailSaysNothingAboutGmail() async throws {
        let t = FakeIMAP(greeting + "* CAPABILITY IMAP4rev1 IDLE CONDSTORE\r\na001 OK done\r\n")
        let s = IMAPSession(transport: t)
        try await s.connect(host: "h", port: 993)
        #expect(!(try await s.capabilities()).contains("X-GM-EXT-1"))
    }

    @Test func theGmailSearchIsSentAsAQuotedRawQuery() async throws {
        let t = FakeIMAP(greeting + "* SEARCH 4 9\r\na001 OK SEARCH completed\r\n")
        let s = IMAPSession(transport: t)
        try await s.connect(host: "h", port: 993)
        #expect(try await s.search(gmailRaw: "newer_than:30d -category:promotions") == [4, 9])
        let sent = await t.written
        #expect(sent[0] == "a001 SEARCH X-GM-RAW \"newer_than:30d -category:promotions\"\r\n",
                "unquoted, the minus and the colon are read as protocol")
    }

    @Test func theThreadIdComesBackAlongsideTheHeadersWhenAskedFor() async throws {
        let headers = "From: a@x.test\r\nSubject: the figures\r\nMessage-ID: <m1@x.test>\r\n\r\n"
        let n = headers.utf8.count
        let stream = greeting
            + "* 1 FETCH (X-GM-THRID 1799 UID 7 INTERNALDATE \" 7-Sep-2026 10:00:00 +0000\" BODY[HEADER.FIELDS (FROM SUBJECT)] {\(n)}\r\n\(headers))\r\n"
            + "a001 OK FETCH completed\r\n"
        let t = FakeIMAP(stream)
        let s = IMAPSession(transport: t)
        try await s.connect(host: "h", port: 993)
        let out = try await s.headers([1], threadIDs: true)
        #expect(out.first?.threadID == "1799")
        #expect(out.first?.fields["message-id"] == "<m1@x.test>", "threading needs the id the message calls itself")
        let sent = await t.written
        #expect(sent[0].contains("X-GM-THRID"))
        #expect(sent[0].contains("IN-REPLY-TO REFERENCES"), "and the headers every other server threads on")
    }

    @Test func noThreadIdIsAskedForOnAServerThatIsNotGmail() async throws {
        let headers = "From: a@x.test\r\nSubject: s\r\n\r\n"
        let t = FakeIMAP(greeting + literalFetch(seq: 1, uid: "7", date: " 7-Sep-2026 10:00:00 +0000", headers: headers, tag: "a001"))
        let s = IMAPSession(transport: t)
        try await s.connect(host: "h", port: 993)
        let out = try await s.headers([1])
        #expect(out.first?.threadID == nil)
        #expect(!(await t.written)[0].contains("X-GM-THRID"))
    }

    // MARK: - Reading a conversation

    @Test func severalWholeMessagesComeBackFromOneUidFetch() async throws {
        let one = "From: a@x.test\r\n\r\nthe question\r\n", two = "From: b@x.test\r\n\r\nthe answer\r\n"
        let stream = greeting
            + "* 1 FETCH (UID 11 BODY[]<0> {\(one.utf8.count)}\r\n\(one))\r\n"
            + "* 2 FETCH (UID 12 BODY[]<0> {\(two.utf8.count)}\r\n\(two))\r\n"
            + "a001 OK FETCH completed\r\n"
        let t = FakeIMAP(stream)
        let s = IMAPSession(transport: t)
        try await s.connect(host: "h", port: 993)
        let out = try await s.messages(uids: ["11", "12"], limit: 4096)
        #expect(out["11"]?.contains("the question") == true)
        #expect(out["12"]?.contains("the answer") == true, "a miscounted literal would swallow this one")
        #expect((await t.written)[0].hasPrefix("a001 UID FETCH 11,12 "), "one command, not one per message")
    }

    @Test func askingForNoMessagesAsksTheServerNothing() async throws {
        let t = FakeIMAP("")
        let s = IMAPSession(transport: t)
        #expect(try await s.messages(uids: [], limit: 10).isEmpty)
        #expect(await t.written.isEmpty)
    }

    @Test func aPasswordWithAQuoteInItIsEscapedRatherThanEndingTheString() async {
        let s = IMAPSession(transport: FakeIMAP(""))
        #expect(await s.quoted(#"pa"ss\word"#) == #""pa\"ss\\word""#)
    }
}

/// UNIT. Which server, and what to say when it says no.
@Suite struct MailProviderTests {

    @Test func theCommonProvidersAreKnownByTheirDomain() {
        #expect(MailProvider.forAddress("them@gmail.com")?.host == "imap.gmail.com")
        #expect(MailProvider.forAddress("them@googlemail.com")?.name == "Gmail")
        #expect(MailProvider.forAddress("them@icloud.com")?.host == "imap.mail.me.com")
        #expect(MailProvider.forAddress("them@fastmail.com")?.port == 993)
        #expect(MailProvider.forAddress("THEM@GMAIL.COM")?.name == "Gmail", "a domain is not case-sensitive")
    }

    @Test func protonGoesThroughItsBridgeOnThisMacRatherThanOverTheInternet() {
        let p = MailProvider.forAddress("them@proton.me")
        #expect(p?.host == "127.0.0.1" && p?.port == 1143)
    }

    @Test func aWorkDomainNobodyCanGuessFallsThroughToAdvanced() {
        #expect(MailProvider.forAddress("them@theircompany.test") == nil)
        #expect(MailProvider.forAddress("not-an-address") == nil)
    }

    @Test func gmailsOpaqueRefusalIsTranslatedIntoTheThreeThingsItCouldMean() {
        let said = MailPool.explain(.rejected("[AUTHENTICATIONFAILED] Invalid credentials"), address: "them@gmail.com")
        #expect(said.contains("sixteen characters"), "the length is the single most useful fact")
        #expect(said.contains("2-Step Verification"), "an app password does not exist without it")
        #expect(said.contains("administrator"), "and a work account may have them switched off entirely")
        #expect(!said.contains("AUTHENTICATIONFAILED"), "the server's own word for it tells the user nothing")
    }

    @Test func anUnknownServerIsQuotedBackBecauseItsWordsAreAllWeHave() {
        #expect(MailPool.explain(.rejected("mailbox locked"), address: "them@theircompany.test").contains("mailbox locked"))
    }

    @Test func notReachingTheServerIsDifferentFromBeingTurnedAway() {
        let said = MailPool.explain(.cannotConnect("hostname not found"), address: "them@gmail.com")
        #expect(said.contains("Could not reach") && said.contains("hostname not found"))
    }
}
