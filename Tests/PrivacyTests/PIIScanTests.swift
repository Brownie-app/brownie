import Testing
import Foundation
@testable import Privacy
import Domain

@Suite struct PIIScanTests {
    @Test func testSSN() { #expect(PIIScan.highRiskHit("ssn 123-45-6789 please") == "us-ssn"); #expect(PIIScan.highRiskHit("order 123456789") == nil) }
    @Test func testCard() { #expect(PIIScan.highRiskHit("card 4111 1111 1111 1111") == "card-number"); #expect(PIIScan.highRiskHit("4111 1111 1111 1112") == nil) }
    @Test func testAadhaar() { #expect(PIIScan.highRiskHit("aadhaar 2345 6789 0124 ok?") == (PIIScan.verhoeff("234567890124") ? "aadhaar" : nil)) }
    @Test func testPAN() { #expect(PIIScan.highRiskHit("PAN ABCPE1234F") == "pan"); #expect(PIIScan.highRiskHit("ticket ABCDE1234F") == nil) }
    @Test func testPassport() { #expect(PIIScan.highRiskHit("passport no Z1234567") == "passport"); #expect(PIIScan.highRiskHit("Z1234567") == nil) }
    @Test func testCleanText() { #expect(PIIScan.highRiskHit("The user is moving to Capitol Hill on the 15th; Maya visits in June.") == nil) }

    @Test func testPolicyFailsClosed() {
        let p = DefaultSensitivityPolicy()
        #expect(p.admit(Judgement(summary: "", title: "x", keep: true, sensitive: false)).reason == .emptySummary)
        #expect(p.admit(Judgement(summary: "card 4111 1111 1111 1111", title: "x", keep: true, sensitive: false)).reason == .piiBackstop)
        #expect(p.admit(Judgement(summary: "fine", title: "x", keep: true, sensitive: true)).reason == .modelSensitive)
        #expect(p.admit(Judgement(summary: "fine", title: "x", keep: false, sensitive: false)).reason == .modelDrop)
        let ok = p.admit(Judgement(summary: "The user signed a lease.", title: "Lease", keep: true, sensitive: false))
        #expect(ok.reason == .kept); #expect(ok.survivor?.title == "Lease")
    }
}
