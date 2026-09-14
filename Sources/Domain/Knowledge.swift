import Foundation

public struct Note: Sendable, Identifiable, Equatable {
    public var id: String { relativePath }
    public let relativePath: String
    public let title: String
    public let body: String
    public let sources: [String]
    public let updatedAt: Date
    public let userEdited: Bool
    public init(relativePath: String, title: String, body: String, sources: [String], updatedAt: Date, userEdited: Bool) {
        self.relativePath = relativePath; self.title = title; self.body = body; self.sources = sources
        self.updatedAt = updatedAt; self.userEdited = userEdited
    }
    public var folder: String { relativePath.contains("/") ? String(relativePath.split(separator: "/").first!) : "" }
}

public struct KnowledgeFolder: Sendable, Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let notes: [Note]
    public init(name: String, notes: [Note]) { self.name = name; self.notes = notes }
}

public protocol KnowledgeStore: Sendable {
    var rootURL: URL { get }
    func exists() async -> Bool
    func folders() async throws -> [KnowledgeFolder]
    func note(at relativePath: String) async throws -> Note?
    func save(_ note: Note) async throws
    func delete(relativePath: String) async throws
    func search(_ query: String, limit: Int) async throws -> [Note]
    func fingerprint() async throws -> String
    func noteCount() async throws -> Int
}
