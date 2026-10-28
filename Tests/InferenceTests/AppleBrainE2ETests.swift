import Testing
import Foundation
import Domain
@testable import Inference
#if canImport(FoundationModels)
import FoundationModels
#endif

/// E2E. The real Apple on-device model, on the machine the test is running on.
///
/// Everything else about Apple Intelligence is tested without it: `AppleBrainStateTests` covers every state a
/// Mac can be in, `KnowledgeBuilderTests` pins the contract a tool-capable brain has to satisfy, and
/// `RunCoordinatorTests` drives a whole night through a stand-in of the same shape. Those run in CI, on any
/// Mac, deterministically.
///
/// These cannot. They need macOS 26, Apple Intelligence-capable hardware, and the switch turned on — none of
/// which a GitHub runner has — and they talk to a model whose output is not deterministic. So they **skip
/// themselves** rather than fail when the Mac cannot run them. A green CI run therefore proves everything
/// except that Apple's model does what we think, and the only way to learn that is to run these on a Mac that
/// qualifies:
///
///     swift test --filter AppleBrainE2E
///
/// If they are skipping on a Mac you believe is capable, that is itself the finding: read the reason the
/// availability check gives, because it is the same reason a user would be shown.
@Suite struct AppleBrainE2ETests {

    /// Why this Mac can or cannot take part. Printed either way, because "skipped" with no reason is a test
    /// that quietly stops meaning anything.
    static let state = AppleIntelligence.state
    static var canRun: Bool { state.isUsable }

    @Test func thisMacSaysWhyItCanOrCannotLendItsModel() {
        // Always runs. It asserts nothing about Apple's model — only that the question has a sane answer and
        // that the answer is one a person could act on, which is the thing that reaches the UI.
        print("Apple Intelligence on this Mac: \(Self.state) — \(Self.state.line)")
        #if canImport(FoundationModels)
        // The decisive number for everything the knowledge builder asks of this model: prompt and answer
        // share it. Printed because nothing else in the app knows it, and a budget guessed against it is
        // how a night ends in exceededContextWindowSize.
        if #available(macOS 26.4, *), Self.state.isUsable { print("  context window: \(SystemLanguageModel.default.contextSize) tokens") }
        #endif
        #expect(!Self.state.line.isEmpty)
        #expect(Self.state.isUsable == (Self.state == .available))
        if !Self.state.isUsable {
            #expect(Self.state.isFixable || Self.state == .notReady || Self.state == .notEligible || Self.state == .needsNewerMacOS,
                    "an unusable Mac must fall into a case the UI knows how to talk about")
        }
    }

    /// A capability is a promise about `run`, not a boast about the model. The knowledge builder routes on
    /// `.files` and the preparer on `.tools`, and both then call `run` — so declaring either before the tool
    /// loop exists would send real work into a method that throws. This fails the moment the two disagree.
    @Test(.enabled(if: AppleBrainE2ETests.canRun, "needs macOS 26 with Apple Intelligence turned on"))
    func capabilitiesMatchWhatIsImplemented() async throws {
        let brain = try #require(AppleIntelligence.brain())
        let caps = brain.descriptor.capabilities
        if caps.contains(.tools) || caps.contains(.files) {
            let agentic = try #require(brain as? AgenticBrain, "a brain claiming tools must be agentic")
            await #expect(throws: Never.self) {
                _ = try await agentic.run(AgentTask(system: "", input: "say ok", effort: .low, maxTurns: 1), tools: []) { _ in }
            }
        }
    }

    @Test(.enabled(if: AppleBrainE2ETests.canRun, "needs macOS 26 with Apple Intelligence turned on"))
    func aRealModelAnswersAndTheAnswerIsNotEmpty() async throws {
        let brain = try #require(AppleIntelligence.brain())
        let r = try await brain.complete(BrainRequest(system: "You answer in one short sentence.",
                                                      input: "Name one thing a house spirit might do overnight."))
        #expect(!r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        print("Apple model said: \(r.text.prefix(200))")
    }

    @Test(.enabled(if: AppleBrainE2ETests.canRun, "needs macOS 26 with Apple Intelligence turned on"))
    func validateSucceedsWhenTheMacIsReady() throws {
        #expect(throws: Never.self) { try AppleIntelligence.brain().map { _ in } }
    }

    /// THE one that answers the question all of this exists for: can Apple's on-device model be driven
    /// through Brownie's own tool loop and made to write a note? Everything downstream of that — rows
    /// marked merged, the judge being owed something, cards with evidence — already works and is tested
    /// against a stand-in. This is the only link that was unproven.
    @Test(.enabled(if: AppleBrainE2ETests.canRun, "needs macOS 26 with Apple Intelligence turned on"))
    func theRealModelCallsAToolAndWritesSomething() async throws {
        let brain = try #require(AppleIntelligence.brain() as? AgenticBrain)
        let written = Written()
        let tools = [
            Domain.Tool(name: "write_file", description: "Write a note at a relative path with its full prose.",
                        parametersSchema: #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}"#) { data in
                written.add(String(decoding: data, as: UTF8.self)); return "written"
            },
            Domain.Tool(name: "finish", description: "Call when every note is written. Give a one-line summary.",
                        parametersSchema: #"{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"]}"#) { _ in
                ToolOutput("done", endsRun: true)
            },
        ]
        let task = AgentTask(
            system: "You keep a small notebook of what matters in someone's life. Use write_file to write each note, then call finish.",
            input: "Write one note at People/Amma.md saying that Amma asked about the deposit on 9 October and is waiting for an answer. Then call finish.",
            effort: .low, maxTurns: 4)
        let r = try await brain.run(task, tools: tools) { _ in }
        print("Apple tool loop: \(r.turns) turn(s), wrote \(written.all.count) file(s)")
        for w in written.all { print("  → \(w.prefix(180))") }
        #expect(!written.all.isEmpty, "the model never called write_file — the loop reached it but it wrote nothing")
        #expect(written.all.contains { $0.contains("People/Amma.md") }, "it wrote, but not where it was asked to: \(written.all)")
    }

    final class Written: @unchecked Sendable {
        private let lock = NSLock(); private var v: [String] = []
        func add(_ s: String) { lock.withLock { v.append(s) } }
        var all: [String] { lock.withLock { v } }
    }

    /// A Mac that cannot run it must hand back nil rather than a brain that fails on first use — nil is what
    /// puts the night on the notes-only path, and a half-working brain is what loses one.
    @Test(.disabled(if: AppleBrainE2ETests.canRun, "this Mac can run it, so there is nothing to refuse"))
    func aMacThatCannotRunItIsGivenNoBrainAtAll() {
        #expect(AppleIntelligence.brain() == nil)
    }
}
