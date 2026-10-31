import Testing
import Foundation
@testable import Domain

/// One person is one identity: every ledger compares names through here, so the table below is the whole rule.
@Suite struct PersonKeyTests {
    @Test func normaliseKeepsTheFirstTwoWordsAndDropsNumbersAndSuffixes() {
        #expect(PersonKey.normalise("Lalita Pathak Tideline") == "lalita pathak")
        #expect(PersonKey.normalise("Lalita Pathak") == "lalita pathak")
        #expect(PersonKey.normalise("Lokesh (+919000000111)") == "lokesh")
        #expect(PersonKey.normalise("Lokesh +91 90000 00111") == "lokesh")
        #expect(PersonKey.normalise("  lokesh ") == "lokesh")
        #expect(PersonKey.normalise("Zoë Müller-Brandt") == "zoe muller", "diacritics fold; a hyphen splits words")
        #expect(PersonKey.normalise("Kiran") == "kiran")
        #expect(PersonKey.normalise("+91 90000 00666") == "", "a bare number has no key")
        #expect(PersonKey.normalise("Zubin (work) (old number)") == "zubin", "every parenthesised part goes")
    }

    @Test func sameIsForgivingAboutSuffixesNumbersAndCase() {
        #expect(PersonKey.same("Lalita Pathak Tideline", "Lalita Pathak"))
        #expect(PersonKey.same("Lokesh (+919000000111)", "Lokesh"))
        #expect(PersonKey.same("LALITA PATHAK", "lalita pathak"))
        #expect(!PersonKey.same("Lalita Dalal", "Lalita Pathak"), "a different surname is a different person")
        #expect(!PersonKey.same("Zubin", "Tanvi"))
        #expect(!PersonKey.same("+91 90000 00666", "+91 90000 00666"), "two unnamed numbers are never the same person by key")
        #expect(!PersonKey.same("", "Lokesh"))
    }

    @Test func aFirstNameAloneMatchesTheLedgersButNeverATitle() {
        // The ledgers may treat "Kiran" and "Kiran Bose" as one; picking a note goes through the registry,
        // which asks how many Kirans there are. The strict key never lets a first name claim a fuller title.
        #expect(PersonKey.normalise("Kiran") != PersonKey.normalise("Kiran Bose"))
        #expect(PersonKey.same("Kiran", "Kiran Bose") && PersonKey.same("Kiran Bose", "Kiran"))
        #expect(!PersonKey.sameKey("Kiran", "Kiran Bose") && !PersonKey.sameKey("Kiran Bose", "Kiran"))
        #expect(PersonKey.sameKey("Lalita Pathak Tideline", "Lalita Pathak"))
        #expect(PersonKey.sameKey("Lokesh (+91)", "Lokesh"))
        #expect(!PersonKey.sameKey("", ""))
    }

    @Test func displayNameDropsTheNumberButKeepsTheName() {
        #expect(PersonKey.displayName("Lokesh (+919000000111)") == "Lokesh")
        #expect(PersonKey.displayName("Lalita  Pathak ") == "Lalita Pathak")
        #expect(PersonKey.displayName("+91 90000 00666") == "+91 90000 00666", "nothing better than the number itself")
    }

    @Test func handlesAreSpelledOneWay() {
        #expect(PersonHandle.whatsapp(phoneDigits: "919000000111") == "whatsapp:+919000000111")
        #expect(PersonHandle.whatsapp(phoneDigits: "+91 90000-00111") == "whatsapp:+919000000111")
        #expect(PersonHandle.imessage("+91 90000 00111") == "imessage:+919000000111")
        #expect(PersonHandle.imessage("Someone@iCloud.com") == "imessage:someone@icloud.com")
        #expect(PersonHandle.slack(userID: "U0ABC") == "slack:U0ABC")
        #expect(PersonHandle.teams(userID: "8:orgid:x") == "teams:8:orgid:x")
        #expect(PersonHandle.telegram(chatID: 777) == "telegram:777")
    }
}
