import Foundation
import Domain
import Support

/// Tiny JSON HTTP helper shared by the engines. Maps HTTP failures to typed `BrainError`s.
struct HTTP {
    let log: Log
    let timeout: TimeInterval

    func postJSON(_ url: URL, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: body)
        if data.count > BrainLimits.requestByteCap { throw BrainError.inputTooLarge(bytes: data.count, cap: BrainLimits.requestByteCap) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = data
        let (out, resp): (Data, URLResponse)
        do { (out, resp) = try await URLSession.shared.data(for: req) }
        catch let e as URLError where e.code == .timedOut { throw BrainError.timeout }
        catch let e as URLError where e.code == .cancelled { throw BrainError.cancelled }
        catch { throw BrainError.provider(code: "network", message: error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw BrainError.badResponse("no http response") }
        let obj = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any]
        switch http.statusCode {
        case 200...299:
            guard let obj else { throw BrainError.badResponse(String(decoding: out.prefix(300), as: UTF8.self)) }
            return obj
        case 401, 403: throw BrainError.unauthorized
        case 429:
            let retry = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
            throw BrainError.usageLimit(retryAfter: retry)
        case 413: throw BrainError.inputTooLarge(bytes: data.count, cap: BrainLimits.requestByteCap)
        default:
            let msg = ((obj?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: out.prefix(300), as: UTF8.self)
            if msg.lowercased().contains("quota") || msg.lowercased().contains("billing") { throw BrainError.usageLimit(retryAfter: nil) }
            throw BrainError.provider(code: String(http.statusCode), message: msg)
        }
    }

    func getJSON(_ url: URL, headers: [String: String]) async throws -> Any {
        var req = URLRequest(url: url, timeoutInterval: 30)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (out, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw BrainError.badResponse("no http response") }
        if http.statusCode == 401 || http.statusCode == 403 { throw BrainError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw BrainError.provider(code: String(http.statusCode), message: String(decoding: out.prefix(300), as: UTF8.self)) }
        return try JSONSerialization.jsonObject(with: out)
    }
}

extension Tool {
    var schemaObject: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(parametersSchema.utf8))) as? [String: Any] ?? ["type": "object", "properties": [:]]
    }
}

func schemaObject(_ s: String?) -> [String: Any]? {
    guard let s else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
}
