import Foundation
@testable import CloudSources

/// Answers by URL substring match, in order of registration; records every call.
final class FakeTransport: JSONTransport, @unchecked Sendable {
    struct Route { let match: String; let status: Int; let body: String }
    private var routes: [Route] = []
    private(set) var calls: [URL] = []
    private let lock = NSLock()
    init() {}
    @discardableResult func on(_ match: String, status: Int = 200, _ body: String) -> FakeTransport { routes.append(Route(match: match, status: status, body: body)); return self }
    func request(_ url: URL, method: String, headers: [String: String], body: Data?) async throws -> (Data, Int) {
        lock.lock(); calls.append(url); lock.unlock()
        let u = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        guard let r = routes.filter({ u.contains($0.match) }).max(by: { $0.match.count < $1.match.count }) else { return (Data("{\"error\":\"no route for \(u)\"}".utf8), 404) }
        return (Data(r.body.utf8), r.status)
    }
    func count(_ match: String) -> Int { calls.filter { ($0.absoluteString.removingPercentEncoding ?? "").contains(match) }.count }
}

func json(_ s: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) ?? [:] }
