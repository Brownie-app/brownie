import Testing
import Foundation
@testable import Agent
import Domain

/// A recorded step finds its element again by name, by the words around it, or by where it sat.
@Suite struct StepMatchTests {
    let win = el(1, "Window", "Amazon", x: 0, y: 0, w: 1000, h: 800)
    func snap(_ es: [UISnapshot.Element]) -> UISnapshot { UISnapshot(app: "Chrome", window: "Amazon", elements: [win] + es) }
    func step(_ target: String, role: String, fx: Double? = nil, fy: Double? = nil, context: String? = nil) -> TaughtRecipe.Step { .init(kind: .click, app: "Google Chrome", target: target, role: role, fx: fx, fy: fy, context: context) }

    @Test func fractionsOfTheWindow() {
        let f = StepMatch.fraction(CGRect(x: 240, y: 380, width: 20, height: 40), in: CGRect(x: 0, y: 0, width: 1000, height: 800))
        #expect(f! == (0.25, 0.5))
        #expect(StepMatch.fraction(.zero, in: .zero) == nil)
    }

    @Test func aLabelledStepMatchesByNameAndRoleFirst() {
        let s = snap([el(2, "Button", "Add to Cart", x: 700, y: 400), el(3, "StaticText", "Add to Cart", x: 100, y: 100), el(4, "Link", "Apple iPhone 16 Pro", x: 300, y: 300)])
        #expect(StepMatch.candidate(for: step("Add to Cart", role: "Button"), in: s)?.id == 2)
        #expect(StepMatch.candidate(for: step("add to cart", role: "Link"), in: s)?.id == 2, "no Link says it → any element that does")
        #expect(StepMatch.candidate(for: step("iPhone 16", role: "Link"), in: s)?.id == 4, "contained words")
        #expect(StepMatch.candidate(for: step("Checkout", role: "Button"), in: s) == nil)
        #expect(StepMatch.candidate(for: step("Add to Cart", role: "Button"), in: s, tried: [2])?.id == 3, "a tried one is skipped")
    }

    @Test func twoWithTheSameNameAreToldApartByPlace() {
        let s = snap([el(2, "Button", "Buy", x: 100, y: 700), el(3, "Button", "Buy", x: 800, y: 100)])
        #expect(StepMatch.candidate(for: step("Buy", role: "Button", fx: 0.8, fy: 0.13), in: s)?.id == 3)
        #expect(StepMatch.candidate(for: step("Buy", role: "Button", fx: 0.1, fy: 0.9), in: s)?.id == 2)
    }

    @Test func anUnlabelledGroupIsFoundByItsWordsThenItsPlace() {
        let s = snap([el(2, "Group", "", x: 100, y: 100, w: 300, h: 60), el(3, "Group", "Apple iPhone 17 6.3 inch", x: 100, y: 300, w: 300, h: 60), el(4, "Group", "", x: 100, y: 500, w: 300, h: 60)])
        #expect(StepMatch.candidate(for: step("Group", role: "Group", fx: 0.25, fy: 0.66, context: "iPhone 17 6.3 inch"), in: s)?.id == 3, "the words win over the place")
        #expect(StepMatch.candidate(for: step("Group", role: "Group", fx: 0.25, fy: 0.66), in: s)?.id == 4, "no words: the place")
        #expect(StepMatch.candidate(for: step("Group", role: "Group", fx: 0.9, fy: 0.9), in: s) == nil, "nothing near the place")
        #expect(step("Group", role: "Group").isUnlabelled && step("text field", role: "TextField").isUnlabelled && !step("Buy", role: "Button").isUnlabelled)
    }

    @Test func oldRecipesWithoutPlacesStillDecode() throws {
        let old = #"{"kind":"click","app":"WhatsApp","target":"Search","role":"StaticText","text":""}"#
        let s = try JSONDecoder().decode(TaughtRecipe.Step.self, from: Data(old.utf8))
        #expect(s.fx == nil && s.context == nil && s.url == nil && s.target == "Search")
        let new = TaughtRecipe.Step(kind: .click, app: "Google Chrome", target: "Group", role: "Group", fx: 0.2, fy: 0.3, context: "iPhone", url: "https://amazon.com/s?k=iphone")
        #expect(try JSONDecoder().decode(TaughtRecipe.Step.self, from: JSONEncoder().encode(new)) == new)
    }

    @Test func browserRecipesGetSearchAndAName() {
        let steps: [TaughtRecipe.Step] = [.init(kind: .launch, app: "Google Chrome", target: "Google Chrome"),
                                          .init(kind: .type, app: "Google Chrome", target: "Address and search bar", role: "TextField", text: "amazon.com", url: "https://www.amazon.com/"),
                                          .init(kind: .type, app: "Google Chrome", target: "Search Amazon", role: "TextField", text: "iphone", url: "https://www.amazon.com/"),
                                          .init(kind: .click, app: "Google Chrome", target: "Group", role: "Group", context: "iPhone 17", url: "https://www.amazon.com/s?k=iphone")]
        let p = Recorder.suggestParameters(steps)
        #expect(p.map(\.name) == ["search"] && p[0].original == "iphone", "the address bar is not a person; the site's search is a search")
        #expect(Recorder.suggestName(steps, parameters: p) == "Search amazon.com for iphone")
    }
}
