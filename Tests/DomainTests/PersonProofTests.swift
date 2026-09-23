import Testing
import Foundation
@testable import Domain

@Suite struct PersonProofTests {
    @Test func phonesAndEmailsAreSpelledOneWay() {
        #expect(PersonProof.phone("+91 95407-52593") == "phone:919540752593" && PersonProof.phone("0091 9540752593") == "phone:919540752593" && PersonProof.phone("12345") == nil)
        #expect(PersonProof.email(" Nitesh@Loopsy.in ") == "email:nitesh@loopsy.in" && PersonProof.email("not-an-address") == nil && PersonProof.email("@x.com") == nil)
        #expect(PersonProof.all(phones: ["+91 9540752593", "919540752593", ""], emails: ["A@B.co", "a@b.co"]) == ["phone:919540752593", "email:a@b.co"])
    }
    @Test func aHandleProvesItselfWhenItIsANumberOrAnAddress() {
        #expect(PersonProof.fromHandle(PersonHandle.whatsapp(phoneDigits: "919540752593")) == "phone:919540752593")
        #expect(PersonProof.fromHandle(PersonHandle.imessage("nitesh@icloud.com")) == "email:nitesh@icloud.com")
        #expect(PersonProof.fromHandle(PersonHandle.imessage("+1 555 010 2030")) == "phone:15550102030")
        #expect(PersonProof.fromHandle(PersonHandle.slack(userID: "U0AB")) == nil && PersonProof.fromHandle("nonsense") == nil)
        let b = BucketInfo(id: BucketID("whatsapp:x"), name: "Nitesh", detail: "", isGroup: false, count: 1, handle: "whatsapp:+919540752593")
        #expect(b.proofs == ["phone:919540752593"], "a bucket's proofs default to what its handle proves")
        let c = ContactCard(name: "Nitesh Kumar", nickname: "Nitu", phones: ["+91 9540752593"], emails: ["nitesh@loopsy.in"])
        #expect(c.proofs == ["phone:919540752593", "email:nitesh@loopsy.in"])
    }
}
