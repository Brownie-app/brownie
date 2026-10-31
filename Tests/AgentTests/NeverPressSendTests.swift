import Testing
@testable import Agent

/// Invariant 4: nothing is sent, paid, submitted or deleted without the user's tap on that step.
///
/// The README calls this "the whole design", and says it is enforced in code rather than in a prompt.
/// Two of the four ways Hands can commit something were not enforced at all:
///
/// - `press(id:)` and `press_text` check the element's title — those were always right.
/// - Return checked for a committing button **and** that the app was Messages, so the same keystroke
///   in WhatsApp, Slack, Telegram, Mail or a browser sent the message with only the prompt objecting.
/// - A click at a bare coordinate checked nothing whatsoever.
///
/// These cover the rules, not the AX plumbing: the plumbing gathers titles and hands them here.
@Suite struct NeverPressSendTests {

    let ask = Hands.Policy().alwaysAskBefore

    // MARK: - Return

    /// The regression this suite exists for. Each of these is a real compose window.
    @Test func returnIsStoppedInEveryAppNotJustMessages() {
        for app in [["Send"], ["Send message"], ["Send Now"], ["Post"], ["Submit"], ["Pay"], ["Transfer"]] {
            #expect(HandsGuard.returnWouldCommit(buttonTitles: app, focusIsTextField: true, askBefore: ask),
                    "Return over \(app) has to stop — it used to go through outside Messages")
        }
    }

    @Test func caseAndSurroundingWordsDoNotMatter() {
        #expect(HandsGuard.returnWouldCommit(buttonTitles: ["SEND"], focusIsTextField: true, askBefore: ask))
        #expect(HandsGuard.returnWouldCommit(buttonTitles: ["Reply", "Send to Lalita"], focusIsTextField: true, askBefore: ask))
    }

    /// The other half: a guard that stops everything is a guard nobody keeps.
    @Test func returnIsFreeWhereNothingCommits() {
        #expect(!HandsGuard.returnWouldCommit(buttonTitles: ["Search", "Cancel", "Add"], focusIsTextField: true, askBefore: ask))
        #expect(!HandsGuard.returnWouldCommit(buttonTitles: [], focusIsTextField: true, askBefore: ask))
    }

    /// Return only commits from inside a field. With focus on the window itself it scrolls or does nothing.
    @Test func returnOutsideATextFieldIsNotACommit() {
        #expect(!HandsGuard.returnWouldCommit(buttonTitles: ["Send"], focusIsTextField: false, askBefore: ask))
    }

    // MARK: - A click at a bare coordinate

    @Test func aClickOntoACommittingControlIsStopped() {
        for words in ["Button “Send”", "Button “Send Message”", "MenuItem “Delete”", "Link “Submit”", "Button “Pay now”"] {
            #expect(HandsGuard.clickWouldCommit(on: words, askBefore: ask), "\(words) commits")
        }
    }

    @Test func aClickOntoAnythingElseGoesThrough() {
        for words in ["Button “Cancel”", "TextArea “”", "Row “Lalita Pathak”", "Button “Attach”", ""] {
            #expect(!HandsGuard.clickWouldCommit(on: words, askBefore: ask), "\(words) commits nothing")
        }
    }

    /// The false positive worth avoiding: a message that merely contains the word.
    @Test func textThatMentionsSendingIsNotAButton() {
        #expect(!HandsGuard.clickWouldCommit(on: "StaticText “did you send the deposit?”", askBefore: ask))
        #expect(!HandsGuard.clickWouldCommit(on: "Cell “Send me the deck when you can”", askBefore: ask))
    }

    /// Nothing under the point means nothing to commit — a click into empty space is not a send.
    @Test func anUnresolvedPointCommitsNothing() {
        #expect(!HandsGuard.clickWouldCommit(on: "", askBefore: ask))
    }

    // MARK: - The list itself

    @Test func everyIrreversibleWordIsCovered() {
        for word in ask {
            #expect(HandsGuard.returnWouldCommit(buttonTitles: [word.capitalized], focusIsTextField: true, askBefore: ask),
                    "“\(word)” is in the policy but Return does not stop for it")
            #expect(HandsGuard.clickWouldCommit(on: "Button “\(word.capitalized)”", askBefore: ask),
                    "“\(word)” is in the policy but a click does not stop for it")
        }
    }
}
