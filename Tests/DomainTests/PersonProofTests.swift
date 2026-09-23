import Testing
import Foundation
@testable import Domain

@Suite struct PersonProofTests {
    @Test func phonesAndEmailsAreSpelledOneWay() {
        #expect(PersonProof.phone("+91 90000-00111") == "phone:919000000111" && PersonProof.phone("0091 9000000111") == "phone:919000000111" && PersonProof.phone("12345") == nil)
        #expect(PersonProof.email(" Lokesh@Harbour.test ") == "email:lokesh@harbour.test" && PersonProof.email("not-an-address") == nil && PersonProof.email("@x.com") == nil)
        #expect(PersonProof.all(phones: ["+91 9000000111", "919000000111", ""], emails: ["A@B.co", "a@b.co"]) == ["phone:919000000111", "email:a@b.co"])
    }
    @Test func aHandleProvesItselfWhenItIsANumberOrAnAddress() {
        #expect(PersonProof.fromHandle(PersonHandle.whatsapp(phoneDigits: "919000000111")) == "phone:919000000111")
        #expect(PersonProof.fromHandle(PersonHandle.imessage("lokesh@icloud.com")) == "email:lokesh@icloud.com")
        #expect(PersonProof.fromHandle(PersonHandle.imessage("+1 555 010 2030")) == "phone:15550102030")
        #expect(PersonProof.fromHandle(PersonHandle.slack(userID: "U0AB")) == nil && PersonProof.fromHandle("nonsense") == nil)
        let b = BucketInfo(id: BucketID("whatsapp:x"), name: "Lokesh", detail: "", isGroup: false, count: 1, handle: "whatsapp:+919000000111")
        #expect(b.proofs == ["phone:919000000111"], "a bucket's proofs default to what its handle proves")
        let c = ContactCard(name: "Lokesh Kadri", nickname: "Nitu", phones: ["+91 9000000111"], emails: ["lokesh@harbour.test"])
        #expect(c.proofs == ["phone:919000000111", "email:lokesh@harbour.test"])
    }
}
