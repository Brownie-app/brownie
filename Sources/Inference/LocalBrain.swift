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
    /// The reader's window is 16,384 tokens for prompt and answer together (`Reader.contextTokens`), so no caller
    /// gets the 32,000 the knowledge builder asks for however large this is. It is a ceiling, not a target.
    public static let outputTokenCap = 3_000
    /// Small on purpose. The 36 KB input cap has to hold the system prompt, the existing-files listing and the
    /// schema as well as the corpus, and a reply about a smaller slice is a reply this model can actually finish.
    public var corpusBudget: Int { 8 * 1024 }
    private let log = Log("brain.local")

    public init(reader: any LocalModel) { self.reader = reader }

    public func validate() async throws { if !(await reader.isLoaded) { try await reader.load() } }

    public func complete(_ request: BrainRequest) async throws -> BrainResult {
        if !(await reader.isLoaded) { try await reader.load() }
        // The cut takes the TAIL, not the head. The corpus arrives oldest-first, so trimming the end dropped the
        // newest material while the appended line claimed the opposite — and the caller then marked every row of
        // the part merged, so what was cut was never fed again. Keeping the newest is the lesser loss, and the
        // sentence now says which end went.
        var input = request.input
        var dropped = 0
        if input.utf8.count > Self.inputByteCap {
            dropped = input.utf8.count - Self.inputByteCap
            input = "(older material left out to fit this Mac's model — \(dropped / 1024) KB of it)\n…\n"
                + String(decoding: input.utf8.suffix(Self.inputByteCap), as: UTF8.self)
        }
        var prompt = request.system + "\n\n" + input
        if let schema = request.schema { prompt += "\n\nReply with JSON only, matching this schema exactly:\n" + schema }
        let cap = min(request.maxOutputTokens, Self.outputTokenCap)
        let started = Date()
        let r = try await reader.generate(GenerateRequest(prompt: prompt, maxOutputTokens: cap))
        // The cap is logged beside the size, because "was it truncated?" used to be an arithmetic guess from a
        // byte count with nothing to compare it against.
        log.info("local brain: \(prompt.utf8.count) B in\(dropped > 0 ? " (\(dropped / 1024) KB cut)" : ""), \(r.text.utf8.count) B out of \(cap) tok asked for \(request.maxOutputTokens), \(String(format: "%.0f", Date().timeIntervalSince(started)))s")
        return BrainResult(text: r.text, usage: Usage(inputTokens: prompt.utf8.count / 4, outputTokens: r.text.utf8.count / 4))
    }
}
