import Testing
@testable import Domain

@Suite struct SignatureTests {
    @Test func addsOnceOnlyWhenOn() {
        #expect(Signature.apply("Hi Kanika", enabled: false) == "Hi Kanika")
        let signed = Signature.apply("Hi Kanika  \n", enabled: true)
        #expect(signed == "Hi Kanika\n\n---\nSent via Brownie · usebrownie.com")
        #expect(Signature.apply(signed, enabled: true) == signed, "never twice")
        #expect(Signature.apply("", enabled: true) == "", "nothing to sign")
        #expect(Signature.apply("see usebrownie.com for the app", enabled: true) == "see usebrownie.com for the app", "the site already named counts as signed")
    }
    @Test func stripReturnsTheDraftAlone() {
        let signed = Signature.apply("Hi Kanika", enabled: true)
        #expect(Signature.strip(signed) == "Hi Kanika" && Signature.strip("plain") == "plain" && Signature.has(signed) && !Signature.has("plain"))
    }
    @Test func theSignedDraftRidesOnTheRecipe() {
        let c = Card(id: "1", title: "t", sourceLabel: "s", why: "", actionLabel: "", dueLine: "", urgency: .low, draftLabel: "", draft: "Hi", recipe: .whatsapp(chat: "Kanika", body: "Hi"), evidence: [], verification: .verified, verifiedLine: "", createdAt: .init())
        let signed = c.withDraft(Signature.apply(c.draft, enabled: true))
        if case .whatsapp(_, let body, _) = signed.recipe { #expect(body.hasSuffix("usebrownie.com")) } else { Issue.record("recipe lost") }
    }
}
