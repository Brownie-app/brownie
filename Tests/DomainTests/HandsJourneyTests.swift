import Testing
import Foundation
@testable import Domain

/// The steps a person watches Hands take.
@Suite struct HandsJourneyTests {
    @Test func aPlanIsTwoToSixDistinctSteps() {
        #expect(HandsJourney.validate(["Open Chrome", "Go to amazon.com"]) == ["Open Chrome", "Go to amazon.com"])
        #expect(HandsJourney.validate(["1. Open Chrome", "2) Go to amazon.com ", "- Search for iPhone"]) == ["Open Chrome", "Go to amazon.com", "Search for iPhone"], "numbering and bullets are stripped")
        #expect(HandsJourney.validate(["Open Chrome"]) == nil)
        #expect(HandsJourney.validate(Array(repeating: "x", count: 7).enumerated().map { "step \($0.offset)" }) == nil)
        #expect(HandsJourney.validate(["Open Chrome", "open chrome", ""]) == nil, "duplicates and blanks don't count")
    }

    @Test func stepsMoveDoingDoneInOrder() {
        var j = HandsJourney()
        #expect(!j.hasPlan && j.progressLine == nil)
        j.add("Looking at the screen")
        #expect(j.loose == ["Looking at the screen"], "before a plan, actions are loose")
        j.setPlan(["Open Chrome", "Go to amazon.com", "Search for iPhone"])
        #expect(j.current?.title == "Open Chrome" && j.progressLine == "Step 1 of 3 · Open Chrome")
        j.add("Opening Google Chrome")
        #expect(j.current?.actions == ["Opening Google Chrome"] && j.lastAction == "Opening Google Chrome")
        j.stepDone(1, note: "Chrome is in front")
        #expect(j.steps[0].state == .done && j.steps[0].note == "Chrome is in front" && j.current?.index == 1 && j.progressLine == "Step 2 of 3 · Go to amazon.com")
        j.stepDone(3, note: "found it")
        #expect(j.steps.map(\.state) == [.done, .done, .done], "closing a later step closes the ones before it")
        #expect(j.current == nil && j.progressLine == "All 3 steps done")
        j.stepDone(9)
        #expect(j.doneCount == 3, "an unknown number is ignored")
    }

    @Test func actionsPerStepAreKeptShort() {
        var j = HandsJourney(); j.setPlan(["a", "b"])
        for i in 0..<10 { j.add("act \(i)") }
        #expect(j.current?.actions.count == HandsJourney.maxActionsPerStep && j.current?.actions.first == "act 4")
    }

    @Test func foldsAFiringsEvents() throws {
        let j = HandsJourney.fold([.step("Hands is starting", done: true), .plan(["Open the chat", "Put the message in", "Stop for you"]), .step("Opening the WhatsApp conversation with Kanika", done: true), .stepDone(1, "chat open"), .step("Putting the message in the box", done: true), .stepDone(2, ""), .pausedForUser("Press Send when ready"), .finished(.pausedAtUserStep)])
        #expect(j.loose == ["Hands is starting"])
        #expect(j.steps.map(\.state) == [.done, .done, .current])
        #expect(j.steps[0].actions == ["Opening the WhatsApp conversation with Kanika"] && j.steps[0].note == "chat open")
        #expect(j.steps[2].actions == ["Press Send when ready"])
        #expect(try JSONDecoder().decode(HandsJourney.self, from: JSONEncoder().encode(j)) == j)
    }
}
