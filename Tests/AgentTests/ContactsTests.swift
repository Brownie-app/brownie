import Testing
import Foundation
@testable import Agent
import Domain

/// A Contacts card as the registry reads it: a name, a nickname when set, and what the card proves. The CNContact work
/// stays in one function; this is the spelling that gets tested.
@Suite struct ContactsTests {
    @Test func aCardIsNamedGivenAndFamilyWithItsProofsSpelled() throws {
        let c = try #require(ContactLookup.card(givenName: "Nitesh", familyName: "Kumar", organization: "Loopsy", nickname: "", phones: ["+91 95407 52593", "095407 52593"], emails: ["Nitesh@Loopsy.in"]))
        #expect(c.name == "Nitesh Kumar" && c.nickname == nil)
        #expect(c.proofs == ["phone:919540752593", "phone:9540752593", "email:nitesh@loopsy.in"], "each number as it was written, digits only; the email lower-cased")
    }

    @Test func aNicknameRidesAlongWhenSet() throws {
        let c = try #require(ContactLookup.card(givenName: "Kanika", familyName: "", organization: "", nickname: " Kan ", phones: [], emails: ["kanika@example.com"]))
        #expect(c.name == "Kanika" && c.nickname == "Kan")
    }

    @Test func theOrganisationNamesACardWithNoPersonName() throws {
        let c = try #require(ContactLookup.card(givenName: "", familyName: " ", organization: "Loopsy Labs", nickname: "", phones: ["011 4100 2233"], emails: []))
        #expect(c.name == "Loopsy Labs" && c.proofs == ["phone:1141002233"])
    }

    @Test func aCardWithNoNameAtAllIsSkipped() {
        #expect(ContactLookup.card(givenName: "", familyName: "", organization: "", nickname: "Kan", phones: ["+91 95407 52593"], emails: []) == nil)
    }

    @Test func aCardThatProvesNothingIsSkipped() {
        #expect(ContactLookup.card(givenName: "Arjun", familyName: "Mehta", organization: "", nickname: "", phones: [], emails: []) == nil)
        #expect(ContactLookup.card(givenName: "Arjun", familyName: "Mehta", organization: "", nickname: "", phones: ["ext 42"], emails: ["not-an-address"]) == nil, "a number too short to be a phone and a string with no @ prove nothing")
    }
}
