import Foundation

public struct GenerateRequest: Sendable {
    public let prompt: String
    public let imageJPEG: Data?
    public let maxOutputTokens: Int
    public init(prompt: String, imageJPEG: Data? = nil, maxOutputTokens: Int = 1024) {
        self.prompt = prompt; self.imageJPEG = imageJPEG; self.maxOutputTokens = maxOutputTokens
    }
}

public struct GenerateResult: Sendable {
    public let text: String
    public let duration: TimeInterval
    public let prefillTokens: Int?
    public let decodeTokens: Int?
    public init(text: String, duration: TimeInterval, prefillTokens: Int? = nil, decodeTokens: Int? = nil) {
        self.text = text; self.duration = duration; self.prefillTokens = prefillTokens; self.decodeTokens = decodeTokens
    }
}

/// The on-device model. Stateless per call; one engine per run. The pipeline decides *when* to
/// reload; the implementation decides *how*.
public protocol LocalModel: Sendable {
    var isLoaded: Bool { get async }
    func load() async throws
    func generate(_ request: GenerateRequest) async throws -> GenerateResult
    func reload() async throws
    func unload() async
}

public enum LocalModelError: Error, Sendable, Equatable {
    case modelNotFound(String)
    case notLoaded
    case engine(String)
    case cancelled
}

public struct LocalModelInfo: Sendable, Equatable {
    public let name: String
    public let fileName: String
    public let downloadURL: URL
    public let approximateBytes: Int64
    public let minimumMemoryGB: Int
    public init(name: String, fileName: String, downloadURL: URL, approximateBytes: Int64, minimumMemoryGB: Int) {
        self.name = name; self.fileName = fileName; self.downloadURL = downloadURL
        self.approximateBytes = approximateBytes; self.minimumMemoryGB = minimumMemoryGB
    }
}
