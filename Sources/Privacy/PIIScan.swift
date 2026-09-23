import Foundation

/// Deterministic high-risk identifier detection. Runs on summaries and titles — behind the model,
/// never instead of it. A hit drops the whole item as sensitive.
public enum PIIScan {
    public static func highRiskHit(_ text: String) -> String? {
        if hasUSSSN(text) { return "us-ssn" }
        if hasLuhnCard(text) { return "card-number" }
        if hasAadhaar(text) { return "aadhaar" }
        if hasPAN(text) { return "pan" }
        if hasPassport(text) { return "passport" }
        if hasBankAccountWithIFSC(text) { return "bank-account" }
        return nil
    }

    // 123-45-6789 (with separators, to avoid matching ordinary 9-digit numbers)
    static func hasUSSSN(_ t: String) -> Bool {
        t.range(of: #"\b(?!000|666|9\d\d)\d{3}[- ](?!00)\d{2}[- ](?!0000)\d{4}\b"#, options: .regularExpression) != nil
    }

    // 13–19 digits with optional spaces/dashes, Luhn-valid
    static func hasLuhnCard(_ t: String) -> Bool {
        let re = try! NSRegularExpression(pattern: #"\b(?:\d[ -]?){13,19}\b"#)
        let ns = t as NSString
        for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            let digits = ns.substring(with: m.range).filter(\.isNumber)
            if (13...19).contains(digits.count), luhn(digits) { return true }
        }
        return false
    }

    static func luhn(_ digits: String) -> Bool {
        var sum = 0, alt = false
        for ch in digits.reversed() {
            guard var d = ch.wholeNumberValue else { return false }
            if alt { d *= 2; if d > 9 { d -= 9 } }
            sum += d; alt.toggle()
        }
        return sum % 10 == 0
    }

    // 12 digits, first digit 2–9, Verhoeff-valid, optionally grouped 4-4-4
    static func hasAadhaar(_ t: String) -> Bool {
        let re = try! NSRegularExpression(pattern: #"\b[2-9]\d{3}[ -]?\d{4}[ -]?\d{4}\b"#)
        let ns = t as NSString
        for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            let digits = ns.substring(with: m.range).filter(\.isNumber)
            if digits.count == 12, verhoeff(digits) { return true }
        }
        return false
    }

    static func verhoeff(_ num: String) -> Bool {
        let d: [[Int]] = [[0,1,2,3,4,5,6,7,8,9],[1,2,3,4,0,6,7,8,9,5],[2,3,4,0,1,7,8,9,5,6],[3,4,0,1,2,8,9,5,6,7],[4,0,1,2,3,9,5,6,7,8],
                          [5,9,8,7,6,0,4,3,2,1],[6,5,9,8,7,1,0,4,3,2],[7,6,5,9,8,2,1,0,4,3],[8,7,6,5,9,3,2,1,0,4],[9,8,7,6,5,4,3,2,1,0]]
        let p: [[Int]] = [[0,1,2,3,4,5,6,7,8,9],[1,5,7,6,2,8,3,0,9,4],[5,8,0,3,7,9,6,1,4,2],[8,9,1,6,0,4,3,5,2,7],
                          [9,4,5,3,1,2,6,8,7,0],[4,2,8,6,5,7,3,9,0,1],[2,7,9,3,8,0,6,4,1,5],[7,0,4,6,9,1,3,2,5,8]]
        var c = 0
        for (i, ch) in num.reversed().enumerated() {
            guard let n = ch.wholeNumberValue else { return false }
            c = d[c][p[i % 8][n]]
        }
        return c == 0
    }

    // Indian PAN: ABCDE1234F, with the 4th letter a valid holder type and a word boundary
    static func hasPAN(_ t: String) -> Bool {
        t.range(of: #"\b[A-Z]{3}[ABCFGHLJPT][A-Z]\d{4}[A-Z]\b"#, options: .regularExpression) != nil
    }

    // Passport-shaped number *next to* the word passport (the shape alone is too common)
    static func hasPassport(_ t: String) -> Bool {
        t.range(of: #"(?i)passport\s*(?:no\.?|number|#|:)?\s*[A-Z]\d{7,8}\b"#, options: .regularExpression) != nil
    }

    // IFSC code + a 9–18 digit number in the same text
    static func hasBankAccountWithIFSC(_ t: String) -> Bool {
        t.range(of: #"\b[A-Z]{4}0[A-Z0-9]{6}\b"#, options: .regularExpression) != nil
            && t.range(of: #"\b\d{9,18}\b"#, options: .regularExpression) != nil
    }
}
