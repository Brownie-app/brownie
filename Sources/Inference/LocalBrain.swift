import Foundation
import Domain
import Support

/// "This Mac only": the reader model doubles as the brain. Plainer cards, nothing sent, ever.
/// No tools, so the pipeline's no-tools paths are used; prompts are cut to the model's window.
public struct LocalBrain: Brain {
    public let descriptor = BrainDescriptor(id: "local", name: "This Mac only", capabilities: [.json], costLine: "Free · nothing leaves")
    private let reader: any LocalModel
    /// Gemma's 16k window less room for the answer, in bytes of prompt.
    public static let inputByteCap = 36_000
    private let log = Log("brain.local")

    public init(reader: any LocalModel) { self.reader = reader }

    public func validate() async throws { if !(await reader.isLoaded) { try await reader.load() } }

    public func complete(_ request: BrainRequest) async throws -> BrainResult {
        if !(await reader.isLoaded) { try await reader.load() }
        var input = request.input
        if input.utf8.count > Self.inputByteCap {
            input = String(decoding: input.utf8.prefix(Self.inputByteCap), as: UTF8.self) + "\n…(older material omitted to fit this Mac's model)"
        }
        var prompt = request.system + "\n\n" + input
        if let schema = request.schema { prompt += "\n\nReply with JSON only, matching this schema exactly:\n" + schema }
        let started = Date()
        let r = try await reader.generate(GenerateRequest(prompt: prompt, maxOutputTokens: min(request.maxOutputTokens, 3000)))
        log.info("local brain: \(prompt.utf8.count) B in, \(r.text.utf8.count) B out, \(String(format: "%.0f", Date().timeIntervalSince(started)))s")
        return BrainResult(text: r.text, usage: Usage(inputTokens: prompt.utf8.count / 4, outputTokens: r.text.utf8.count / 4))
    }
}
