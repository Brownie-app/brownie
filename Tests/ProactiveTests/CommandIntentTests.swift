import Testing
@testable import Proactive

/// The ⌘⇧Space rule: a question is answered from the notes; anything else goes to Hands.
@Suite struct CommandIntentTests {
    @Test(arguments: [
        "what did I promise Meera?", "What did I promise Meera", "who is Karan", "when is the villa hold ending",
        "did I reply to Ankit", "Where did we leave the pricing", "how many open loops with Rohan", "which flight did Priya pick",
        "is Meera waiting on me", "are there any invoices due", "have I paid the landlord", "any promises to Nayan",
        "What's still open with the landlord", "who's coming on Sunday", "Reply to Rohan?", "  did I ?  ", "कब है मीटिंग?",
    ]) func questions(_ q: String) {
        #expect(CommandIntent.isQuestion(q), "\(q) should be answered from the notes")
    }

    @Test(arguments: [
        "reply to Rohan about the villa", "send Meera the pricing notes", "book a table for Sunday", "Morning invoices",
        "open WhatsApp and search for Vivek", "draft a message to Ankit", "run Morning invoices", "Whatever you do, don't send",
        "Whatsapp Priya", "", "   ",
    ]) func goals(_ g: String) {
        #expect(!CommandIntent.isQuestion(g), "\(g) is a goal for Hands, not a question")
    }

    @Test func classifyTrimsAndTags() {
        #expect(CommandIntent.classify("  who is Karan?  ") == .question("who is Karan?"))
        #expect(CommandIntent.classify(" reply to Karan ") == .goal("reply to Karan"))
    }
}
