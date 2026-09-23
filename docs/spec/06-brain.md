# 06 · The brain (frontier model abstraction)

Everything cloud-side goes through one protocol pair. No package but `Brain/` knows a provider's
wire format.

```swift
public protocol Brain: Sendable {
    var descriptor: BrainDescriptor { get }          // id, name, capabilities, costLine
    func complete(_ req: BrainRequest) async throws -> BrainResult          // text or JSON (schema)
}
public protocol AgenticBrain: Brain {
    func run(_ task: AgentTask, tools: [Tool], sandbox: Sandbox, onEvent: (AgentEvent) -> Void) async throws -> AgentResult
}
public protocol ComputerUseBrain: Brain {
    func act(_ goal: Goal, policy: ConfirmationPolicy, onEvent: (AgentEvent) -> Void) async throws -> ActOutcome
}
```

`BrainDescriptor.capabilities`: `.json`, `.tools`, `.files` (agentic file editing), `.webSearch`,
`.vision`, `.computerUse`, `.mailConnector`, `.calendarConnector`. Callers check capabilities and
degrade: a brain without `.files` gets the KB built via a single-shot "emit a file map as JSON"
path; a brain without `.tools` skips verification (cards shown `unverified`); no `.computerUse` ⇒
Hands is unavailable and the UI says so.

## Engines (v1)

| Engine | Auth | How | Capabilities | Cost to user |
|---|---|---|---|---|
| **OpenAI (ChatGPT)** — default | API key (Keychain) | Responses API; agentic via tool loop we own; computer use via OpenAI's computer-use tool | all except connectors | per-token on their key |
| **Claude** | API key | Messages API; agentic via tool loop; computer use via Anthropic's computer-use tool | all except connectors | per-token |
| **OpenRouter** | API key | OpenAI-compatible | json, tools, vision (model-dependent) | per-token |
| **Local (LM Studio / any OpenAI-compatible)** | none | OpenAI-compatible at a base URL | json (prompt-folded), maybe tools | ₹0 |
| **None** | — | — | — | KB-only mode |

**Subscription-login engines** (using a ChatGPT Plus or Claude Pro login through the vendor's own CLI
so the user pays nothing extra) are behind the same protocol as a **later addition**. They are not in
v1 because they rely on the vendor's tooling and terms; the design's "uses the plan you already have"
line is honoured by the API-key engines with a cost estimate shown in Settings → Brain.

## Requests
- `BrainRequest {system, input(text | parts), schema?, effort: low|medium|high, maxOutputTokens,
  timeout}`. Effort maps per provider (reasoning effort / thinking budget).
- Byte cap on any single request (~950 KB) enforced *before* the call with a typed error; the
  corpus slicer keeps KB inputs under ~700 KB per part.
- Structured outputs via provider JSON schema where supported; otherwise the schema is folded into
  the prompt and the outermost JSON value is extracted; decoding is always fail-closed.
- Every call is cancellable; cancellation kills the underlying task/process.
- Typed errors: `.notConfigured`, `.unauthorized`, `.usageLimit(retryAfter?)`, `.inputTooLarge`,
  `.timeout`, `.provider(code, message)`. Only a good validation result is cached (per launch); a
  failure is re-probed on every retry so a fixed key is seen immediately.

## The agentic KB builder
Our own loop: the brain gets `read_file / write_file / list_dir / finish` tools scoped to the
staging dir. Turn cap, byte cap, and a "finish must be called" rule. Progress = files written.
Provider-native agent runtimes (OpenAI Agents, Claude Agent SDK) may back this later behind the same
protocol.

## Cost line
Settings → Brain shows an estimate: "Last night: ~N K tokens ≈ ₹X on your key" computed from
returned usage. Never hidden.
