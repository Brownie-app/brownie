import Testing
import Foundation
import Domain

/// UNIT. What a person is told about Apple Intelligence, and what they are offered, for every state this Mac
/// can be in — including the four nobody can reproduce on the machine they happen to be sitting at.
///
/// This is why `AppleBrainState` has no `FoundationModels` in it. That framework exists only on macOS 26, and
/// only answers for the Mac the test is running on, so a test that asked it could never cover "not eligible"
/// and "still downloading" at the same time. Here every state is a value, so every state is testable, in CI,
/// on any machine. `AppleBrain` is then a thin mapping from Apple's enum onto these, and that mapping is the
/// only part needing real hardware.
@Suite struct AppleBrainStateTests {

    @Test func onlyAStateSomebodyCanReachIsOffered() {
        #expect(AppleBrainState.available.isOffered)
        #expect(AppleBrainState.notEnabled.isOffered, "a switch they can flip is worth showing — that is the whole feature")
        #expect(AppleBrainState.notReady.isOffered, "it becomes available on its own; saying so is better than hiding it")
        #expect(!AppleBrainState.notEligible.isOffered, "this hardware never will, so it is noise in a list of seven")
        #expect(!AppleBrainState.needsNewerMacOS.isOffered)
    }

    @Test func onlyAReadyMacCanActuallyRunANight() {
        #expect(AppleBrainState.available.isUsable)
        for s: AppleBrainState in [.notEnabled, .notReady, .notEligible, .needsNewerMacOS] {
            #expect(!s.isUsable, "\(s) must not be handed to a run")
        }
    }

    @Test func aButtonIsOfferedOnlyWherePressingItHelps() {
        #expect(AppleBrainState.notEnabled.action == "Turn it on")
        #expect(AppleBrainState.notEnabled.isFixable)
        for s: AppleBrainState in [.available, .notReady, .notEligible, .needsNewerMacOS] {
            #expect(s.action == nil, "\(s): a button into a pane with no switch in it is worse than no button")
            #expect(!s.isFixable)
        }
    }

    @Test func everyStateSaysAWholeSentence() {
        for s: AppleBrainState in [.available, .notEnabled, .notReady, .notEligible, .needsNewerMacOS] {
            #expect(!s.line.isEmpty)
            #expect(!s.line.hasSuffix("!"), "the app does not shout")
            #expect(s.line.first!.isUppercase && s.line.hasSuffix("."), "a whole sentence: \(s.line)")
        }
        #expect(AppleBrainState.notEligible.line.contains("can't run"), "say so plainly rather than hinting")
        #expect(AppleBrainState.notReady.line.contains("nothing for you to do"), "and say when waiting is the answer")
    }

    /// The nudge is the part most likely to become nagging, so what it must NOT do is pinned harder than what it does.
    @Test func theNudgeIsOfferedOnlyWhenThereIsSomethingBetterToOffer() {
        #expect(AppleBrainState.notEnabled.nudgeFromLocalReader != nil, "off but available: worth one line")
        #expect(AppleBrainState.available.nudgeFromLocalReader != nil, "already on: worth one line, since it does more")
        #expect(AppleBrainState.notEligible.nudgeFromLocalReader == nil, "nothing better exists here — saying so would be cruel and useless")
        #expect(AppleBrainState.needsNewerMacOS.nudgeFromLocalReader == nil)
        #expect(AppleBrainState.notReady.nudgeFromLocalReader == nil, "mid-download is not the moment to push someone elsewhere")
    }

    @Test func theSettingsLinkPointsAtAPaneAndNotNowhere() throws {
        let u = try #require(AppleBrainState.settingsURL)
        #expect(u.scheme == "x-apple.systempreferences")
        #expect(u.absoluteString.contains("AppleIntelligence"))
    }
}
