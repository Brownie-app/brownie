import Testing
@testable import Proactive

/// The ⌘⇧Space rule: a question is answered from the notes; anything else goes to Hands.
@Suite struct CommandIntentTests {
    @Test(arguments: [
        "what did I promise Meena?", "What did I promise Meena", "who is Devan", "when is the villa hold ending",
        "did I reply to Tarun", "Where did we leave the pricing", "how many open loops with Zubin", "which flight did Tanvi pick",
        "is Meena waiting on me", "are there any invoices due", "have I paid the landlord", "any promises to Nayra",
        "What's still open with the landlord", "who's coming on Sunday", "Reply to Zubin?", "  did I ?  ", "कब है मीटिंग?",
    ]) func questions(_ q: String) {
        #expect(CommandIntent.isQuestion(q), "\(q) should be answered from the notes")
    }

    @Test(arguments: [
        "reply to Zubin about the villa", "send Meena the pricing notes", "book a table for Sunday", "Morning invoices",
        "open WhatsApp and search for Ishan", "draft a message to Tarun", "run Morning invoices", "Whatever you do, don't send",
        "Whatsapp Tanvi", "", "   ",
    ]) func goals(_ g: String) {
        #expect(!CommandIntent.isQuestion(g), "\(g) is a goal for Hands, not a question")
    }

    @Test func classifyTrimsAndTags() {
        #expect(CommandIntent.classify("  who is Devan?  ") == .question("who is Devan?"))
        #expect(CommandIntent.classify(" reply to Devan ") == .goal("reply to Devan"))
    }
}
