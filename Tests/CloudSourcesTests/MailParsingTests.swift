import Testing
import Foundation
@testable import CloudSources

/// UNIT. Mail was standardised in 1982 and amended ever since, so the awkward spellings are the normal case:
/// a subject encoded word by word, a header folded over three lines, a body in quoted-printable inside a
/// multipart wrapper. Each one here is a shape a real server actually sends.
@Suite struct MailParsingTests {

    // MARK: - Headers

    @Test func aHeaderFoldedOverSeveralLinesComesBackWhole() {
        let raw = "Subject: the quarterly figures,\r\n with the appendix\r\n\tand the cover note\r\nFrom: a@x.test\r\n\r\nbody"
        let h = MailParsing.headers(raw)
        #expect(h["subject"] == "the quarterly figures, with the appendix and the cover note")
        #expect(h["from"] == "a@x.test", "the header after a folded one is still found")
    }

    @Test func theBlankLineEndsTheHeadersAndTheBodyIsNotMistakenForOne() {
        let h = MailParsing.headers("Subject: hello\r\n\r\nTo: not-a-header@x.test\r\nplain text")
        #expect(h["subject"] == "hello")
        #expect(h["to"] == nil, "past the blank line is body, whatever it looks like")
    }

    @Test func namesAreLowerCasedAndTheFirstOfARepeatedHeaderWins() {
        let h = MailParsing.headers("SUBJECT: first\r\nSubject: second\r\n\r\n")
        #expect(h["subject"] == "first")
    }

    // MARK: - RFC 2047

    @Test func anEncodedSubjectIsDecoded() {
        #expect(MailParsing.decodeWords("=?UTF-8?B?TGFsaXRhIFBhdGhhaw==?=") == "Lalita Pathak")
        #expect(MailParsing.decodeWords("=?UTF-8?Q?Lalita_Pathak?=") == "Lalita Pathak", "Q encoding writes a space as an underscore")
    }

    @Test func twoEncodedWordsSideBySideDoNotGainASpaceBetweenThem() {
        // RFC 2047 §6.2: whitespace between adjacent encoded words is not part of the text.
        let s = "=?UTF-8?Q?Lalita?= =?UTF-8?Q?_Pathak?="
        #expect(MailParsing.decodeWords(s) == "Lalita Pathak")
    }

    @Test func plainTextAroundAnEncodedWordIsKept() {
        #expect(MailParsing.decodeWords("Re: =?UTF-8?Q?the_figures?= (urgent)") == "Re: the figures (urgent)")
    }

    @Test func somethingThatOnlyLooksEncodedIsLeftAlone() {
        #expect(MailParsing.decodeWords("a =?b? c") == "a =?b? c")
        #expect(MailParsing.decodeWords("no words here") == "no words here")
    }

    // MARK: - Addresses

    @Test func theNameComesOutOfAFromHeaderAndTheAddressSeparately() {
        #expect(MailParsing.displayName("\"Lalita Pathak\" <lalita@tideline.test>") == "Lalita Pathak")
        #expect(MailParsing.address("\"Lalita Pathak\" <lalita@tideline.test>") == "lalita@tideline.test")
    }

    @Test func aBareAddressStandsInForItsOwnName() {
        #expect(MailParsing.displayName("lokesh@tideline.test") == "lokesh")
        #expect(MailParsing.displayName("<lokesh@tideline.test>") == "lokesh")
        #expect(MailParsing.address("lokesh@tideline.test") == "lokesh@tideline.test")
    }

    @Test func somethingThatIsNotAnAddressDoesNotBecomeOne() {
        #expect(MailParsing.address("undisclosed recipients") == nil)
        #expect(MailParsing.address("@tideline.test") == nil)
        #expect(MailParsing.address("lalita@") == nil)
    }

    // MARK: - Bodies

    @Test func quotedPrintableIsDecodedAndSoftBreaksDisappear() {
        let body = MailParsing.body("the quarterly figures are =\r\nattached, =C2=A34,100 in all",
                                    headers: ["content-transfer-encoding": "quoted-printable", "content-type": "text/plain; charset=UTF-8"])
        #expect(body == "the quarterly figures are attached, £4,100 in all")
    }

    @Test func base64IsDecoded() {
        let b64 = Data("Could you send the deck before Friday?".utf8).base64EncodedString()
        #expect(MailParsing.body(b64, headers: ["content-transfer-encoding": "base64", "content-type": "text/plain"]) == "Could you send the deck before Friday?")
    }

    @Test func aMultipartMessagePrefersThePlainTextPart() {
        let raw = [
            "--SEP", "Content-Type: text/plain; charset=UTF-8", "", "the plain words", "",
            "--SEP", "Content-Type: text/html; charset=UTF-8", "", "<p>the <b>html</b> words</p>", "",
            "--SEP--", ""
        ].joined(separator: "\r\n")
        #expect(MailParsing.body(raw, headers: ["content-type": "multipart/alternative; boundary=\"SEP\""]) == "the plain words")
    }

    @Test func withNoPlainPartTheHtmlIsStrippedRatherThanDropped() {
        let raw = ["--SEP", "Content-Type: text/html", "", "<p>Hello <b>Tanvi</b></p><script>ignore()</script>", "", "--SEP--", ""].joined(separator: "\r\n")
        let out = MailParsing.body(raw, headers: ["content-type": "multipart/alternative; boundary=SEP"])
        #expect(out.contains("Hello") && out.contains("Tanvi"))
        #expect(!out.contains("ignore()"), "a script block is not words anybody said")
        #expect(!out.contains("<"))
    }

    @Test func htmlEntitiesBecomeTheCharactersTheyName() {
        #expect(MailParsing.stripTags("<p>Tanvi &amp; Lokesh &lt;both&gt;&nbsp;replied</p>") == "Tanvi & Lokesh <both> replied")
    }

    @Test func aParameterIsReadOutOfAContentTypeWithOrWithoutQuotes() {
        #expect(MailParsing.parameter("charset", in: "text/plain; charset=\"ISO-8859-1\"") == "ISO-8859-1")
        #expect(MailParsing.parameter("boundary", in: "multipart/mixed; boundary=abc123") == "abc123")
        #expect(MailParsing.parameter("charset", in: "text/plain") == nil)
    }

    // MARK: - Dates

    @Test func theUsualDateSpellingsAreUnderstood() throws {
        let d = try #require(MailParsing.date("Mon, 7 Sep 2026 10:00:00 +0530"))
        #expect(abs(d.timeIntervalSince1970 - 1788755400) < 1)
        #expect(MailParsing.date("7 Sep 2026 10:00:00 +0000") != nil, "the day name is optional")
        #expect(MailParsing.date("Mon, 7 Sep 2026 10:00:00 +0000 (GMT)") != nil, "a trailing zone comment is ignored")
        #expect(MailParsing.date("nonsense") == nil)
    }

    @Test func imapSpellsItsOwnDateDifferentlyFromTheHeader() {
        #expect(MailParsing.internalDate("\" 7-Sep-2026 10:00:00 +0000\"") != nil)
        #expect(MailParsing.internalDate("7-Sep-2026 10:00:00 +0000") != nil)
    }

    @Test func theSearchDayIsAlwaysEnglishWhateverTheMacIsSetTo() {
        let d = Date(timeIntervalSince1970: 1788739200)   // 7 Sep 2026 UTC
        #expect(MailParsing.searchDay(d) == "7-Sep-2026")
    }
}
