import Foundation
import LiteRTLM
import Domain
import Support

/// The on-device model behind `LocalModel`. One engine per run; stateless per item.
/// Nothing else imports LiteRTLM.
public actor Reader: LocalModel {
    public struct Settings: Sendable {
        public var topK = 64
        public var topP: Float = 0.95
        public var temperature: Float = 0.15
        public var visualTokenBudget: Int32 = 280
        public var contextTokens = 16_384
        public var speculativeDecoding = true
        public var constrainedJSON = false
        public init() {}
    }

    private let modelPath: URL
    private let settings: Settings
    private let log = Log("reader")
    private var engine: Engine?
    private var jsonSchema: String?

    public init(modelPath: URL, settings: Settings = Settings(), jsonSchema: String? = nil) {
        self.modelPath = modelPath; self.settings = settings; self.jsonSchema = jsonSchema
    }

    public var isLoaded: Bool { engine != nil }

    public func load() async throws {
        guard FileManager.default.fileExists(atPath: modelPath.path) else { throw LocalModelError.modelNotFound(modelPath.path) }
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableSpeculativeDecoding = settings.speculativeDecoding
        ExperimentalFlags.visualTokenBudget = settings.visualTokenBudget
        let started = Date()
        do {
            let vision: Backend? = ProcessInfo.processInfo.environment["BROWNIE_VISION"] == "cpu" ? .cpu() : (ProcessInfo.processInfo.environment["BROWNIE_VISION"] == "off" ? nil : .gpu)
            let config = try EngineConfig(modelPath: modelPath.path, backend: .gpu, visionBackend: vision,
                                          maxNumTokens: settings.contextTokens, cacheDir: Paths.modelCache.path)
            let e = Engine(engineConfig: config)
            try await e.initialize()
            engine = e
            log.info("engine loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        } catch {
            throw LocalModelError.engine("\(error)")
        }
    }

    public func generate(_ request: GenerateRequest) async throws -> GenerateResult {
        guard let engine else { throw LocalModelError.notLoaded }
        let started = Date()
        do {
            let sampler = try SamplerConfig(topK: settings.topK, topP: settings.topP, temperature: settings.temperature)
            let config = ConversationConfig(samplerConfig: sampler, enableResponseFormat: settings.constrainedJSON && jsonSchema != nil,
                                            visualTokenBudget: settings.visualTokenBudget)
            let conversation = try await engine.createConversation(with: config)   // fresh per item: no history bleed, flat RAM
            var contents: [Content] = []
            if let img = request.imageJPEG {
                if ProcessInfo.processInfo.environment["BROWNIE_VISION_FILE"] == "1" {
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("brownie-\(UUID().uuidString).jpg")
                    try img.write(to: tmp); defer { try? FileManager.default.removeItem(at: tmp) }
                    contents.append(.imageFile(tmp.path))
                } else { contents.append(.imageData(img)) }
            }
            contents.append(.text(request.prompt))
            let format = (settings.constrainedJSON ? jsonSchema : nil).flatMap { try? ResponseFormat.json(schema: $0) }
            let reply = try await conversation.sendMessage(Message(contents: contents), maxOutputTokens: request.maxOutputTokens, responseFormat: format)
            if Task.isCancelled { throw LocalModelError.cancelled }
            return GenerateResult(text: reply.toString, duration: Date().timeIntervalSince(started))
        } catch let e as LocalModelError { throw e }
        catch { throw LocalModelError.engine("\(error)") }
    }

    /// Full teardown → pause → fresh load. The pause lets the Metal driver reclaim memory; a
    /// too-quick reload behaves "shallow" and the wedge persists.
    public func reload() async throws {
        await unload()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try await load()
    }

    public func unload() async { engine = nil }
}
