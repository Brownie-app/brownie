import Foundation
import Domain
import Platform
import Support

/// The one place engine choice + credentials become a `Brain`. Settings (store) decide the
/// engine; Keychain (or the Debug env file) supplies the key.
public enum BrainEngine: String, CaseIterable, Sendable {
    case openai, anthropic, openrouter, custom, local, none
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
    public static func make(_ c: BrainConfig) -> (any Brain)? {
        let key = c.engine.keyName.flatMap(Secrets.value) ?? ""
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
