import Foundation
import Domain
import Support
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model as a brain: free, no key, no download of ours, and nothing leaves the Mac.
///
/// Why it exists when `LocalBrain` already runs a local model. `LocalBrain` wraps Gemma, which has no tools and
/// no way to constrain what it emits, so the knowledge builder has to ask it for the whole vault as one JSON
/// string and hope — which is how a night ends in `badResponse("no file map")`. This brain has both of the
/// things that were missing: `@Generable` guarantees the shape of what comes back, so a malformed reply is not
/// a failure mode but an impossibility, and `Tool` lets it take the builder's agentic path and write one note
/// at a time, which is a size a small model can finish.
///
/// Everything here is `@available(macOS 26, *)`. The deployment target is macOS 14 and stays there: the type is
/// simply never constructed on an older Mac, and `AppleBrainState` — which has no SDK in it at all — is what the
/// rest of the app reasons about.
public enum AppleIntelligence {
    /// What this Mac can do, asked fresh each time. Cheap, and the answer changes while the app is running —
    /// someone can switch Apple Intelligence on in System Settings and come back, which is the whole point of
    /// offering them a button.
    public static var state: AppleBrainState {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return .needsNewerMacOS }
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
        case .unavailable(.modelNotReady): return .notReady
        case .unavailable(.deviceNotEligible): return .notEligible
        @unknown default: return .notEligible   // a reason we have never heard of is not one we can talk them through
        }
        #else
        return .needsNewerMacOS
        #endif
    }

    /// A brain, or nil when this Mac cannot lend one. Nil is a first-class answer everywhere in the app: it is
    /// what a missing key gives too, and it puts the night on the notes-only path rather than failing it.
    public static func brain() -> (any Brain)? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), state.isUsable else { return nil }
        return AppleBrain()
        #else
        return nil
        #endif
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
struct AppleBrain: AgenticBrain {
    /// A capability is a promise about `run`, not a boast about the model: the knowledge builder takes its
    /// agentic path on `.files` and the preparer takes its own on `.tools`, and both then call `run`.
    /// `capabilitiesMatchWhatIsImplemented` fails the moment this line gets ahead of the loop below.
    ///
    /// `.files` is the one that matters. It is what stops the builder asking this model for a whole vault as
    /// one JSON string — the request that cannot be satisfied at any size — and makes it write one note per
    /// turn instead. Not `.vision` or `.computerUse`: Hands needs a model that can be trusted with a screen.
    let descriptor = BrainDescriptor(id: "apple", name: "Apple Intelligence",
                                     capabilities: [.json, .tools, .files],
                                     costLine: "Free · nothing leaves this Mac")
    private let log = Log("brain.apple")

    /// Small on purpose, and smaller than the Gemma brain's. The window holds the instructions, the tool
    /// results and the answer together, and this model's is modest — but it writes one note per turn rather
    /// than a vault per reply, so the slice it needs is small too.
    var corpusBudget: Int { 6 * 1024 }

    func validate() throws {
        guard AppleIntelligence.state.isUsable else { throw BrainError.notConfigured }
    }

    func complete(_ request: BrainRequest) async throws -> BrainResult {
        let session = LanguageModelSession(instructions: request.system)
        let started = Date()
        do {
            let r = try await session.respond(to: request.input)
            log.info("apple brain: \(request.input.utf8.count) B in, \(r.content.utf8.count) B out, \(String(format: "%.0f", Date().timeIntervalSince(started)))s")
            return BrainResult(text: r.content, usage: Usage(inputTokens: request.input.utf8.count / 4, outputTokens: r.content.utf8.count / 4))
        } catch { throw Self.translate(error) }
    }

    /// The tool loop. Apple's session runs it: the tools are handed over once, and the framework decides when
    /// to call them and feeds the results back itself, so there is no turn-by-turn message history to resend —
    /// which is the thing that would otherwise exhaust a small window after two or three reads.
    ///
    /// A turn cap is still honoured, because a model that keeps calling `read_file` and never writes is a night
    /// that never ends. `finish` is Brownie's own signal; when a tool says the run is over, so is this.
    func run(_ task: AgentTask, tools: [Domain.Tool], onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> AgentResult {
        let done = Done()
        let bridged: [any FoundationModels.Tool] = try tools.map { tool in
            try BridgedTool(tool, finished: { done.set() })
        }
        let session = LanguageModelSession(tools: bridged, instructions: task.system)
        let started = Date()
        var text = "", turns = 0
        var input = task.input
        do {
            while turns < max(1, task.maxTurns) {
                turns += 1
                let r = try await session.respond(to: input)
                text = r.content
                if done.isSet { break }
                // Apple's session returns once it has finished calling tools and produced prose. If Brownie's
                // own `finish` was never called, nudge once rather than assuming — a small model can stop early.
                onEvent(.message("Writing the notes"))
                input = "Carry on. Call finish when every note is written."
            }
            log.info("apple brain: \(turns) turn(s), \(text.utf8.count) B out, \(String(format: "%.0f", Date().timeIntervalSince(started)))s")
            return AgentResult(finalText: text, usage: Usage(inputTokens: task.input.utf8.count / 4, outputTokens: text.utf8.count / 4), turns: turns)
        } catch { throw Self.translate(error) }
    }

    /// Whether a tool has said the run is over. A reference so the bridged tools, which are values handed to
    /// Apple's session, can report back into this call.
    final class Done: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    /// Apple's errors, in the vocabulary the rest of the app already speaks, so one brain's failure reads the
    /// same as another's on the morning screen.
    static func translate(_ error: Error) -> Error {
        guard let g = error as? LanguageModelSession.GenerationError else { return error }
        switch g {
        case .exceededContextWindowSize: return BrainError.badResponse("the request was longer than this Mac's model can hold")
        case .rateLimited, .concurrentRequests: return BrainError.usageLimit(retryAfter: nil)
        case .assetsUnavailable: return BrainError.notConfigured
        case .guardrailViolation, .refusal: return BrainError.badResponse("Apple's model declined to answer this one")
        case .decodingFailure: return BrainError.badResponse("Apple's model returned something unreadable")
        case .unsupportedGuide, .unsupportedLanguageOrLocale: return BrainError.badResponse("Apple's model cannot do this kind of request")
        @unknown default: return error
        }
    }
}
#endif
