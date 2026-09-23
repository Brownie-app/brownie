import Foundation
import Domain
import Support

/// The welcome letter, written once after the first knowledge base exists.
public struct LetterWriter: Sendable {
    private let brain: any Brain
    private let template: String
    public init(brain: any Brain, bundle: Bundle? = nil) throws {
        let bundle = bundle ?? Bundle.module
        self.brain = brain
        template = try String(contentsOf: bundle.url(forResource: "letter", withExtension: "md", subdirectory: "Prompts") ?? bundle.url(forResource: "letter", withExtension: "md")!, encoding: .utf8)
    }
    public func write(readme: String, numbers: String) async throws -> (String, Usage) {
        let p = template.replacingOccurrences(of: "{{numbers}}", with: numbers).replacingOccurrences(of: "{{readme}}", with: readme)
        let r = try await brain.complete(BrainRequest(system: "You write exactly one letter, nothing else.", input: p, effort: .low, maxOutputTokens: 8000))
        let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BrainError.badResponse("empty letter") }
        return (text, r.usage)
    }
}
