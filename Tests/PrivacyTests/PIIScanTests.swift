import XCTest
@testable import Privacy
import Domain

final class PIIScanTests: XCTestCase {
    func testSSN() { XCTAssertEqual(PIIScan.highRiskHit("ssn 123-45-6789 please"), "us-ssn"); XCTAssertNil(PIIScan.highRiskHit("order 123456789")) }
    func testCard() { XCTAssertEqual(PIIScan.highRiskHit("card 4111 1111 1111 1111"), "card-number"); XCTAssertNil(PIIScan.highRiskHit("4111 1111 1111 1112")) }
    func testAadhaar() { XCTAssertEqual(PIIScan.highRiskHit("aadhaar 2345 6789 0124 ok?"), PIIScan.verhoeff("234567890124") ? "aadhaar" : nil) }
    func testPAN() { XCTAssertEqual(PIIScan.highRiskHit("PAN ABCPE1234F"), "pan"); XCTAssertNil(PIIScan.highRiskHit("ticket ABCDE1234F")) }
    func testPassport() { XCTAssertEqual(PIIScan.highRiskHit("passport no Z1234567"), "passport"); XCTAssertNil(PIIScan.highRiskHit("Z1234567")) }
    func testCleanText() { XCTAssertNil(PIIScan.highRiskHit("The user is moving to Capitol Hill on the 15th; Maya visits in June.")) }

    func testPolicyFailsClosed() {
        let p = DefaultSensitivityPolicy()
        XCTAssertEqual(p.admit(Judgement(summary: "", title: "x", keep: true, sensitive: false)).reason, .emptySummary)
        XCTAssertEqual(p.admit(Judgement(summary: "card 4111 1111 1111 1111", title: "x", keep: true, sensitive: false)).reason, .piiBackstop)
        XCTAssertEqual(p.admit(Judgement(summary: "fine", title: "x", keep: true, sensitive: true)).reason, .modelSensitive)
        XCTAssertEqual(p.admit(Judgement(summary: "fine", title: "x", keep: false, sensitive: false)).reason, .modelDrop)
        let ok = p.admit(Judgement(summary: "The user signed a lease.", title: "Lease", keep: true, sensitive: false))
        XCTAssertEqual(ok.reason, .kept); XCTAssertEqual(ok.survivor?.title, "Lease")
    }
}
