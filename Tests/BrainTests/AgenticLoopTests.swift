import Testing
import Foundation
@testable import Brain
import Domain

/// A tool that ends the run (finish) is the loop's last word: the brain returns one normal result with
/// the usage so far, asks the model for nothing more, and the send log records a success, not a cancellation.
@Suite(.serialized) struct AgenticLoopTests {
    /// Serves canned replies, in order, to whatever the brains post through URLSession.shared; records every request body.
    final class Stub: URLProtocol {
        nonisolated(unsafe) static var active = false
        nonisolated(unsafe) static var replies: [[String: Any]] = []
        nonisolated(unsafe) static var requests: [[String: Any]] = []
        static let lock = NSLock()
        static let registered: Void = { URLProtocol.registerClass(Stub.self) }()
        static func arm(_ r: [[String: Any]]) { _ = registered; lock.withLock { active = true; replies = r; requests = [] } }
        static func disarm() { lock.withLock { active = false; replies = []; requests = [] } }
        static var sent: [[String: Any]] { lock.withLock { requests } }

        override class func canInit(with request: URLRequest) -> Bool {
            lock.withLock { active } && (request.url?.host == "api.anthropic.com" || request.url?.host == "stub.test")
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let body = Self.body(of: request)
            let reply: [String: Any] = Self.lock.withLock {
                Self.requests.append((try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
                return Self.replies.isEmpty ? ["error": ["message": "no reply scripted"]] : Self.replies.removeFirst()
            }
            let data = try! JSONSerialization.data(withJSONObject: reply)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
        static func body(of r: URLRequest) -> Data {
            if let b = r.httpBody { return b }
            guard let s = r.httpBodyStream else { return Data() }
            s.open(); defer { s.close() }
            var out = Data(); var buf = [UInt8](repeating: 0, count: 64 * 1024)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; out.append(buf, count: n) }
            return out
        }
    }

    actor Writes { var before = 0, after = 0, finished = false
        func note() { if finished { after += 1 } else { before += 1 } }
        func finish() { finished = true } }

    static func tools(_ w: Writes) -> [Tool] {
        [
            Tool(name: "write_file", description: "w", parametersSchema: #"{"type":"object","properties":{}}"#) { (_: Data) async throws -> String in await w.note(); return "wrote" },
            Tool(name: "finish", description: "f", parametersSchema: #"{"type":"object","properties":{}}"#) { (_: Data) async throws -> ToolOutput in await w.finish(); return ToolOutput("finished", endsRun: true) },
        ]
    }

    static func anthropicTurn(_ uses: [(String, String)], stop: String = "tool_use", inTok: Int, outTok: Int) -> [String: Any] {
        ["content": uses.map { ["type": "tool_use", "id": $0.0, "name": $0.1, "input": [:]] as [String: Any] }, "stop_reason": stop,
         "usage": ["input_tokens": inTok, "output_tokens": outTok]]
    }

    @Test func anthropicReturnsAfterFinishWithItsUsageAndAsksForNoMoreTurns() async throws {
        Stub.arm([
            Self.anthropicTurn([("t1", "write_file"), ("t2", "finish"), ("t3", "write_file")], inTok: 100, outTok: 20),
            Self.anthropicTurn([("t4", "write_file")], inTok: 999, outTok: 999),   // must never be requested
        ])
        defer { Stub.disarm() }
        let w = Writes()
        let r = try await AnthropicBrain(apiKey: "k").run(AgentTask(system: "s", input: "i", maxTurns: 5), tools: Self.tools(w)) { _ in }
        #expect(r.usage == Usage(inputTokens: 100, outputTokens: 20), "the usage so far comes back with the result")
        #expect(r.turns == 1)
        #expect(Stub.sent.count == 1, "no request after the turn that called finish")
        let before = await w.before, after = await w.after
        #expect(before == 1 && after == 0, "a write emitted after finish in the same turn does not run")
    }

    @Test func anthropicKeepsLoopingWhenNoToolEndsTheRun() async throws {
        Stub.arm([
            Self.anthropicTurn([("t1", "write_file")], inTok: 10, outTok: 2),
            ["content": [["type": "text", "text": "done"]], "stop_reason": "end_turn", "usage": ["input_tokens": 30, "output_tokens": 4]],
        ])
        defer { Stub.disarm() }
        let w = Writes()
        let r = try await AnthropicBrain(apiKey: "k").run(AgentTask(system: "s", input: "i", maxTurns: 5), tools: Self.tools(w)) { _ in }
        #expect(r.turns == 2 && r.finalText == "done" && r.usage == Usage(inputTokens: 40, outputTokens: 6))
        #expect(Stub.sent.count == 2)
        let second = Stub.sent[1]["messages"] as? [[String: Any]]
        #expect(second?.count == 3, "the tool result went back to the model")
    }

    @Test func chatCompletionsLoopReturnsAfterFinish() async throws {
        Stub.arm([
            ["choices": [["message": ["content": "", "tool_calls": [["id": "c1", "type": "function", "function": ["name": "finish", "arguments": "{}"]],
                                                                     ["id": "c2", "type": "function", "function": ["name": "write_file", "arguments": "{}"]]]]]],
             "usage": ["prompt_tokens": 5, "completion_tokens": 7]],
            ["choices": [["message": ["content": "again", "tool_calls": [["id": "c3", "type": "function", "function": ["name": "write_file", "arguments": "{}"]]]]]], "usage": ["prompt_tokens": 9, "completion_tokens": 9]],
        ])
        defer { Stub.disarm() }
        let w = Writes()
        let brain = OpenAICompatibleBrain(flavour: .custom, baseURL: URL(string: "https://stub.test/v1")!, apiKey: "", model: "m")
        let r = try await brain.run(AgentTask(system: "s", input: "i", maxTurns: 5), tools: Self.tools(w)) { _ in }
        #expect(r.usage == Usage(inputTokens: 5, outputTokens: 7) && r.turns == 1)
        #expect(Stub.sent.count == 1)
        #expect(await w.after == 0)
    }

    @Test func responsesLoopReturnsAfterFinish() async throws {
        Stub.arm([
            ["id": "r1", "output": [["type": "function_call", "name": "finish", "call_id": "c1", "arguments": "{}"]], "usage": ["input_tokens": 3, "output_tokens": 4]],
            ["id": "r2", "output": [["type": "function_call", "name": "write_file", "call_id": "c2", "arguments": "{}"]], "usage": ["input_tokens": 9, "output_tokens": 9]],
        ])
        defer { Stub.disarm() }
        let w = Writes()
        let brain = OpenAICompatibleBrain(flavour: .openai, baseURL: URL(string: "https://stub.test/v1")!, apiKey: "k", model: "m")
        let r = try await brain.run(AgentTask(system: "s", input: "i", maxTurns: 5), tools: Self.tools(w)) { _ in }
        #expect(r.usage == Usage(inputTokens: 3, outputTokens: 4) && r.turns == 1)
        #expect(Stub.sent.count == 1)
    }

    /// The logged wrapper hands the tools' outputs through untouched (the run-ending flag included), so a part
    /// that ends by finish is recorded as "N turns · tokens back" — never as "failed: cancelled".
    @Test func sendLogRecordsAFinishedPartAsASuccess() async throws {
        struct Loop: AgenticBrain {
            let descriptor = BrainDescriptor(id: "loop", name: "Loop", capabilities: [.tools, .files], costLine: "")
            func validate() async throws {}
            func complete(_ r: BrainRequest) async throws -> BrainResult { BrainResult(text: "", usage: .zero) }
            func run(_ task: AgentTask, tools: [Tool], onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> AgentResult {
                // What a real loop does: run tools until one ends the run, then return with the usage.
                var turns = 0
                for name in ["write_file", "finish", "write_file"] {
                    turns += 1
                    let out = try await tools.first { $0.name == name }!.run(Data("{}".utf8))
                    if out.endsRun { return AgentResult(finalText: out.text, usage: Usage(inputTokens: 50, outputTokens: 12), turns: turns) }
                }
                throw BrainError.badResponse("finish never ended the run")
            }
        }
        let sink = SendLoggerTests.Sink()
        let logger = SendLogger(sink: { p, m, b, d, pl in await sink.add(p, m, b, d, pl) }, result: { id, back in await sink.done(id, back) })
        let brain = try #require(SendLogger.wrap(Loop(), model: "m", logger: logger) as? AgenticBrain)
        logger.setPurpose("Update your notes")
        let w = Writes()
        let r = try await brain.run(AgentTask(system: "s", input: "i"), tools: Self.tools(w)) { _ in }
        #expect(r.turns == 2 && r.usage == Usage(inputTokens: 50, outputTokens: 12))
        let results = await sink.results
        #expect(results.count == 1 && results[0].1 == "2 turns · 12 tokens back", "\(results)")
        #expect(await sink.rows.first?.4.contains("TOOL finish") == true, "the finish call is part of what left")
    }
}
