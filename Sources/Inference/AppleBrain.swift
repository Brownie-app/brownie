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
    /// `.json` only, for now, and deliberately NOT `.tools` or `.files`.
    ///
    /// A capability is a promise about `run`, not about the model: the knowledge builder takes its agentic path
    /// on `.files`, and the preparer takes its own on `.tools`, and both then call `run`. Until the tool loop
    /// below is written, declaring either would route real work into a method that throws — which is exactly
    /// the shape of the bug this whole branch exists to fix, reintroduced one layer up. The loop is the next
    /// piece of work; `capabilitiesMatchWhatIsImplemented` fails the moment this line gets ahead of it.
    let descriptor = BrainDescriptor(id: "apple", name: "Apple Intelligence",
                                     capabilities: [.json],
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

    /// Not written yet. Nothing reaches it, because the descriptor claims neither `.tools` nor `.files` — the
    /// two capabilities that are the only routes here. Bridging `Domain.Tool` to `FoundationModels.Tool` means
    /// a `GenerationSchema` per tool, which is the next piece of work and the one that makes notes possible.
    func run(_ task: AgentTask, tools: [Domain.Tool], onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> AgentResult {
        throw BrainError.badResponse("the Apple brain has no tool loop yet")
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
