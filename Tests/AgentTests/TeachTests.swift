import Testing
import Foundation
@testable import Agent
import Domain

@Suite struct TeachTests {
    typealias Step = TaughtRecipe.Step
    @Test func testCleanStripsDirectionMarks() {
        #expect(Recorder.clean("\u{200E}WhatsApp\u{200E}") == "WhatsApp")
        #expect(Recorder.clean("  Vivek, You \u{200B}") == "Vivek, You")
    }
    @Test func testPersonComesFromTheSearchBox() {
        let steps = [Step(kind: .launch, app: "WhatsApp", target: "WhatsApp"), Step(kind: .click, app: "WhatsApp", target: "Search", role: "StaticText"),
                     Step(kind: .type, app: "WhatsApp", target: "Search", role: "TextField", text: "vivek you"), Step(kind: .click, app: "WhatsApp", target: "Vivek", role: "Button"),
                     Step(kind: .type, app: "WhatsApp", target: "Compose message", role: "TextField", text: "hi")]
        let p = Recorder.suggestParameters(steps)
        #expect(p.map(\.name) == ["person", "message"])
        #expect(p[0].original == "vivek you"); #expect(p[1].original == "hi")
    }
    @Test func testPersonFallsBackToTheRowAndSkipsChrome() {
        let steps = [Step(kind: .click, app: "Messages", target: "New Chat", role: "Button"), Step(kind: .click, app: "Messages", target: "Amma", role: "Row"), Step(kind: .type, app: "Messages", target: "Message", role: "TextField", text: "on my way")]
        let p = Recorder.suggestParameters(steps)
        #expect(p.first?.original == "Amma")
    }
    @Test func testSearchTextIsNeverTheMessage() {
        let steps = [Step(kind: .type, app: "WhatsApp", target: "Search", role: "TextField", text: "rohan")]
        #expect(Recorder.suggestParameters(steps).first { $0.name == "message" } == nil)
    }
    @Test func testSuggestedName() {
        let p = [TaughtRecipe.Parameter(name: "person", original: "Rohan")]
        #expect(Recorder.suggestName([Step(kind: .launch, app: "WhatsApp", target: "WhatsApp")], parameters: p) == "Message Rohan in WhatsApp")
    }
    @Test func testMethodLadder() {
        let wa = TaughtRecipe(name: "w", steps: [Step(kind: .launch, app: "WhatsApp", target: "WhatsApp"), Step(kind: .type, app: "WhatsApp", target: "Compose message", role: "TextField", text: "hi")], parameters: [], createdAt: Date())
        #expect(wa.method == "WhatsApp link")
        let searchOnly = TaughtRecipe(name: "w", steps: [Step(kind: .launch, app: "WhatsApp", target: "WhatsApp"), Step(kind: .type, app: "WhatsApp", target: "Search", role: "TextField", text: "x")], parameters: [], createdAt: Date())
        #expect(searchOnly.method == "Screen", "a search alone is not a message")
        let mail = TaughtRecipe(name: "m", steps: [Step(kind: .launch, app: "Mail", target: "Mail")], parameters: [], createdAt: Date())
        #expect(mail.method == "AppleScript")
        let two = TaughtRecipe(name: "t", steps: [Step(kind: .launch, app: "Mail", target: "Mail"), Step(kind: .launch, app: "Safari", target: "Safari")], parameters: [], createdAt: Date())
        #expect(two.method == "Screen")
    }
    @Test func testScheduleLine() {
        #expect(TaughtRecipe.Schedule.onDemand.line == "When you ask")
        #expect(TaughtRecipe.Schedule.weekly(weekday: 2, hour: 9, minute: 0).line == "Every Monday, 9:00")
    }
    @Test func testRecipeRoundTripsThroughJSON() throws {
        let r = TaughtRecipe(name: "n", steps: [Step(kind: .key, app: "Mail", target: "cmd+n")], parameters: [.init(name: "message", original: "x", fill: .fromNotes)], schedule: .weekly(weekday: 2, hour: 9, minute: 15), createdAt: Date())
        let back = try JSONDecoder().decode(TaughtRecipe.self, from: JSONEncoder().encode(r))
        #expect(back == r)
    }
}
