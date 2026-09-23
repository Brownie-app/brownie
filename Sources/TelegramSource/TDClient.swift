import Foundation
import CTDJson
import Support

/// A thin actor over TDLib's JSON interface. One client per app; requests carry an `@extra` id
/// so responses can be awaited; updates are fanned out to a handler.
public actor TDClient {
    public enum Error: Swift.Error { case tdlib(String), timeout, notReady }
    public enum AuthState: Sendable, Equatable { case waitingForParameters, waitingForPhone, waitingForCode, waitingForPassword(hint: String), ready, loggedOut, other(String) }

    private let clientID: Int32
    private var pending: [String: CheckedContinuation<[String: Any], Swift.Error>] = [:]
    private var nextExtra = 1
    public private(set) var authState: AuthState = .waitingForParameters
    private var authObservers: [@Sendable (AuthState) -> Void] = []
    private let log = Log("telegram.td")
    private let apiID: Int32
    private let apiHash: String
    private let databaseDir: URL

    public init(apiID: Int32, apiHash: String, databaseDir: URL) {
        self.apiID = apiID; self.apiHash = apiHash; self.databaseDir = databaseDir
        td_execute("{\"@type\":\"setLogVerbosityLevel\",\"new_verbosity_level\":1}")
        clientID = td_create_client_id()
    }

    private var started = false
    public func start() {
        guard !started else { return }
        started = true
        let id = clientID
        // td_receive blocks; give it its own thread, not a cooperative-pool task.
        let thread = Thread { [weak self] in
            while true {
                guard let raw = td_receive(1.0) else { continue }
                let s = String(cString: raw)
                guard let data = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                guard let self else { return }
                Task { await self.dispatch(obj) }
            }
        }
        thread.name = "tdlib-receive"; thread.qualityOfService = .utility; thread.start()
        log.info("client \(id) receiving on its own thread")
        // TDLib starts delivering updates only after the first request; getOption is a harmless kick.
        "{\"@type\":\"getOption\",\"name\":\"version\"}".withCString { td_send(id, $0) }
    }

    public func onAuth(_ f: @escaping @Sendable (AuthState) -> Void) { authObservers.append(f); f(authState) }

    private func dispatch(_ obj: [String: Any]) {
        let t = obj["@type"] as? String ?? "?"
        if t == "error" { log.warn("error: \(obj["message"] as? String ?? "?")") }
        if let extra = obj["@extra"] as? String, let c = pending.removeValue(forKey: extra) {
            if obj["@type"] as? String == "error" { c.resume(throwing: Error.tdlib(obj["message"] as? String ?? "tdlib error")) } else { c.resume(returning: obj) }
            return
        }
        if obj["@type"] as? String == "updateAuthorizationState", let st = obj["authorization_state"] as? [String: Any] {
            let type = st["@type"] as? String ?? ""
            switch type {
            case "authorizationStateWaitTdlibParameters":
                authState = .waitingForParameters
                Task { await sendParameters() }
            case "authorizationStateWaitEncryptionKey":
                authState = .waitingForParameters
                Task { do { _ = try await send(["@type": "checkDatabaseEncryptionKey", "encryption_key": ""]); log.info("encryption key accepted") } catch { log.warn("encryption key: \(error)") } }
            case "authorizationStateWaitPhoneNumber": authState = .waitingForPhone
            case "authorizationStateWaitCode": authState = .waitingForCode
            case "authorizationStateWaitPassword": authState = .waitingForPassword(hint: st["password_hint"] as? String ?? "")
            case "authorizationStateReady": authState = .ready
            case "authorizationStateLoggingOut", "authorizationStateClosed", "authorizationStateClosing": authState = .loggedOut
            default: authState = .other(type)
            }
            log.info("auth: \(type)")
            for o in authObservers { o(authState) }
        }
    }

    private var parametersSent = false
    private func sendParameters() async {
        guard !parametersSent else { return }
        parametersSent = true
        do {
            // TDLib 1.8.0 (Homebrew) wraps the parameters in a `tdlibParameters` object; newer builds take them flat. Try wrapped first, then flat.
            let params: [String: Any] = ["@type": "tdlibParameters", "database_directory": databaseDir.path, "files_directory": databaseDir.appendingPathComponent("files").path,
                                         "use_file_database": false, "use_chat_info_database": true, "use_message_database": true, "use_secret_chats": false,
                                         "api_id": apiID, "api_hash": apiHash, "system_language_code": "en", "device_model": "Mac", "system_version": "macOS", "application_version": "0.1",
                                         "enable_storage_optimizer": true, "use_test_dc": false]
            var flat = params; flat["@type"] = "setTdlibParameters"
            do { _ = try await send(flat); log.info("parameters accepted (flat)") }
            catch {
                log.info("flat params rejected (\(error)); trying wrapped")
                _ = try await send(["@type": "setTdlibParameters", "parameters": params]); log.info("parameters accepted (wrapped)")
            }

        } catch { parametersSent = false; log.warn("setTdlibParameters failed: \(error)") }
    }

    @discardableResult
    public func send(_ req: [String: Any], timeout: TimeInterval = 30) async throws -> [String: Any] {
        start()
        var r = req
        let extra = "b\(nextExtra)"; nextExtra += 1
        r["@extra"] = extra
        let json = String(decoding: try JSONSerialization.data(withJSONObject: r), as: UTF8.self)
        return try await withCheckedThrowingContinuation { c in
            pending[extra] = c
            json.withCString { td_send(clientID, $0) }   // NUL-terminated, as td_send requires
            Task { try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9)); if let c = self.pending.removeValue(forKey: extra) { c.resume(throwing: Error.timeout) } }
        }
    }

    // MARK: auth steps
    public func setPhone(_ phone: String) async throws {
        start()
        if authState == .waitingForParameters { await sendParameters() }
        try await send(["@type": "setAuthenticationPhoneNumber", "phone_number": phone])
    }
    public func setCode(_ code: String) async throws { try await send(["@type": "checkAuthenticationCode", "code": code]) }
    public func setPassword(_ pw: String) async throws { try await send(["@type": "checkAuthenticationPassword", "password": pw]) }
    public func logOut() async throws { try await send(["@type": "logOut"]) }
}
