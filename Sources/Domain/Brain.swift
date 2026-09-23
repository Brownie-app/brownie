import Foundation

public enum BrainCapability: String, Codable, Sendable, CaseIterable {
    case json, tools, files, webSearch, vision, computerUse
}

public enum Effort: String, Codable, Sendable { case low, medium, high }

public struct BrainDescriptor: Sendable, Equatable {
    public let id: String
    public let name: String
    public let capabilities: Set<BrainCapability>
    public let costLine: String
    public init(id: String, name: String, capabilities: Set<BrainCapability>, costLine: String) {
        self.id = id; self.name = name; self.capabilities = capabilities; self.costLine = costLine
    }
}

public struct BrainRequest: Sendable {
    public let system: String
    public let input: String
    /// JSON schema (as a JSON object string) when a structured reply is required.
    public let schema: String?
    public let effort: Effort
    public let maxOutputTokens: Int
    public let timeout: TimeInterval
    public init(system: String, input: String, schema: String? = nil, effort: Effort = .high,
                maxOutputTokens: Int = 8192, timeout: TimeInterval = 600) {
        self.system = system; self.input = input; self.schema = schema; self.effort = effort
        self.maxOutputTokens = maxOutputTokens; self.timeout = timeout
    }
}

public struct Usage: Sendable, Equatable, Codable {
    public var inputTokens: Int, outputTokens: Int
    public init(inputTokens: Int, outputTokens: Int) { self.inputTokens = inputTokens; self.outputTokens = outputTokens }
    public static let zero = Usage(inputTokens: 0, outputTokens: 0)
    public static func + (a: Usage, b: Usage) -> Usage { Usage(inputTokens: a.inputTokens + b.inputTokens, outputTokens: a.outputTokens + b.outputTokens) }
}

public struct BrainResult: Sendable {
    public let text: String
    public let usage: Usage
    public init(text: String, usage: Usage) { self.text = text; self.usage = usage }
    /// The outermost JSON value in `text`, for fail-closed decoding.
    public var jsonData: Data? {
        guard let s = text.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let e = text.lastIndex(where: { $0 == "}" || $0 == "]" }), s < e else { return nil }
        return String(text[s...e]).data(using: .utf8)
    }
}

/// What a tool hands back: text, optionally an image the brain should look at (a screenshot), and
/// whether the run is over. A "finish" tool sets `endsRun`, so the loop returns after that call with
/// its usage and turn count intact instead of asking the model for another turn or being cancelled.
public struct ToolOutput: Sendable {
    public let text: String
    public let imageJPEG: Data?
    public let endsRun: Bool
    public init(_ text: String, imageJPEG: Data? = nil, endsRun: Bool = false) { self.text = text; self.imageJPEG = imageJPEG; self.endsRun = endsRun }
}

/// A tool the agentic brain may call. Implementations are plain closures owned by the caller.
public struct Tool: Sendable {
    public let name: String
    public let description: String
    public let parametersSchema: String
    public let run: @Sendable (Data) async throws -> ToolOutput
    public init(name: String, description: String, parametersSchema: String, run: @escaping @Sendable (Data) async throws -> ToolOutput) {
        self.name = name; self.description = description; self.parametersSchema = parametersSchema; self.run = run
    }
    /// Text-only convenience: a trailing closure returning a String.
    public init(name: String, description: String, parametersSchema: String, run: @escaping @Sendable (Data) async throws -> String) {
        self.name = name; self.description = description; self.parametersSchema = parametersSchema
        self.run = { ToolOutput(try await run($0)) }
    }
}

public struct AgentTask: Sendable {
    public let system: String
    public let input: String
    public let effort: Effort
    public let maxTurns: Int
    public let timeout: TimeInterval
    public init(system: String, input: String, effort: Effort = .high, maxTurns: Int = 60, timeout: TimeInterval = 1200) {
        self.system = system; self.input = input; self.effort = effort; self.maxTurns = maxTurns; self.timeout = timeout
    }
}

public enum AgentEvent: Sendable {
    case thought(String)
    case toolCall(name: String, summary: String)
    case toolResult(name: String, summary: String)
    case message(String)
}

public struct AgentResult: Sendable {
    public let finalText: String
    public let usage: Usage
    public let turns: Int
    public init(finalText: String, usage: Usage, turns: Int) { self.finalText = finalText; self.usage = usage; self.turns = turns }
}

public enum BrainError: Error, Sendable, Equatable {
    case notConfigured
    case unauthorized
    case usageLimit(retryAfter: TimeInterval?)
    case inputTooLarge(bytes: Int, cap: Int)
    case timeout
    case cancelled
    case provider(code: String, message: String)
    case badResponse(String)
}

public protocol Brain: Sendable {
    var descriptor: BrainDescriptor { get }
    func validate() async throws
    func complete(_ request: BrainRequest) async throws -> BrainResult
}

public protocol AgenticBrain: Brain {
    func run(_ task: AgentTask, tools: [Tool], onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> AgentResult
}

public extension Brain {
    var isAgentic: Bool { self is AgenticBrain }
}

/// Hard cap on any single request body, enforced before the call.
public enum BrainLimits {
    public static let requestByteCap = 950 * 1024
    public static let corpusPartBudget = 700 * 1024
}
