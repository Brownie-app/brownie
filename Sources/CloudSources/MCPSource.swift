import Foundation
import Domain
import Platform
import Support

/// A source over any MCP server: a `list` tool that returns recent items and a `get` tool that
/// returns one. The manifest maps the server's tools onto the contract. This is the extension
/// point for Slack, Linear, Notion, Granola, GitHub, Drive — and anything else with an MCP server.
public struct MCPManifest: Codable, Sendable, Equatable, Identifiable {
    public var id: String                 // "linear", "slack", or a user-chosen slug
    public var name: String
    public var url: String
    public var kind: SourceKind
    public var listTool: String           // e.g. "list_issues"
    public var listArgs: [String: String] // e.g. ["updatedSince": "{{since}}"]
    public var getTool: String?           // e.g. "get_issue"; nil ⇒ the list result IS the content
    public var getArgKey: String          // e.g. "id"
    public var idKey: String              // key in each list item holding the id
    public var titleKey: String
    public var dateKey: String            // ISO date key for ordering
    public var isWork: Bool
    public init(id: String, name: String, url: String, kind: SourceKind, listTool: String, listArgs: [String: String] = [:], getTool: String?, getArgKey: String = "id",
                idKey: String = "id", titleKey: String = "title", dateKey: String = "updatedAt", isWork: Bool = true) {
        self.id = id; self.name = name; self.url = url; self.kind = kind; self.listTool = listTool; self.listArgs = listArgs; self.getTool = getTool
        self.getArgKey = getArgKey; self.idKey = idKey; self.titleKey = titleKey; self.dateKey = dateKey; self.isWork = isWork
    }
    public var tokenKey: String { "mcp.\(id).token" }
}

public struct MCPSource: Source {
    public static var descriptor: SourceDescriptor { SourceDescriptor(id: "mcp", name: "MCP", detail: "", door: .mcp, isWork: true) }
    public var descriptor: SourceDescriptor { SourceDescriptor(id: SourceID("mcp:\(manifest.id)"), name: manifest.name, detail: "via MCP · \(manifest.url)", door: .mcp, isWork: true) }
    public var id: SourceID { descriptor.id }

    public let manifest: MCPManifest
    private let log = Log("source.mcp")
    public init(manifest: MCPManifest) { self.manifest = manifest }

    var client: MCPClient { MCPClient(url: URL(string: manifest.url)!, token: Keychain.get(manifest.tokenKey)) }

    public func availability() async -> Availability {
        guard URL(string: manifest.url) != nil else { return .unavailable("Bad server address") }
        do { let c = client; try await c.initialize(); return .available }
        catch MCPClient.Error.http(let code, _) where code == 401 || code == 403 { return .needsSignIn }
        catch { return .unavailable("Couldn't reach the server: \(error)") }
    }

    public func buckets(since marks: [BucketID: ItemKey], enabled: Set<BucketID>?) async throws -> [Bucket] {
        let c = client; try await c.initialize()
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7 * 86400))
        var args: [String: Any] = [:]
        for (k, v) in manifest.listArgs { args[k] = v.replacingOccurrences(of: "{{since}}", with: since) }
        let text = try await c.callTool(manifest.listTool, args)
        let bucket = BucketID("mcp:\(manifest.id)")
        let items = Self.parseList(text).compactMap { item -> Candidate? in
            guard let id = (item[manifest.idKey] as? String) ?? (item[manifest.idKey] as? NSNumber).map({ $0.stringValue }) else { return nil }
            let date = (item[manifest.dateKey] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            let raw = (try? JSONSerialization.data(withJSONObject: item)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return Candidate(source: descriptor.id, bucket: bucket, key: ItemKey(order: date?.timeIntervalSince1970 ?? 0, tiebreak: id), kind: manifest.kind, id: id, itemDate: date,
                             metadata: ["name": item[manifest.titleKey] as? String ?? id, "displayPath": "\(manifest.name)/\(item[manifest.titleKey] as? String ?? id)", "raw": manifest.getTool == nil ? raw : ""])
        }.sorted { $0.key > $1.key }
        return [Bucket(id: bucket, name: manifest.name, items: items)]
    }

    public func load(_ c: Candidate) async throws -> Artifact {
        if let tool = manifest.getTool {
            let cl = client; try await cl.initialize()
            let text = try await cl.callTool(tool, [manifest.getArgKey: c.id])
            return Artifact(candidate: c, text: String(text.prefix(24_000)))
        }
        return Artifact(candidate: c, text: c.metadata["raw"])
    }

    /// Tools return either a JSON array, an object with an array field, or plain text; we take
    /// what we can.
    static func parseList(_ text: String) -> [[String: Any]] {
        guard let data = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let arr = obj as? [[String: Any]] { return arr }
        if let dict = obj as? [String: Any] {
            for v in dict.values { if let arr = v as? [[String: Any]] { return arr } }
        }
        return []
    }
}

/// Presets for the work apps in the design. The user supplies the server URL (their org's MCP
/// endpoint) and a token; the tool names are the common ones and editable.
public enum MCPPresets {
    public static let all: [MCPManifest] = [
        MCPManifest(id: "linear", name: "Linear", url: "https://mcp.linear.app/mcp", kind: .ticket, listTool: "list_issues", listArgs: ["updatedAt": "{{since}}"], getTool: "get_issue", titleKey: "title"),
        MCPManifest(id: "github", name: "GitHub", url: "https://api.githubcopilot.com/mcp/", kind: .ticket, listTool: "search_issues", listArgs: ["q": "assignee:@me updated:>{{since}}"], getTool: "get_issue", idKey: "number", dateKey: "updated_at"),
        MCPManifest(id: "notion", name: "Notion", url: "https://mcp.notion.com/mcp", kind: .document, listTool: "search", listArgs: ["query": ""], getTool: "fetch", dateKey: "last_edited_time"),
        MCPManifest(id: "slack", name: "Slack", url: "", kind: .groupChat, listTool: "conversations_history", getTool: nil, dateKey: "ts"),
        MCPManifest(id: "granola", name: "Granola", url: "", kind: .document, listTool: "list_meetings", getTool: "get_transcript", dateKey: "date"),
    ]
}
