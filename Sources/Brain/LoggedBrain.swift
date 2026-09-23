import Foundation
import Domain
import Support

/// Records every request that leaves the Mac: purpose, size, and the exact text. The brain
/// underneath is untouched; this only watches. "What left your Mac" reads what it wrote.
public final class SendLogger: @unchecked Sendable {
    public typealias Sink = @Sendable (_ purpose: String, _ model: String, _ bytes: Int, _ detail: String, _ payload: String) async -> Int64?
    public typealias Result = @Sendable (_ id: Int64, _ cameBack: String) async -> Void
    private let lock = NSLock()
    private var purpose = "Brain request"
    private var detail = ""
    private let sink: Sink
    private let result: Result
    /// Keep the log honest but bounded: the exact text, up to this many bytes per request.
    public static let payloadCap = 200_000

    public init(sink: @escaping Sink, result: @escaping Result) { self.sink = sink; self.result = result }

    /// The pipeline names each stage before it runs so the log reads like a story, not a dump.
    public func setPurpose(_ p: String, detail: String = "") { lock.lock(); purpose = p; self.detail = detail; lock.unlock() }
    var current: (String, String) { lock.lock(); defer { lock.unlock() }; return (purpose, detail) }

    func record(model: String, payload: String) async -> Int64? {
        let (p, d) = current
        let capped = payload.utf8.count > Self.payloadCap ? String(decoding: payload.utf8.prefix(Self.payloadCap), as: UTF8.self) + "\n…(\(payload.utf8.count - Self.payloadCap) more bytes)" : payload
        return await sink(p, model, payload.utf8.count, d, capped)
    }
    func finish(_ id: Int64?, _ cameBack: String) async { if let id { await result(id, cameBack) } }

    /// Wraps a brain so every call is logged. Agentic brains stay agentic.
    public static func wrap(_ brain: any Brain, model: String, logger: SendLogger) -> any Brain {
        if let a = brain as? AgenticBrain { return LoggedAgenticBrain(inner: a, model: model, logger: logger) }
        return LoggedBrain(inner: brain, model: model, logger: logger)
    }
}

struct LoggedBrain: Brain {
    let inner: any Brain
    let model: String
    let logger: SendLogger
    var descriptor: BrainDescriptor { inner.descriptor }
    func validate() async throws { try await inner.validate() }
    func complete(_ request: BrainRequest) async throws -> BrainResult {
        let id = await logger.record(model: model, payload: "SYSTEM:\n\(request.system)\n\nINPUT:\n\(request.input)")
        do {
            let r = try await inner.complete(request)
            await logger.finish(id, "\(r.text.utf8.count.formattedBytes) back · \(r.usage.outputTokens) tokens")
            return r
        } catch { await logger.finish(id, "failed: \(error)"); throw error }
    }
}

struct LoggedAgenticBrain: AgenticBrain {
    let inner: any AgenticBrain
    let model: String
    let logger: SendLogger
    var descriptor: BrainDescriptor { inner.descriptor }
    func validate() async throws { try await inner.validate() }
    func complete(_ request: BrainRequest) async throws -> BrainResult {
        try await LoggedBrain(inner: inner, model: model, logger: logger).complete(request)
    }
    /// Tool results are sent to the brain on the next turn, so they are part of what left — appended as they happen.
    func run(_ task: AgentTask, tools: [Tool], onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> AgentResult {
        let box = PayloadBox(initial: "SYSTEM:\n\(task.system)\n\nINPUT:\n\(task.input)")
        let wrapped = tools.map { t in
            Tool(name: t.name, description: t.description, parametersSchema: t.parametersSchema) { (data: Data) async throws -> ToolOutput in
                let out = try await t.run(data)
                await box.append("\n\nTOOL \(t.name)(\(String(decoding: data.prefix(400), as: UTF8.self))) →\n\(out.text)\(out.imageJPEG.map { "\n[screenshot, \($0.count.formattedBytes)]" } ?? "")")
                return out
            }
        }
        do {
            let r = try await inner.run(task, tools: wrapped, onEvent: onEvent)
            let id = await logger.record(model: model, payload: await box.text)
            await logger.finish(id, "\(r.turns) turns · \(r.usage.outputTokens) tokens back")
            return r
        } catch {
            let id = await logger.record(model: model, payload: await box.text)
            await logger.finish(id, "failed: \(error)"); throw error
        }
    }
}

actor PayloadBox {
    private(set) var text: String
    init(initial: String) { text = initial }
    func append(_ s: String) { if text.utf8.count < SendLogger.payloadCap { text += s } }
}

public extension Int {
    var formattedBytes: String {
        if self < 1024 { return "\(self) B" }
        if self < 1024 * 1024 { return String(format: "%.1f KB", Double(self) / 1024) }
        return String(format: "%.1f MB", Double(self) / 1024 / 1024)
    }
}
