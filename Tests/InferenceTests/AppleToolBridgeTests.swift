import Testing
import Foundation
import Domain
@testable import Inference
#if canImport(FoundationModels)
import FoundationModels
#endif

/// UNIT. Translating Brownie's JSON-Schema tools into the Swift schema Apple's framework constrains against.
///
/// This needs macOS 26 to compile against the framework, but not Apple Intelligence to be *enabled* — building
/// a schema asks nothing of the model. So unlike the E2E suite these run on any macOS 26 machine, including a
/// CI runner, and they are where a tool that grows a shape the bridge cannot read gets caught.
@Suite struct AppleToolBridgeTests {

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    func schema(_ json: String, _ name: String = "t") throws -> GenerationSchema {
        try AppleToolBridge.schema(forToolNamed: name, json: json)
    }

    /// The four shapes Brownie's own tools actually declare, taken verbatim from KnowledgeBuilder.
    @Test(.enabled(if: AppleToolBridgeTests.isMacOS26)) func everyShapeBrowniesOwnToolsUseTranslates() throws {
        guard #available(macOS 26, *) else { return }
        #expect(throws: Never.self) { try schema(#"{"type":"object","properties":{"path":{"type":"string"}},"required":[]}"#, "list_dir") }
        #expect(throws: Never.self) { try schema(#"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#, "read_file") }
        #expect(throws: Never.self) { try schema(#"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"},"sources":{"type":"array","items":{"type":"string"}}},"required":["path","content"]}"#, "write_file") }
        #expect(throws: Never.self) { try schema(#"{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"]}"#, "finish") }
    }

    @Test(.enabled(if: AppleToolBridgeTests.isMacOS26)) func numbersBooleansAndClosedSetsAllTranslate() throws {
        guard #available(macOS 26, *) else { return }
        #expect(throws: Never.self) { try schema(#"{"type":"object","properties":{"n":{"type":"integer"},"x":{"type":"number"},"b":{"type":"boolean"}},"required":["n"]}"#) }
        #expect(throws: Never.self) { try schema(#"{"type":"object","properties":{"urgency":{"type":"string","enum":["high","medium","low"]}},"required":["urgency"]}"#) }
    }

    /// A shape the bridge cannot read must fail where somebody is watching — at construction — rather than
    /// silently losing an argument at three in the morning.
    @Test(.enabled(if: AppleToolBridgeTests.isMacOS26)) func aShapeTheBridgeCannotReadFailsLoudlyAndNamesTheTool() throws {
        guard #available(macOS 26, *) else { return }
        #expect(throws: (any Error).self) { try schema("not json at all", "write_file") }
        #expect(throws: (any Error).self) { try schema(#"{"type":"object","properties":{"when":{"type":"date"}},"required":[]}"#, "write_file") }
        #expect(throws: (any Error).self) { try schema(#"{"type":"object","properties":{"tags":{"type":"array"}},"required":[]}"#, "write_file") }
        do { _ = try schema(#"{"type":"object","properties":{"when":{"type":"date"}}}"#, "write_file") }
        catch { #expect("\(error)".contains("write_file"), "the message must say which tool: \(error)") }
    }

    /// The bridged tool runs Brownie's own closure and hands back its text, so a tool behaves the same
    /// whichever brain is driving it.
    @Test(.enabled(if: AppleToolBridgeTests.isMacOS26)) func aBridgedToolRunsBrowniesOwnClosure() async throws {
        guard #available(macOS 26, *) else { return }
        let seen = Box()
        let tool = Domain.Tool(name: "write_file", description: "d",
                               parametersSchema: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#) { data in
            seen.set(String(decoding: data, as: UTF8.self)); return "written"
        }
        let bridged = try BridgedTool(tool, finished: {})
        let out = try await bridged.call(arguments: GeneratedContent(json: #"{"path":"People/Amma.md"}"#))
        #expect(out == "written")
        #expect(seen.value?.contains("People/Amma.md") == true, "the arguments reached the closure as JSON: \(seen.value ?? "nil")")
    }

    /// A tool that ends the run says so, and the loop is told. Without this a small model that calls `finish`
    /// would be asked to carry on until the turn cap, which is minutes of a night spent on nothing.
    @Test(.enabled(if: AppleToolBridgeTests.isMacOS26)) func aToolThatEndsTheRunReportsBack() async throws {
        guard #available(macOS 26, *) else { return }
        let done = AppleBrain.Done()
        #expect(!done.isSet)
        let tool = Domain.Tool(name: "finish", description: "d",
                               parametersSchema: #"{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"]}"#) { _ in
            ToolOutput("done", endsRun: true)
        }
        _ = try await BridgedTool(tool, finished: { done.set() }).call(arguments: GeneratedContent(json: #"{"summary":"all written"}"#))
        #expect(done.isSet)
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock(); private var v: String?
        func set(_ s: String) { lock.withLock { v = s } }
        var value: String? { lock.withLock { v } }
    }
    #endif

    static var isMacOS26: Bool {
        if #available(macOS 26, *) { return true } else { return false }
    }
}
