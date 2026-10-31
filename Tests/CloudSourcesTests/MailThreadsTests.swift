import Testing
import Foundation
import Domain
import LocalSources
@testable import CloudSources

/// UNIT. Turning a mailbox back into conversations.
///
/// This is the piece Gmail's API used to hand over for free, and the reason asks and loops stopped coming from
/// mail when that source went. Every shape below is one a real mailer produces: a reply that cites the whole
/// chain, one that cites only its parent, one that cites nothing at all, and two strangers who both wrote "Hi".
@Suite struct MailThreadsTests {

    func m(_ uid: String, _ day: Int, subject: String, id: String? = nil, inReplyTo: String? = nil,
           references: String? = nil, thrid: String? = nil) -> MailThreads.Message {
        var f = ["subject": subject]
        if let id { f["message-id"] = "<\(id)>" }
        if let inReplyTo { f["in-reply-to"] = "<\(inReplyTo)>" }
        if let references { f["references"] = references }
        return MailThreads.Message(uid: uid, date: Date(timeIntervalSince1970: 1_788_739_200 + Double(day) * 86400),
                                   fields: f, threadID: thrid)
    }

    // MARK: - Gmail's own id

    @Test func gmailsThreadIdIsUsedWhenTheServerOffersIt() {
        // Deliberately contradictory: no References anywhere, and two different subjects. X-GM-THRID still wins,
        // because it is the same number the web interface threads on.
        let t = MailThreads.group([
            m("1", 0, subject: "the audited accounts", id: "a@x.test", thrid: "99"),
            m("2", 2, subject: "something else entirely", id: "b@x.test", thrid: "99"),
            m("3", 1, subject: "unrelated", id: "c@x.test", thrid: "77"),
        ])
        #expect(t.count == 2)
        #expect(t.first { $0.messages.count == 2 }?.messages.map(\.uid) == ["1", "2"], "oldest first inside a thread")
    }

    // MARK: - References, for every other server

    @Test func aReplyJoinsTheMailItAnswers() {
        let t = MailThreads.group([
            m("1", 0, subject: "the audited accounts", id: "a@x.test"),
            m("2", 2, subject: "Re: the audited accounts", id: "b@x.test", inReplyTo: "a@x.test"),
        ])
        #expect(t.count == 1)
        #expect(t[0].messages.map(\.uid) == ["1", "2"])
    }

    @Test func aLongChainIsOneConversationHoweverItIsCited() {
        // Three mailers, three habits: one cites the whole chain, one only its parent, one both.
        let t = MailThreads.group([
            m("1", 0, subject: "the figures", id: "a@x.test"),
            m("2", 1, subject: "Re: the figures", id: "b@x.test", inReplyTo: "a@x.test"),
            m("3", 2, subject: "Re: the figures", id: "c@x.test", references: "<a@x.test> <b@x.test>"),
            m("4", 3, subject: "Re: the figures", id: "d@x.test", inReplyTo: "c@x.test", references: "<a@x.test> <b@x.test> <c@x.test>"),
        ])
        #expect(t.count == 1)
        #expect(t[0].messages.map(\.uid) == ["1", "2", "3", "4"])
    }

    @Test func twoSeparateConversationsStaySeparate() {
        let t = MailThreads.group([
            m("1", 0, subject: "the figures", id: "a@x.test"),
            m("2", 1, subject: "Re: the figures", id: "b@x.test", inReplyTo: "a@x.test"),
            m("3", 1, subject: "the lease", id: "c@x.test"),
            m("4", 2, subject: "Re: the lease", id: "d@x.test", inReplyTo: "c@x.test"),
        ])
        #expect(t.count == 2)
        #expect(t.allSatisfy { $0.messages.count == 2 })
    }

    @Test func aReplyThatArrivesBeforeTheMailItAnswersIsStillJoined() {
        // Threading cannot assume arrival order: a UID set comes back in whatever order the server likes.
        let t = MailThreads.group([
            m("2", 2, subject: "Re: the figures", id: "b@x.test", inReplyTo: "a@x.test"),
            m("1", 0, subject: "the figures", id: "a@x.test"),
        ])
        #expect(t.count == 1 && t[0].messages.map(\.uid) == ["1", "2"])
    }

    @Test func aMailCitingSomethingOutsideTheWindowDoesNotDragInAStranger() {
        // Both cite a parent that was not fetched. They are two conversations, not one joined through a ghost.
        let t = MailThreads.group([
            m("1", 0, subject: "the figures", id: "a@x.test", inReplyTo: "old-one@x.test"),
            m("2", 0, subject: "the lease", id: "b@x.test", inReplyTo: "old-two@x.test"),
        ])
        #expect(t.count == 2)
    }

    // MARK: - The subject fallback

    @Test func aReplyFromAMailerThatDropsReferencesIsRescuedByItsSubject() {
        let t = MailThreads.group([
            m("1", 0, subject: "the audited accounts", id: "a@x.test"),
            m("2", 2, subject: "Re: the audited accounts", id: "b@x.test"),
        ])
        #expect(t.count == 1, "some phone clients send no In-Reply-To at all")
    }

    @Test func twoStrangersWhoBothWroteHiAreNotOneConversation() {
        // The guard on the fallback: without a Re: anywhere, an identical subject proves nothing.
        let t = MailThreads.group([
            m("1", 0, subject: "Hi", id: "a@x.test"),
            m("2", 1, subject: "Hi", id: "b@x.test"),
        ])
        #expect(t.count == 2)
    }

    @Test func anEmptySubjectNeverJoinsAnything() {
        let t = MailThreads.group([
            m("1", 0, subject: "", id: "a@x.test"),
            m("2", 1, subject: "Re: ", id: "b@x.test"),
        ])
        #expect(t.count == 2)
    }

    // MARK: - Subjects

    @Test func thePrefixesMailersStackUpAreAllStripped() {
        #expect(MailThreads.normalisedSubject("Re: the figures") == "the figures")
        #expect(MailThreads.normalisedSubject("RE: Fwd: Re: the figures") == "the figures")
        #expect(MailThreads.normalisedSubject("[team] Re: the figures") == "the figures")
        #expect(MailThreads.normalisedSubject("Re[2]: the figures") == "the figures", "Outlook numbers its replies")
        #expect(MailThreads.normalisedSubject("SV: the figures") == "the figures", "and not every mailer is English")
        #expect(MailThreads.normalisedSubject("  The Figures  ") == "the figures")
    }

    @Test func aSubjectThatOnlyLooksLikeAPrefixKeepsItsWords() {
        #expect(MailThreads.normalisedSubject("Regarding the figures") == "regarding the figures")
        #expect(MailThreads.normalisedSubject("Review: the figures") == "review: the figures")
    }

    // MARK: - Ids

    @Test func messageIdsAreReadOutOfTheirBrackets() {
        #expect(MailThreads.ids("<a@x.test> <b@y.test>") == ["a@x.test", "b@y.test"])
        #expect(MailThreads.ids("  <a@x.test>  ") == ["a@x.test"])
        #expect(MailThreads.ids("nonsense with no brackets") == [], "References is a list of msg-ids; junk is not one")
    }

    @Test func aMailWithNoMessageIdIsItsOwnConversationRatherThanEveryonesElse() {
        let t = MailThreads.group([
            m("1", 0, subject: "one"),
            m("2", 1, subject: "two"),
        ])
        #expect(t.count == 2, "a missing Message-ID must not collapse into a single shared key")
    }

    // MARK: - Order and identity

    @Test func threadsComeBackLiveliestFirst() {
        let t = MailThreads.group([
            m("1", 0, subject: "old", id: "a@x.test"),
            m("2", 9, subject: "new", id: "b@x.test"),
        ])
        #expect(t.map { $0.messages[0].uid } == ["2", "1"], "the cap has to fall on the quiet threads")
    }

    @Test func theSameThreadKeepsItsKeyFromOneNightToTheNext() {
        // Tonight's read and tomorrow's must produce the same bucket, or every ask reopens as a new one.
        let tonight = MailThreads.group([m("1", 0, subject: "the figures", id: "a@x.test")])
        let tomorrow = MailThreads.group([
            m("1", 0, subject: "the figures", id: "a@x.test"),
            m("2", 1, subject: "Re: the figures", id: "b@x.test", inReplyTo: "a@x.test"),
        ])
        #expect(tonight[0].key == tomorrow[0].key)
    }

    @Test func aThreadKeepsItsKeyEvenAfterItsFirstMailAgesOutOfTheWindow() {
        // The window slides every night. If the key moved when the original dropped off the back of it, a
        // conversation Brownie has been tracking for a month would become a stranger overnight.
        let whole = MailThreads.group([
            m("1", 0, subject: "the figures", id: "a@x.test"),
            m("2", 1, subject: "Re: the figures", id: "b@x.test", references: "<a@x.test>"),
            m("3", 2, subject: "Re: the figures", id: "c@x.test", references: "<a@x.test> <b@x.test>"),
        ])
        let tailOnly = MailThreads.group([
            m("3", 2, subject: "Re: the figures", id: "c@x.test", references: "<a@x.test> <b@x.test>"),
        ])
        #expect(whole[0].key == tailOnly[0].key, "every reply still names the mail the chain started from")
    }

    @Test func gmailsThreadKeyDoesNotDependOnWhichMessagesAreInTheWindow() {
        let whole = MailThreads.group([
            m("1", 0, subject: "one", id: "a@x.test", thrid: "99"),
            m("2", 1, subject: "two", id: "b@x.test", thrid: "99"),
        ])
        let tailOnly = MailThreads.group([m("2", 1, subject: "two", id: "b@x.test", thrid: "99")])
        #expect(whole[0].key == tailOnly[0].key)
    }
}

/// UNIT. The short memory that keeps one night's questions down to one night's reading.
@Suite struct MailConversationsTests {

    func conversation(_ name: String) -> MailSource.Conversation {
        MailSource.Conversation(
            info: BucketInfo(id: BucketID("mail:thread:\(name)"), name: name, detail: "", isGroup: false, count: 1),
            messages: [ChatMessage(rowID: 1, date: Date(timeIntervalSince1970: 1_788_739_200), sender: name, isMe: false, text: "hello")])
    }

    @Test func whatWasReadOnceIsAnsweredFromMemory() async {
        let c = MailConversations()
        #expect(await c.get(60) == nil, "nothing read yet")
        await c.put(60, [conversation("Lalita Pathak")])
        #expect(await c.get(60)?.count == 1)
        #expect(await c.get(30) == nil, "a different window is a different read")
    }

    @Test func memoryOlderThanItsWelcomeIsNotUsed() async {
        let c = MailConversations(ttl: -1)
        await c.put(60, [conversation("Lalita Pathak")])
        #expect(await c.get(60) == nil, "mail that arrives mid-run should be seen by the next run")
    }

    @Test func changingTheMailboxForgetsTheOldOne() async {
        // Otherwise the mailbox you just disconnected answers for the one you just connected.
        let c = MailConversations()
        await c.put(60, [conversation("Lalita Pathak")])
        await c.forget()
        #expect(await c.get(60) == nil)
    }
}

/// UNIT. Finding the mail the user sent, and keeping it apart from the mail they received.
///
/// An ask closes on the user's own reply, and a reply lives in the Sent mailbox — never in INBOX. Reading only
/// INBOX gives Brownie the question and never the answer, so every ask opens and then nags forever. These are
/// the two things that have to hold for a reply to close the ask it answers.
@Suite struct MailSentMailboxTests {

    let greeting = "* OK ready\r\n"

    @Test func theSentMailboxIsFoundByItsSpecialUseAttribute() async throws {
        let t = FakeIMAP(greeting + """
        * LIST (\\HasNoChildren) "/" "INBOX"\r
        * LIST (\\HasNoChildren \\Sent) "/" "[Gmail]/Sent Mail"\r
        * LIST (\\HasNoChildren \\Trash) "/" "[Gmail]/Bin"\r
        a001 OK Success\r\n
        """)
        let s = IMAPSession(transport: t)
        try await s.connect(host: "h", port: 993)
        #expect(try await s.sentMailbox() == "[Gmail]/Sent Mail", "RFC 6154 names it, whatever the folder is called")
    }

    @Test func aServerWithoutSpecialUseIsFoundByName() async throws {
        let t = FakeIMAP(greeting + "* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n* LIST (\\HasNoChildren) \"/\" \"Sent Items\"\r\na001 OK done\r\n")
        let s = IMAPSession(transport: t)
        try await s.connect(host: "h", port: 993)
        #expect(try await s.sentMailbox() == "Sent Items", "Outlook calls it this and publishes no attribute")
    }

    @Test func aServerThatKeepsNoSentMailSaysSoRatherThanGuessing() async throws {
        let t = FakeIMAP(greeting + "* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n* LIST (\\HasNoChildren) \"/\" \"Archive\"\r\na001 OK done\r\n")
        let s = IMAPSession(transport: t)
        try await s.connect(host: "h", port: 993)
        #expect(try await s.sentMailbox() == nil, "better nothing than reading Archive as if it were Sent")
    }

    @Test func theTrashIsNeverMistakenForTheSentMailbox() async throws {
        let t = FakeIMAP(greeting + "* LIST (\\HasNoChildren \\Trash) \"/\" \"Deleted Messages\"\r\n* LIST (\\HasNoChildren \\Sent) \"/\" \"Sent Messages\"\r\na001 OK done\r\n")
        let s = IMAPSession(transport: t)
        try await s.connect(host: "h", port: 993)
        #expect(try await s.sentMailbox() == "Sent Messages")
    }

    // MARK: - The two mailboxes must not collide

    @Test func aUidIsOnlyUniqueInsideOneMailboxSoItIsTaggedWithOne() {
        // INBOX 7 and Sent 7 are different messages. Untagged, the body map would hold one of them twice and a
        // reply would come back carrying the text of the question it answers.
        let inbox = "INBOX\u{1}7", sent = "[Gmail]/Sent Mail\u{1}7"
        #expect(inbox != sent)
        #expect(MailSource.mailbox(of: inbox) == "INBOX" && MailSource.uid(of: inbox) == "7")
        #expect(MailSource.mailbox(of: sent) == "[Gmail]/Sent Mail" && MailSource.uid(of: sent) == "7")
    }

    @Test func aMailboxNameWithPunctuationInItSurvivesTheTag() {
        for name in ["[Gmail]/Sent Mail", "INBOX.Sent", "Sent Items", "Envoyés"] {
            let tagged = "\(name)\u{1}412"
            #expect(MailSource.mailbox(of: tagged) == name, Comment(rawValue: name))
            #expect(MailSource.uid(of: tagged) == "412", Comment(rawValue: name))
        }
    }

    @Test func aSentReplyJoinsTheThreadOfTheMailItAnswers() {
        // The whole point: the question arrives in INBOX, the answer is in Sent, and threading has to put them
        // back together before the detector can see that the ask was answered.
        let question = MailThreads.Message(uid: "INBOX\u{1}7", date: Date(timeIntervalSince1970: 1_788_739_200),
                                           fields: ["subject": "the audited accounts", "message-id": "<q@x.test>", "from": "rhea@chhabra-co.test"])
        let answer = MailThreads.Message(uid: "Sent\u{1}7", date: Date(timeIntervalSince1970: 1_788_912_000),
                                         fields: ["subject": "Re: the audited accounts", "message-id": "<a@x.test>",
                                                  "in-reply-to": "<q@x.test>", "from": "me@x.test"])
        let t = MailThreads.group([question, answer])
        #expect(t.count == 1, "one conversation, across two mailboxes")
        #expect(t[0].messages.map(\.uid) == ["INBOX\u{1}7", "Sent\u{1}7"], "the question, then the answer")
    }
}
