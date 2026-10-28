import Testing
import Foundation
import CoreGraphics
@testable import Agent

/// UNIT. Deciding when Hands needs to look at the screen, and what it is told when it does.
///
/// The snapshot itself needs a running Mac with a frontmost app and Accessibility granted, so it cannot be
/// tested here. Everything around it can: which goals point at something, and whether the header built from a
/// snapshot actually says who the conversation is with. Those are the two things that failed in the field —
/// Hands answered "what would you like me to handle?" over an open WhatsApp chat.
@Suite struct ScreenContextTests {

    func element(_ id: Int, _ role: String, _ title: String, _ value: String = "", actions: [String] = []) -> UISnapshot.Element {
        UISnapshot.Element(id: id, role: role, title: title, value: value, frame: .zero, actions: actions, depth: 1)
    }

    @Test func aGoalThatPointsAtSomethingNeedsTheScreen() {
        for goal in ["Can you handle this", "handle it", "reply to her", "deal with this", "answer them",
                     "what does this say", "send him the file", "sort that out"] {
            #expect(ScreenContext.needsScreen(goal), "\(goal) cannot be acted on without knowing what is on screen")
        }
    }

    @Test func aGoalThatNamesWhatItWantsDoesNot() {
        for goal in ["open amazon and search for an iphone", "open the WhatsApp chat with Kanika",
                     "book a table at Toit for Friday", "find the lease in Documents"] {
            #expect(!ScreenContext.needsScreen(goal), "\(goal) says what it means, so the header is not worth its tokens")
        }
    }

    /// "it" inside another word must not count — "submit", "edit", "with" all contain it.
    @Test func aPointingWordIsAWholeWordNotASyllable() {
        #expect(!ScreenContext.needsScreen("submit the form"))
        #expect(!ScreenContext.needsScreen("edit the title"))
        #expect(!ScreenContext.needsScreen("open github"))
        #expect(ScreenContext.needsScreen("submit it"), "but the word on its own does")
    }

    @Test func theHeaderNamesTheAppTheWindowAndWhoIsTalking() throws {
        let snap = UISnapshot(app: "\u{200E}WhatsApp", window: "\u{200E}WhatsApp", elements: [
            element(1, "Window", "WhatsApp"),
            element(2, "StaticText", "\u{200E}Kanika Pandey Loadmill"),
            element(3, "StaticText", "", "Did you call Mr Taragi yet?"),
            element(4, "TextArea", "\u{200E}Compose message", "", actions: ["Focus"]),
        ])
        let header = try #require(ScreenContext.header(snap))
        #expect(header.contains("app: WhatsApp"), "and without the bidi marks the tree is full of")
        #expect(header.contains("Kanika Pandey Loadmill"), "who it is with is the whole point")
        #expect(header.contains("Did you call Mr Taragi yet?"), "and what was said")
        #expect(header.contains("the cursor is in: Compose message"), "so it knows where a reply would land")
        #expect(header.contains("do not ask the user to repeat it"), "the instruction that stops it asking back")
    }

    @Test func theHeaderIsBoundedSoItCannotCrowdOutTheTask() throws {
        let many = (1...60).map { element($0, "StaticText", "", "line number \($0) of a very long conversation") }
        let header = try #require(ScreenContext.header(UISnapshot(app: "Mail", window: "Inbox", elements: many), lines: 12))
        #expect(header.components(separatedBy: "line number").count - 1 == 12, "the newest twelve, no more")
        #expect(header.contains("line number 60"), "and they are the newest, not the oldest")
        #expect(!header.contains("line number 1 of"))
    }

    @Test func nothingFrontmostIsNoHeaderRatherThanAnEmptyOne() {
        #expect(ScreenContext.header(nil) == nil)
    }

    @Test func aScreenWithNothingReadableStillNamesTheApp() throws {
        let header = try #require(ScreenContext.header(UISnapshot(app: "Preview", window: "lease.pdf", elements: [])))
        #expect(header.contains("app: Preview") && header.contains("window: lease.pdf"))
        #expect(!header.contains("on screen:"), "no content is better than an empty heading")
    }
}
