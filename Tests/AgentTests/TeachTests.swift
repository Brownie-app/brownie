import XCTest
@testable import Agent
import Domain

final class TeachTests: XCTestCase {
    typealias Step = TaughtRecipe.Step
    func testCleanStripsDirectionMarks() {
        XCTAssertEqual(Recorder.clean("\u{200E}WhatsApp\u{200E}"), "WhatsApp")
        XCTAssertEqual(Recorder.clean("  Vivek, You \u{200B}"), "Vivek, You")
    }
    func testPersonComesFromTheSearchBox() {
        let steps = [Step(kind: .launch, app: "WhatsApp", target: "WhatsApp"), Step(kind: .click, app: "WhatsApp", target: "Search", role: "StaticText"),
                     Step(kind: .type, app: "WhatsApp", target: "Search", role: "TextField", text: "vivek you"), Step(kind: .click, app: "WhatsApp", target: "Vivek", role: "Button"),
                     Step(kind: .type, app: "WhatsApp", target: "Compose message", role: "TextField", text: "hi")]
        let p = Recorder.suggestParameters(steps)
        XCTAssertEqual(p.map(\.name), ["person", "message"])
        XCTAssertEqual(p[0].original, "vivek you"); XCTAssertEqual(p[1].original, "hi")
    }
    func testPersonFallsBackToTheRowAndSkipsChrome() {
        let steps = [Step(kind: .click, app: "Messages", target: "New Chat", role: "Button"), Step(kind: .click, app: "Messages", target: "Amma", role: "Row"), Step(kind: .type, app: "Messages", target: "Message", role: "TextField", text: "on my way")]
        let p = Recorder.suggestParameters(steps)
        XCTAssertEqual(p.first?.original, "Amma")
    }
    func testSearchTextIsNeverTheMessage() {
        let steps = [Step(kind: .type, app: "WhatsApp", target: "Search", role: "TextField", text: "rohan")]
        XCTAssertNil(Recorder.suggestParameters(steps).first { $0.name == "message" })
    }
    func testSuggestedName() {
        let p = [TaughtRecipe.Parameter(name: "person", original: "Rohan")]
        XCTAssertEqual(Recorder.suggestName([Step(kind: .launch, app: "WhatsApp", target: "WhatsApp")], parameters: p), "Message Rohan in WhatsApp")
    }
    func testMethodLadder() {
        let wa = TaughtRecipe(name: "w", steps: [Step(kind: .launch, app: "WhatsApp", target: "WhatsApp"), Step(kind: .type, app: "WhatsApp", target: "Compose message", role: "TextField", text: "hi")], parameters: [], createdAt: Date())
        XCTAssertEqual(wa.method, "WhatsApp link")
        let searchOnly = TaughtRecipe(name: "w", steps: [Step(kind: .launch, app: "WhatsApp", target: "WhatsApp"), Step(kind: .type, app: "WhatsApp", target: "Search", role: "TextField", text: "x")], parameters: [], createdAt: Date())
        XCTAssertEqual(searchOnly.method, "Screen", "a search alone is not a message")
        let mail = TaughtRecipe(name: "m", steps: [Step(kind: .launch, app: "Mail", target: "Mail")], parameters: [], createdAt: Date())
        XCTAssertEqual(mail.method, "AppleScript")
        let two = TaughtRecipe(name: "t", steps: [Step(kind: .launch, app: "Mail", target: "Mail"), Step(kind: .launch, app: "Safari", target: "Safari")], parameters: [], createdAt: Date())
        XCTAssertEqual(two.method, "Screen")
    }
    func testScheduleLine() {
        XCTAssertEqual(TaughtRecipe.Schedule.onDemand.line, "When you ask")
        XCTAssertEqual(TaughtRecipe.Schedule.weekly(weekday: 2, hour: 9, minute: 0).line, "Every Monday, 9:00")
    }
    func testRecipeRoundTripsThroughJSON() throws {
        let r = TaughtRecipe(name: "n", steps: [Step(kind: .key, app: "Mail", target: "cmd+n")], parameters: [.init(name: "message", original: "x", fill: .fromNotes)], schedule: .weekly(weekday: 2, hour: 9, minute: 15), createdAt: Date())
        let back = try JSONDecoder().decode(TaughtRecipe.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
    }
}
