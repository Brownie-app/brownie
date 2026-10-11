import Foundation
import Domain
import Platform
import Support

/// The one place engine choice + credentials become a `Brain`. Settings (store) decide the
/// engine; Keychain (or the Debug env file) supplies the key.
public enum BrainEngine: String, CaseIterable, Sendable {
    // Order is the order they are offered. The two that cost nothing come first on purpose: a stranger
    // scanning the grid should meet a choice they can make before one that asks them to go and get a key.
    case none, local, openai, anthropic, openrouter, custom
    public var displayName: String {
        switch self {
        case .openai: return "ChatGPT / OpenAI"
        case .anthropic: return "Claude"
        case .openrouter: return "OpenRouter"
        case .custom: return "LM Studio / custom"
        case .local: return "This Mac only"
        case .none: return "No brain"
        }
    }
    public var keyName: String? {
        switch self { case .openai: return "OPENAI_API_KEY"; case .anthropic: return "ANTHROPIC_API_KEY"; case .openrouter: return "OPENROUTER_API_KEY"; case .custom: return "CUSTOM_BRAIN_API_KEY"; case .local, .none: return nil }
    }
    /// The line under the name, wherever the engine is offered. It lives here rather than in a view because
    /// onboarding and Settings used to word the same choice differently — and onboarding told the one key-free
    /// option, "This Mac only", that it needed "Your own API key".
    public var caption: String {
        switch self {
        case .local: return "No key, nothing leaves, ever · no notes or cards yet — same as No brain"
        case .none: return "A note each day of what was read · no cards, no drafts, no Hands"
        case .openai: return "Your OpenAI key · drafts, cards, Hands"
        case .anthropic: return "Your Anthropic key · official computer use"
        case .openrouter: return "Any model, on your key"
        case .custom: return "LM Studio or any local server · simpler cards"
        }
    }
    /// True when this engine cannot do anything without a key the user has not given.
    public var needsKey: Bool { self == .openai || self == .anthropic || self == .openrouter }
    public var defaultModel: String {
        switch self { case .openai: return "gpt-5.6-luna"; case .anthropic: return "claude-opus-5"; case .openrouter: return "anthropic/claude-opus-5"; case .custom: return "local"; case .local: return "gemma-4-e4b"; case .none: return "" }
    }
}

public struct BrainConfig: Sendable, Equatable {
    public var engine: BrainEngine
    public var model: String
    public var customBaseURL: String
    public init(engine: BrainEngine, model: String, customBaseURL: String = "http://127.0.0.1:1234/v1") {
        self.engine = engine; self.model = model; self.customBaseURL = customBaseURL
    }
}

public enum BrainFactory {
    /// `key` is for tests, which must not depend on whatever happens to be in the developer's own env file.
    /// In the app it is always nil and the key comes from the Keychain (or, in Debug, `.secrets/brownie.env`).
    public static func make(_ c: BrainConfig, key override: String? = nil) -> (any Brain)? {
        let key = override ?? c.engine.keyName.flatMap(Secrets.value) ?? ""
        // No key, no brain. Without this the app manufactures a brain that sends "Bearer none", the first run
        // dies on a 401, and the first thing a stranger ever reads is "The brain rejected your key" about a key
        // they never had. Returning nil instead puts them on the no-brain path the app already knows how to walk.
        // `.custom` is exempt: a local server legitimately needs no key, which is what `hasKey` already says.
        guard !(c.engine.needsKey && key.isEmpty) else { return nil }
        switch c.engine {
        case .openai: return OpenAICompatibleBrain(flavour: .openai, baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: key, model: c.model)
        case .openrouter: return OpenAICompatibleBrain(flavour: .openrouter, baseURL: URL(string: "https://openrouter.ai/api/v1")!, apiKey: key, model: c.model)
        case .custom:
            let base = URL(string: c.customBaseURL) ?? URL(string: Secrets.value("CUSTOM_BRAIN_BASE_URL") ?? "http://127.0.0.1:1234/v1")!
            return OpenAICompatibleBrain(flavour: .custom, baseURL: base, apiKey: key, model: c.model.isEmpty ? (Secrets.value("CUSTOM_BRAIN_MODEL") ?? "local") : c.model)
        case .anthropic: return AnthropicBrain(apiKey: key, model: c.model)
        case .local, .none: return nil   // the app builds LocalBrain itself — it needs the reader
        }
    }

    public static func hasKey(_ e: BrainEngine) -> Bool { e.keyName.flatMap(Secrets.value).map { !$0.isEmpty } ?? (e == .custom || e == .local) }
}
