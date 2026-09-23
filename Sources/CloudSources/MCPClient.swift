import Foundation
import Support

/// Minimal MCP client over Streamable HTTP (JSON-RPC 2.0). Enough for `initialize`,
/// `tools/list`, `tools/call`. Auth is a bearer token the user pastes (or none for local servers).
public actor MCPClient {
    public struct ToolInfo: Sendable, Equatable { public let name: String; public let description: String }
    public enum Error: Swift.Error { case http(Int, String), rpc(String), badResponse }

    private let url: URL
    private let token: String?
    private var sessionID: String?
    private var nextID = 1
    private let log = Log("mcp")

    public init(url: URL, token: String?) { self.url = url; self.token = token }

    public func initialize() async throws {
        let r = try await call("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "Brownie", "version": "0.1"]])
        _ = r
        _ = try? await notify("notifications/initialized")
    }

    public func listTools() async throws -> [ToolInfo] {
        let r = try await call("tools/list", [:])
        return ((r["tools"] as? [[String: Any]]) ?? []).map { ToolInfo(name: $0["name"] as? String ?? "", description: $0["description"] as? String ?? "") }
    }

    /// Returns the text content of the tool result, concatenated.
    public func callTool(_ name: String, _ args: [String: Any]) async throws -> String {
        let r = try await call("tools/call", ["name": name, "arguments": args])
        let content = (r["content"] as? [[String: Any]]) ?? []
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = nextID; nextID += 1
        let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let (obj, _) = try await post(body)
        guard let obj else { throw Error.badResponse }
        if let err = obj["error"] as? [String: Any] { throw Error.rpc(err["message"] as? String ?? "rpc error") }
        return (obj["result"] as? [String: Any]) ?? [:]
    }

    private func notify(_ method: String) async throws {
        _ = try await post(["jsonrpc": "2.0", "method": method])
    }

    private func post(_ body: [String: Any]) async throws -> ([String: Any]?, Int) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let sessionID { req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        if let sid = http?.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = sid }
        let code = http?.statusCode ?? 0
        guard (200...299).contains(code) else { throw Error.http(code, String(decoding: data.prefix(200), as: UTF8.self)) }
        if data.isEmpty { return (nil, code) }
        // Streamable HTTP may answer as SSE: take the last `data:` JSON line.
        if (http?.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream") {
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("data:") }
            for line in lines.reversed() {
                if let d = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces).data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any], obj["id"] != nil { return (obj, code) }
            }
            return (nil, code)
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any], code)
    }
}
