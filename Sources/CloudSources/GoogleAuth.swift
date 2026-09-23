import Foundation
import AppKit
import CommonCrypto
import Platform
import Support

/// Google OAuth for a Desktop-app client (loopback redirect, PKCE). Tokens live in Keychain.
/// Needs GOOGLE_OAUTH_CLIENT_ID / _SECRET (founder credentials; see docs/launch-setup.md).
public actor GoogleAuth {
    public static let shared = GoogleAuth()
    private let log = Log("google.auth")
    public static let scopes = ["https://www.googleapis.com/auth/gmail.readonly", "https://www.googleapis.com/auth/calendar.readonly"]

    public static var isConfigured: Bool { (Secrets.value("GOOGLE_OAUTH_CLIENT_ID") ?? "").isEmpty == false }
    public var isSignedIn: Bool { Keychain.get("google.refreshToken") != nil }

    public enum Error: Swift.Error { case notConfigured, cancelled, exchange(String), noRefreshToken }

    /// Opens the browser, waits for the loopback redirect, exchanges the code. One admin-free prompt.
    public func signIn() async throws {
        guard let clientID = Secrets.value("GOOGLE_OAUTH_CLIENT_ID"), let secret = Secrets.value("GOOGLE_OAUTH_CLIENT_SECRET") else { throw Error.notConfigured }
        let verifier = Self.random(64), state = Self.random(16)
        let challenge = Self.base64url(Self.sha256(Data(verifier.utf8)))
        let server = try LoopbackServer()
        let redirect = "http://127.0.0.1:\(server.port)/callback"
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [.init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect), .init(name: "response_type", value: "code"),
                        .init(name: "scope", value: Self.scopes.joined(separator: " ")), .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
                        .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"), .init(name: "state", value: state)]
        await MainActor.run { NSWorkspace.shared.open(c.url!) }
        let params = try await server.waitForCallback()
        guard params["state"] == state, let code = params["code"] else { throw Error.cancelled }
        let body = ["code": code, "client_id": clientID, "client_secret": secret, "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier]
        let tok = try await Self.tokenRequest(body)
        guard let refresh = tok["refresh_token"] as? String else { throw Error.noRefreshToken }
        Keychain.set("google.refreshToken", refresh)
        Keychain.set("google.accessToken", tok["access_token"] as? String)
        Keychain.set("google.accessExpiry", String(Date().timeIntervalSince1970 + ((tok["expires_in"] as? Double) ?? 3000)))
        log.info("signed in")
    }

    public func signOut() { Keychain.set("google.refreshToken", nil); Keychain.set("google.accessToken", nil); Keychain.set("google.accessExpiry", nil) }

    /// A valid access token, refreshed when within a minute of expiry.
    public func accessToken() async throws -> String {
        if let t = Keychain.get("google.accessToken"), let e = Keychain.get("google.accessExpiry").flatMap(Double.init), e - 60 > Date().timeIntervalSince1970 { return t }
        guard let refresh = Keychain.get("google.refreshToken") else { throw Error.noRefreshToken }
        guard let clientID = Secrets.value("GOOGLE_OAUTH_CLIENT_ID"), let secret = Secrets.value("GOOGLE_OAUTH_CLIENT_SECRET") else { throw Error.notConfigured }
        let tok = try await Self.tokenRequest(["refresh_token": refresh, "client_id": clientID, "client_secret": secret, "grant_type": "refresh_token"])
        guard let access = tok["access_token"] as? String else { throw Error.exchange("no access token") }
        Keychain.set("google.accessToken", access)
        Keychain.set("google.accessExpiry", String(Date().timeIntervalSince1970 + ((tok["expires_in"] as? Double) ?? 3000)))
        return access
    }

    static func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"; req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Error.exchange(String(decoding: data.prefix(200), as: UTF8.self)) }
        return obj
    }

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
    let port: UInt16
    private let fd: Int32
    init() throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
        var one: Int32 = 1; setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        guard withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { throw GoogleAuth.Error.exchange("bind") }
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
