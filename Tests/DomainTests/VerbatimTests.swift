import Testing
import Foundation
import Domain

/// UNIT. Checking a claim against the messages it is supposed to have come from.
///
/// Every case here is taken from one real ledger of twenty-two loops, audited line by line. That audit is the
/// reason this code exists, so the tests are the audit: if a change makes one of these pass again, the bug it
/// describes is back.
@Suite struct VerbatimTests {

    func line(_ text: String, id: String = "1", day: Int = 0) -> SourceLine {
        SourceLine(id: id, said: Date(timeIntervalSinceReferenceDate: 814_000_000 + Double(day) * 86400), text: text)
    }

    // MARK: - Folding

    @Test func foldingIgnoresEverythingThatIsNotTheWords() {
        #expect(Verbatim.fold("  Hi,  Asha!  ") == "hi asha")
        #expect(Verbatim.fold("\u{200E}9 lakh\u{200F}") == "9 lakh", "a chat export is full of bidi marks")
        #expect(Verbatim.fold("₹17,00,000") == "1700000", "currency marks go; the digits are the claim")
        #expect(Verbatim.fold("A\nB\tC") == "a b c")
    }

    @Test func foldingKeepsDigitsApartFromLetters() {
        #expect(Verbatim.fold("v2.4.1") == "v241")
        #expect(Verbatim.fold("api-worker:latest") == "apiworkerlatest")
    }

    // MARK: - Finding the message a claim came from

    @Test func theSupportingLineIsTheMessageItselfNotAnExtractOfIt() throws {
        let msgs = [line("Hey, are we still on for Friday?", id: "A"),
                    line("Can you call me back when you get a chance? Missed you earlier.", id: "B")]
        let span = try #require(Verbatim.support(for: "Call Asha back", in: msgs))
        #expect(span.messageID == "B")
        #expect(span.text == "Can you call me back when you get a chance? Missed you earlier.",
                "the span is what was said, whole — choosing which part mattered would be one more judgement that can be wrong")
    }

    @Test func aClaimNothingResemblesGetsNoSpan() {
        let msgs = [line("lunch at 1?"), line("sure, see you there")]
        #expect(Verbatim.support(for: "Send the signed lease to the landlord's solicitor", in: msgs) == nil)
    }

    /// The distinction the whole design rests on: no span is "unproven", and callers must not read it as "false".
    @Test func noMessagesAtAllIsUnprovenRatherThanDisproven() {
        #expect(Verbatim.support(for: "Call Asha back", in: []) == nil)
        #expect(Specifics.unsupported(in: "Call Asha back about the 9 lakh funding", against: []).isEmpty,
                "a chat that cannot be read must never be able to condemn a claim")
    }

    @Test func aSpanIsCappedSoItIsEvidenceAndNotACopyOfTheConversation() {
        let long = String(repeating: "word ", count: 200)
        let span = Span(SourceLine(id: "A", said: .distantPast, text: long))
        #expect(span.text.count == Verbatim.spanLimit)
    }

    @Test func appearsWantsTheActualWordingAndIsNotFooledByShortMatches() {
        let msgs = [line("I'll send the deposit receipt tomorrow morning")]
        #expect(Verbatim.appears("send the deposit receipt", in: msgs))
        #expect(Verbatim.appears("SEND THE DEPOSIT RECEIPT", in: msgs), "folded, so case and punctuation do not matter")
        #expect(!Verbatim.appears("ok", in: msgs), "two letters appear in everything and prove nothing")
        #expect(!Verbatim.appears("send the deposit cheque", in: msgs))
    }

    // MARK: - Specifics

    @Test func theThingsWorthCheckingAreTheOnesThatCannotBeNearlyRight() {
        #expect(Specifics.found(in: "Call Asha back about the potential 9 lakh funding") == ["9 lakh"])
        #expect(Specifics.found(in: "Share the image with 10020030040050010") == ["10020030040050010"])
        #expect(Specifics.found(in: "Send the proposal by 30 Sep").contains("30 Sep"))
        #expect(Specifics.found(in: "Pay the 40% deposit").contains("40%"))
        #expect(Specifics.found(in: "Ship api-worker:latest").contains("api-worker:latest"))
    }

    @Test func smallRoundNumbersDriftHarmlesslyAndAreNotWorthAGate() {
        #expect(Specifics.found(in: "Provide rough estimates for the three requested tasks").isEmpty)
        #expect(Specifics.found(in: "Send Ishan the final proposal for commentary on slides 6-11").allSatisfy { $0 != "6" },
                "a slide range is not an amount somebody can be wrong about in the way 9 lakh is")
        #expect(Specifics.found(in: "Copy Lanterna design for the product").isEmpty)
    }

    /// THE case. One real message, and a loop that named a figure nobody mentioned.
    @Test func anAmountNoMessageContainsIsUnsupported() {
        let msgs = [line("Hi, tried calling you. Please call back when free."),
                    line("Sorry, was travelling for work — will call you back.")]
        #expect(Specifics.unsupported(in: "Call Asha Mehra back about the potential 9 lakh funding", against: msgs) == ["9 lakh"])
    }

    @Test func anAmountTheMessageDoesContainPasses() {
        let msgs = [line("We can look at a funding of 9 lakh next month"), line("ok, call me")]
        #expect(Specifics.unsupported(in: "Call Asha back about the potential 9 lakh funding", against: msgs).isEmpty)
    }

    /// The failure mode a model-written quote can never catch: the claim and its "evidence" carry the same
    /// wrong digits, so they agree with each other. Only the message settles it.
    @Test func aCorruptedIdentifierFailsEvenThoughTheModelsOwnQuoteAgreesWithIt() {
        let msgs = [line("push it to 100200300400500.dkr.ecr.eu-west-1.amazonaws.com please")]
        #expect(Specifics.unsupported(in: "Share the corrected image with 100200300400500", against: msgs).isEmpty,
                "the real id passes")
        #expect(Specifics.unsupported(in: "Share the corrected image with 10020030040050010", against: msgs) == ["10020030040050010"],
                "a digit inserted makes a different id, and there is no such thing as nearly the right one")
        #expect(Specifics.unsupported(in: "Share the corrected image with 10020030045040500", against: msgs) == ["10020030045040500"])
    }

    @Test func anImpossibleDateIsNotInAnyMessageEither() {
        let msgs = [line("shall we say the 10th at 8pm?")]
        #expect(!Specifics.unsupported(in: "Meet Dyu on October 109", against: msgs).isEmpty)
    }

    @Test func anAmountIsMatchedThroughFormattingAndCurrencyMarks() {
        #expect(Specifics.unsupported(in: "transfer 1700000 to the account", against: [line("please transfer ₹17,00,000 today")]).isEmpty,
                "the same number written two ways is the same number")
    }

    // MARK: - Repairing a claim

    @Test func onlyTheInventedClauseGoesAndThePromiseStays() {
        #expect(Claim.withoutUnsupported("Call Asha Mehra back about the potential 9 lakh funding", specifics: ["9 lakh"])
                == "Call Asha Mehra back")
        #expect(Claim.withoutUnsupported("Share Ravi the corrected api-worker:latest image with 10020030040050010", specifics: ["10020030040050010"])
                == "Share Ravi the corrected api-worker:latest image")
    }

    @Test func aClaimThatIsNothingButTheInventedPartIsRefusedRatherThanMangled() {
        #expect(Claim.withoutUnsupported("9 lakh", specifics: ["9 lakh"]) == nil)
        #expect(Claim.withoutUnsupported("Pay 9 lakh", specifics: ["9 lakh"]) == nil, "“Pay” on its own is not a promise")
    }

    @Test func nothingUnsupportedMeansNothingChanges() {
        let claim = "Call Noor about the lease"
        #expect(Claim.withoutUnsupported(claim, specifics: []) == claim)
    }

    @Test func aCommaIsAClauseBoundaryToo() {
        #expect(Claim.withoutUnsupported("Email Tanvi the address, 9 lakh included", specifics: ["9 lakh"])
                == "Email Tanvi the address")
    }
}
