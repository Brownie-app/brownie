import Testing
import Foundation
@testable import Domain

/// One person is one identity: every ledger compares names through here, so the table below is the whole rule.
@Suite struct PersonKeyTests {
    @Test func normaliseKeepsTheFirstTwoWordsAndDropsNumbersAndSuffixes() {
        #expect(PersonKey.normalise("Kanika Pandey Loadmill") == "kanika pandey")
        #expect(PersonKey.normalise("Kanika Pandey") == "kanika pandey")
        #expect(PersonKey.normalise("Nitesh (+919540752593)") == "nitesh")
        #expect(PersonKey.normalise("Nitesh +91 95407 52593") == "nitesh")
        #expect(PersonKey.normalise("  nitesh ") == "nitesh")
        #expect(PersonKey.normalise("Zoë Müller-Brandt") == "zoe muller", "diacritics fold; a hyphen splits words")
        #expect(PersonKey.normalise("Arjun") == "arjun")
        #expect(PersonKey.normalise("+91 98765 43210") == "", "a bare number has no key")
        #expect(PersonKey.normalise("Rohan (work) (old number)") == "rohan", "every parenthesised part goes")
    }

    @Test func sameIsForgivingAboutSuffixesNumbersAndCase() {
        #expect(PersonKey.same("Kanika Pandey Loadmill", "Kanika Pandey"))
        #expect(PersonKey.same("Nitesh (+919540752593)", "Nitesh"))
        #expect(PersonKey.same("KANIKA PANDEY", "kanika pandey"))
        #expect(!PersonKey.same("Kanika Sharma", "Kanika Pandey"), "a different surname is a different person")
        #expect(!PersonKey.same("Rohan", "Priya"))
        #expect(!PersonKey.same("+91 98765 43210", "+91 98765 43210"), "two unnamed numbers are never the same person by key")
        #expect(!PersonKey.same("", "Nitesh"))
    }

    @Test func aFirstNameAloneMatchesTheLedgersButNeverATitle() {
        // The ledgers may treat "Arjun" and "Arjun Mehta" as one; picking a note goes through the registry,
        // which asks how many Arjuns there are. The strict key never lets a first name claim a fuller title.
        #expect(PersonKey.normalise("Arjun") != PersonKey.normalise("Arjun Mehta"))
        #expect(PersonKey.same("Arjun", "Arjun Mehta") && PersonKey.same("Arjun Mehta", "Arjun"))
        #expect(!PersonKey.sameKey("Arjun", "Arjun Mehta") && !PersonKey.sameKey("Arjun Mehta", "Arjun"))
        #expect(PersonKey.sameKey("Kanika Pandey Loadmill", "Kanika Pandey"))
        #expect(PersonKey.sameKey("Nitesh (+91)", "Nitesh"))
        #expect(!PersonKey.sameKey("", ""))
    }

    @Test func displayNameDropsTheNumberButKeepsTheName() {
        #expect(PersonKey.displayName("Nitesh (+919540752593)") == "Nitesh")
        #expect(PersonKey.displayName("Kanika  Pandey ") == "Kanika Pandey")
        #expect(PersonKey.displayName("+91 98765 43210") == "+91 98765 43210", "nothing better than the number itself")
    }

    @Test func handlesAreSpelledOneWay() {
        #expect(PersonHandle.whatsapp(phoneDigits: "919540752593") == "whatsapp:+919540752593")
        #expect(PersonHandle.whatsapp(phoneDigits: "+91 95407-52593") == "whatsapp:+919540752593")
        #expect(PersonHandle.imessage("+91 95407 52593") == "imessage:+919540752593")
        #expect(PersonHandle.imessage("Someone@iCloud.com") == "imessage:someone@icloud.com")
        #expect(PersonHandle.slack(userID: "U0ABC") == "slack:U0ABC")
        #expect(PersonHandle.teams(userID: "8:orgid:x") == "teams:8:orgid:x")
        #expect(PersonHandle.telegram(chatID: 777) == "telegram:777")
    }
}
