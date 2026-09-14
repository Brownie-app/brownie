import Foundation

// MARK: - Identity

public struct SourceID: Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

public struct BucketID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// How the reader should judge an item. Prompts key off this, never off the app.
public enum SourceKind: String, Codable, Sendable, CaseIterable {
    case document, directMessage, groupChat, mail, event, ticket
}

/// How a source reaches its data.
public enum Door: String, Codable, Sendable {
    case localDatabase, localAPI, userCloud, mcp
}

public enum Permission: String, Codable, Sendable, CaseIterable {
    case fullDiskAccess, accessibility, screenRecording, microphone, speech, contacts, calendar, automation
}

public struct SourceDescriptor: Sendable, Hashable {
    public let id: SourceID
    public let name: String
    public let detail: String
    public let door: Door
    public let permissions: [Permission]
    public let supportsPerBucketOptIn: Bool
    public let isWork: Bool

    public init(id: SourceID, name: String, detail: String, door: Door, permissions: [Permission] = [],
                supportsPerBucketOptIn: Bool = false, isWork: Bool = false) {
        self.id = id; self.name = name; self.detail = detail; self.door = door
        self.permissions = permissions; self.supportsPerBucketOptIn = supportsPerBucketOptIn; self.isWork = isWork
    }
}

public enum Availability: Sendable, Equatable {
    case available
    case notInstalled
    case needsPermission(Permission)
    case needsSignIn
    case unavailable(String)
}

// MARK: - Items

/// Totally-ordered key within a bucket. `order` alone need not be unique (two files added the same
/// second); the tiebreak makes each item a distinct point so a cursor names exactly one boundary.
public struct ItemKey: Hashable, Codable, Sendable, Comparable {
    public let order: Double
    public let tiebreak: String
    public init(order: Double, tiebreak: String = "") { self.order = order; self.tiebreak = tiebreak }
    public init(rowID: Int64) { self.order = Double(rowID); self.tiebreak = "" }
    public static func < (a: ItemKey, b: ItemKey) -> Bool {
        a.order != b.order ? a.order < b.order : a.tiebreak < b.tiebreak
    }
}

/// Enough to load one item. Metadata is display/judgement context only (path, chat name, dates).
public struct Candidate: Sendable, Hashable {
    public let source: SourceID
    public let bucket: BucketID
    public let key: ItemKey
    public let kind: SourceKind
    public let id: String
    public let itemDate: Date?
    public let metadata: [String: String]

    public init(source: SourceID, bucket: BucketID, key: ItemKey, kind: SourceKind, id: String,
                itemDate: Date?, metadata: [String: String] = [:]) {
        self.source = source; self.bucket = bucket; self.key = key; self.kind = kind
        self.id = id; self.itemDate = itemDate; self.metadata = metadata
    }
    public var isGroup: Bool { metadata["isGroup"] == "1" }
}

/// What the reader sees. Raw. Never stored, never sent anywhere but the on-device model.
public struct Artifact: Sendable {
    public let candidate: Candidate
    public let text: String?
    public let imageJPEG: Data?
    public let metadata: [String: String]

    public init(candidate: Candidate, text: String?, imageJPEG: Data? = nil, metadata: [String: String] = [:]) {
        self.candidate = candidate; self.text = text; self.imageJPEG = imageJPEG
        self.metadata = candidate.metadata.merging(metadata) { $1 }
    }
    public var kind: SourceKind { candidate.kind }
    public var isGroup: Bool { metadata["isGroup"] == "1" }
}

public struct Bucket: Sendable {
    public let id: BucketID
    public let name: String
    /// Newest-first. Extra items older than `since` are harmless; the core filters authoritatively.
    public let items: [Candidate]
    public init(id: BucketID, name: String, items: [Candidate]) { self.id = id; self.name = name; self.items = items }
}

// MARK: - The contract

/// A source is dumb: it lists keyed work-items per bucket and loads one. All cursor logic,
/// retries and judgement live in the ingest core, never here.
public protocol Source: Sendable {
    static var descriptor: SourceDescriptor { get }
    func availability() async -> Availability
    /// Independent streams the user can opt into (chats, channels, projects). Empty when the source
    /// has no per-bucket opt-in.
    func discoverBuckets() async throws -> [BucketInfo]
    func buckets(since marks: [BucketID: ItemKey], enabled: Set<BucketID>?) async throws -> [Bucket]
    func load(_ candidate: Candidate) async throws -> Artifact
}

public extension Source {
    var descriptor: SourceDescriptor { Self.descriptor }
    var id: SourceID { Self.descriptor.id }
    func discoverBuckets() async throws -> [BucketInfo] { [] }
}

public struct BucketInfo: Sendable, Hashable, Identifiable {
    public let id: BucketID
    public let name: String
    public let detail: String
    public let isGroup: Bool
    public let count: Int
    public init(id: BucketID, name: String, detail: String, isGroup: Bool, count: Int) {
        self.id = id; self.name = name; self.detail = detail; self.isGroup = isGroup; self.count = count
    }
}

public enum SourceError: Error, Sendable, Equatable {
    case notAvailable(Availability)
    case cannotRead(String)
    case itemGone
}
