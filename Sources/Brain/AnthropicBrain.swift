import Foundation
import Domain
import Support

/// Claude via the Messages API (raw HTTP; there is no official Swift SDK). Adaptive thinking,
/// `output_config.effort`, structured output via `output_config.format`, and our own tool loop.
public struct AnthropicBrain: AgenticBrain {
    public let descriptor = BrainDescriptor(id: "anthropic", name: "Claude", capabilities: [.json, .tools, .files, .vision, .computerUse, .webSearch],
                                            costLine: "Billed per token on your own key")
    let apiKey: String
    let model: String
    private let base = URL(string: "https://api.anthropic.com/v1/messages")!
    private let log = Log("brain.anthropic")

    public init(apiKey: String, model: String = "claude-opus-5") { self.apiKey = apiKey; self.model = model }

    var headers: [String: String] { ["x-api-key": apiKey, "anthropic-version": "2023-06-01"] }
    var http: HTTP { HTTP(log: log, timeout: 600) }

    public func validate() async throws {
        if apiKey.isEmpty { throw BrainError.notConfigured }
        _ = try await http.postJSON(base, headers: headers, body: ["model": model, "max_tokens": 16, "messages": [["role": "user", "content": "Reply with exactly: OK"]]])
    }

    public func complete(_ req: BrainRequest) async throws -> BrainResult {
        var outputConfig: [String: Any] = ["effort": req.effort.rawValue]
        if let schema = schemaObject(req.schema) { outputConfig["format"] = ["type": "json_schema", "schema": schema] }
        let body: [String: Any] = ["model": model, "max_tokens": req.maxOutputTokens, "system": req.system,
                                   "thinking": ["type": "adaptive"], "output_config": outputConfig,
                                   "messages": [["role": "user", "content": req.input]]]
        let r = try await HTTP(log: log, timeout: req.timeout).postJSON(base, headers: headers, body: body)
        if (r["stop_reason"] as? String) == "refusal" { throw BrainError.provider(code: "refusal", message: "the model declined this request") }
        return BrainResult(text: Self.text(from: r), usage: Self.usage(from: r))
    }

    public func run(_ task: AgentTask, tools: [Tool], onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> AgentResult {
        var messages: [[String: Any]] = [["role": "user", "content": task.input]]
        let toolDefs: [[String: Any]] = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schemaObject] }
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        var usage = Usage.zero
        let deadline = Date().addingTimeInterval(task.timeout)
        for turn in 1...task.maxTurns {
            if Task.isCancelled { throw BrainError.cancelled }
            if Date() > deadline { throw BrainError.timeout }
            let body: [String: Any] = ["model": model, "max_tokens": 16_000, "system": task.system, "thinking": ["type": "adaptive"],
                                       "output_config": ["effort": task.effort.rawValue], "tools": toolDefs, "messages": messages]
            let r = try await http.postJSON(base, headers: headers, body: body)
            usage = usage + Self.usage(from: r)
            let content = r["content"] as? [[String: Any]] ?? []
            messages.append(["role": "assistant", "content": content])   // echo thinking blocks back unchanged
            let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !text.isEmpty { onEvent(.message(text)) }
            let uses = content.filter { $0["type"] as? String == "tool_use" }
            if (r["stop_reason"] as? String) != "tool_use" || uses.isEmpty { return AgentResult(finalText: text, usage: usage, turns: turn) }
            var results: [[String: Any]] = []
            for use in uses {
                let id = use["id"] as? String ?? "", name = use["name"] as? String ?? ""
                let input = (try? JSONSerialization.data(withJSONObject: use["input"] ?? [:])) ?? Data("{}".utf8)
                onEvent(.toolCall(name: name, summary: String(decoding: input.prefix(120), as: UTF8.self)))
                var result = ToolOutput("unknown tool \(name)"), isError = false
                if let tool = byName[name] { do { result = try await tool.run(input) } catch { result = ToolOutput("\(error)"); isError = true } } else { isError = true }
                onEvent(.toolResult(name: name, summary: String(result.text.prefix(120))))
                // A tool that ends the run (finish) makes this the last turn: nothing after it in the same
                // turn runs, and the model is not asked again — the result carries the usage so far.
                if result.endsRun { return AgentResult(finalText: text, usage: usage, turns: turn) }
                var content: [[String: Any]] = [["type": "text", "text": result.text]]
                if let img = result.imageJPEG { content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": img.base64EncodedString()]]) }
                var block: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": content]
                if isError { block["is_error"] = true }
                results.append(block)
            }
            messages.append(["role": "user", "content": results])   // all results in ONE user message
        }
        throw BrainError.provider(code: "turns", message: "agent exceeded \(task.maxTurns) turns")
    }

    static func text(from r: [String: Any]) -> String {
        (r["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    static func usage(from r: [String: Any]) -> Usage {
        let u = r["usage"] as? [String: Any]
        return Usage(inputTokens: u?["input_tokens"] as? Int ?? 0, outputTokens: u?["output_tokens"] as? Int ?? 0)
    }
}
