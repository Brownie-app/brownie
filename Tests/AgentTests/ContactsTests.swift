import Testing
import Foundation
@testable import Agent
import Domain

/// A Contacts card as the registry reads it: a name, a nickname when set, and what the card proves. The CNContact work
/// stays in one function; this is the spelling that gets tested.
@Suite struct ContactsTests {
    @Test func aCardIsNamedGivenAndFamilyWithItsProofsSpelled() throws {
        let c = try #require(ContactLookup.card(givenName: "Lokesh", familyName: "Kadri", organization: "Harbour", nickname: "", phones: ["+91 90000 00111", "090000 00111"], emails: ["Lokesh@Harbour.test"]))
        #expect(c.name == "Lokesh Kadri" && c.nickname == nil)
        #expect(c.proofs == ["phone:919000000111", "phone:9000000111", "email:lokesh@harbour.test"], "each number as it was written, digits only; the email lower-cased")
    }

    @Test func aNicknameRidesAlongWhenSet() throws {
        let c = try #require(ContactLookup.card(givenName: "Lalita", familyName: "", organization: "", nickname: " Kan ", phones: [], emails: ["lalita@example.com"]))
        #expect(c.name == "Lalita" && c.nickname == "Kan")
    }

    @Test func theOrganisationNamesACardWithNoPersonName() throws {
        let c = try #require(ContactLookup.card(givenName: "", familyName: " ", organization: "Harbour Labs", nickname: "", phones: ["090000 00333"], emails: []))
        #expect(c.name == "Harbour Labs" && c.proofs == ["phone:9000000333"])
    }

    @Test func aCardWithNoNameAtAllIsSkipped() {
        #expect(ContactLookup.card(givenName: "", familyName: "", organization: "", nickname: "Kan", phones: ["+91 90000 00111"], emails: []) == nil)
    }

    @Test func aCardThatProvesNothingIsSkipped() {
        #expect(ContactLookup.card(givenName: "Kiran", familyName: "Mehra", organization: "", nickname: "", phones: [], emails: []) == nil)
        #expect(ContactLookup.card(givenName: "Kiran", familyName: "Mehra", organization: "", nickname: "", phones: ["ext 42"], emails: ["not-an-address"]) == nil, "a number too short to be a phone and a string with no @ prove nothing")
    }
}
