import Foundation
import CommonCrypto

/// The parts of an OAuth sign-in that are the same whoever is on the other end: a PKCE verifier and its
/// challenge, and a one-shot loopback server to catch the redirect.
///
/// These lived on `GoogleAuth` until Gmail was removed, and Slack and Teams had been borrowing them from
/// there — a Microsoft sign-in reaching into a type named after Google. They are nobody's provider now.
enum OAuth {
    static func random(_ n: Int) -> String { String((0..<n).map { _ in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".randomElement()! }) }
    static func base64url(_ d: Data) -> String { d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func sha256(_ d: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: 32)
        d.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(d.count), &hash) }
        return Data(hash)
    }
}

/// One-shot HTTP server on 127.0.0.1 that captures the OAuth redirect.
final class LoopbackServer: @unchecked Sendable {
    enum Error: Swift.Error { case cannotBind }

    let port: UInt16
    private let fd: Int32
    init() throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
        var one: Int32 = 1; setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        guard withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { throw Error.cannotBind }
        var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(sock, $0, &len) } }
        listen(sock, 1)
        fd = sock
        port = UInt16(bigEndian: bound.sin_port)
    }
    func waitForCallback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let c = accept(self.fd, nil, nil)
                defer { close(c); close(self.fd) }
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = read(c, &buf, 4095)
                let req = String(decoding: buf[0..<max(0, n)], as: UTF8.self)
                let line = req.split(separator: "\r\n").first ?? ""
                let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let comps = URLComponents(string: "http://x" + path)
                var out: [String: String] = [:]
                for q in comps?.queryItems ?? [] { out[q.name] = q.value }
                let html = "<html><body style='font-family:-apple-system;padding:40px'><h2>Brownie is connected.</h2><p>You can close this tab.</p></body></html>"
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n" + html
                _ = resp.withCString { write(c, $0, strlen($0)) }
                cont.resume(returning: out)
            }
        }
    }
}
