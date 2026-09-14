import Foundation
import Domain
import Support

/// OpenAI, OpenRouter, LM Studio, or any Chat-Completions-compatible endpoint. Our own tool loop.
public struct OpenAICompatibleBrain: AgenticBrain {
    public enum Flavour: String, Sendable { case openai, openrouter, custom }

    public let descriptor: BrainDescriptor
    let baseURL: URL
    let apiKey: String
    let model: String
    let flavour: Flavour
    private let log = Log("brain.openai")

    public init(flavour: Flavour, baseURL: URL, apiKey: String, model: String) {
        self.flavour = flavour; self.baseURL = baseURL; self.apiKey = apiKey; self.model = model
        let caps: Set<BrainCapability> = flavour == .custom ? [.json, .tools] : [.json, .tools, .files, .vision, .computerUse]
        let name = flavour == .openai ? "ChatGPT / OpenAI" : (flavour == .openrouter ? "OpenRouter" : "Custom (\(baseURL.host ?? "local"))")
        descriptor = BrainDescriptor(id: flavour.rawValue, name: name, capabilities: caps,
                                     costLine: flavour == .custom ? "₹0 · runs on this Mac" : "Billed per token on your own key")
    }

    var headers: [String: String] {
        var h = ["Authorization": "Bearer \(apiKey.isEmpty ? "none" : apiKey)"]
        if flavour == .openrouter { h["HTTP-Referer"] = "https://brownie.app"; h["X-Title"] = "Brownie" }
        return h
    }
    var http: HTTP { HTTP(log: log, timeout: 600) }

    public func validate() async throws {
        if flavour != .custom, apiKey.isEmpty { throw BrainError.notConfigured }
        let r = try await http.postJSON(baseURL.appendingPathComponent("chat/completions"), headers: headers,
                                        body: ["model": model, "messages": [["role": "user", "content": "Reply with exactly: OK"]], "max_completion_tokens": 16])
        guard Self.text(from: r) != nil else { throw BrainError.badResponse("no choices") }
    }

    public func complete(_ req: BrainRequest) async throws -> BrainResult {
        // Reasoning models spend output tokens on thinking before the visible reply; never starve them.
        var body: [String: Any] = ["model": model, "messages": [["role": "system", "content": req.system], ["role": "user", "content": req.input]],
                                   "max_completion_tokens": max(req.maxOutputTokens, flavour == .openai ? 16_000 : req.maxOutputTokens)]
        if flavour == .openai { body["reasoning_effort"] = req.effort.rawValue }
        if let schema = schemaObject(req.schema) {
            if flavour == .custom { body["response_format"] = ["type": "json_object"] }
            else { body["response_format"] = ["type": "json_schema", "json_schema": ["name": "reply", "schema": schema, "strict": false]] }
        }
        let r = try await HTTP(log: log, timeout: req.timeout).postJSON(baseURL.appendingPathComponent("chat/completions"), headers: headers, body: body)
        guard let text = Self.text(from: r) else { throw BrainError.badResponse("empty reply") }
        return BrainResult(text: text, usage: Self.usage(from: r))
    }

    public func run(_ task: AgentTask, tools: [Tool], onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> AgentResult {
        if flavour == .openai { return try await runResponses(task, tools: tools, onEvent: onEvent) }
        return try await runChat(task, tools: tools, onEvent: onEvent)
    }

    /// OpenAI's Responses API: tools + reasoning together, on every current model.
    private func runResponses(_ task: AgentTask, tools: [Tool], onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> AgentResult {
        var input: [[String: Any]] = [["role": "user", "content": task.input]]
        let toolDefs: [[String: Any]] = tools.map { ["type": "function", "name": $0.name, "description": $0.description, "parameters": $0.schemaObject] }
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        var usage = Usage.zero
        var previousID: String?
        let deadline = Date().addingTimeInterval(task.timeout)
        for turn in 1...task.maxTurns {
            if Task.isCancelled { throw BrainError.cancelled }
            if Date() > deadline { throw BrainError.timeout }
            var body: [String: Any] = ["model": model, "instructions": task.system, "input": input, "tools": toolDefs, "max_output_tokens": 16_000,
                                       "reasoning": ["effort": task.effort.rawValue], "store": true]
            if let previousID { body["previous_response_id"] = previousID }
            let r = try await http.postJSON(baseURL.appendingPathComponent("responses"), headers: headers, body: body)
            let u = r["usage"] as? [String: Any]
            usage = usage + Usage(inputTokens: u?["input_tokens"] as? Int ?? 0, outputTokens: u?["output_tokens"] as? Int ?? 0)
            previousID = r["id"] as? String
            let items = (r["output"] as? [[String: Any]]) ?? []
            var text = ""
            var calls: [[String: Any]] = []
            for item in items {
                switch item["type"] as? String {
                case "message":
                    for c in (item["content"] as? [[String: Any]]) ?? [] where (c["type"] as? String) == "output_text" { text += (c["text"] as? String) ?? "" }
                case "function_call": calls.append(item)
                default: break
                }
            }
            if !text.isEmpty { onEvent(.message(text)) }
            if calls.isEmpty { return AgentResult(finalText: text, usage: usage, turns: turn) }
            var outputs: [[String: Any]] = []
            for call in calls {
                let name = call["name"] as? String ?? "", callID = call["call_id"] as? String ?? ""
                let args = (call["arguments"] as? String).flatMap { $0.data(using: .utf8) } ?? Data("{}".utf8)
                onEvent(.toolCall(name: name, summary: String(decoding: args.prefix(120), as: UTF8.self)))
                var result = ToolOutput("error: unknown tool \(name)")
                if let tool = byName[name] { do { result = try await tool.run(args) } catch { result = ToolOutput("error: \(error)") } }
                onEvent(.toolResult(name: name, summary: String(result.text.prefix(120))))
                outputs.append(["type": "function_call_output", "call_id": callID, "output": result.text])
                if let img = result.imageJPEG {
                    outputs.append(["role": "user", "content": [["type": "input_text", "text": "Screenshot from \(name):"], ["type": "input_image", "image_url": "data:image/jpeg;base64," + img.base64EncodedString(), "detail": "high"]]])
                }
            }
            input = outputs   // with previous_response_id, only the new items are sent
        }
        throw BrainError.provider(code: "turns", message: "agent exceeded \(task.maxTurns) turns")
    }

    /// Chat Completions loop for OpenRouter / local servers.
    private func runChat(_ task: AgentTask, tools: [Tool], onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> AgentResult {
        var messages: [[String: Any]] = [["role": "system", "content": task.system], ["role": "user", "content": task.input]]
        let toolDefs: [[String: Any]] = tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schemaObject]] }
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        var usage = Usage.zero
        let deadline = Date().addingTimeInterval(task.timeout)
        for turn in 1...task.maxTurns {
            if Task.isCancelled { throw BrainError.cancelled }
            if Date() > deadline { throw BrainError.timeout }
            // OpenAI's chat/completions rejects function tools with reasoning on some models (gpt-5.6-luna);
            // they require an explicit "none". Effort is honoured in `complete()`, where there are no tools.
            let body: [String: Any] = ["model": model, "messages": messages, "tools": toolDefs, "max_completion_tokens": 16_000]
            let r = try await http.postJSON(baseURL.appendingPathComponent("chat/completions"), headers: headers, body: body)
            usage = usage + Self.usage(from: r)
            guard let choice = (r["choices"] as? [[String: Any]])?.first, let msg = choice["message"] as? [String: Any] else { throw BrainError.badResponse("no choices") }
            let calls = msg["tool_calls"] as? [[String: Any]] ?? []
            let content = msg["content"] as? String ?? ""
            if !content.isEmpty { onEvent(.message(content)) }
            if calls.isEmpty { return AgentResult(finalText: content, usage: usage, turns: turn) }
            var assistant: [String: Any] = ["role": "assistant", "tool_calls": calls]
            if !content.isEmpty { assistant["content"] = content }
            messages.append(assistant)
            for call in calls {
                let id = call["id"] as? String ?? UUID().uuidString
                let fn = call["function"] as? [String: Any] ?? [:]
                let name = fn["name"] as? String ?? ""
                let args = (fn["arguments"] as? String).flatMap { $0.data(using: .utf8) } ?? Data("{}".utf8)
                onEvent(.toolCall(name: name, summary: String(decoding: args.prefix(120), as: UTF8.self)))
                var result = ToolOutput("error: unknown tool \(name)")
                if let tool = byName[name] { do { result = try await tool.run(args) } catch { result = ToolOutput("error: \(error)") } }
                onEvent(.toolResult(name: name, summary: String(result.text.prefix(120))))
                messages.append(["role": "tool", "tool_call_id": id, "content": result.text])
                if let img = result.imageJPEG {
                    messages.append(["role": "user", "content": [["type": "text", "text": "Screenshot from \(name):"], ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + img.base64EncodedString(), "detail": "high"]]]])
                }
            }
        }
        throw BrainError.provider(code: "turns", message: "agent exceeded \(task.maxTurns) turns")
    }

    static func text(from r: [String: Any]) -> String? {
        ((r["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
    }
    static func usage(from r: [String: Any]) -> Usage {
        let u = r["usage"] as? [String: Any]
        return Usage(inputTokens: u?["prompt_tokens"] as? Int ?? 0, outputTokens: u?["completion_tokens"] as? Int ?? 0)
    }
}
