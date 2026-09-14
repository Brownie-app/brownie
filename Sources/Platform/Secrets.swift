import Foundation

/// Where a credential comes from, in order: the user's Keychain (their own key or client always
/// wins) → the founder's `.secrets/brownie.env` in Debug builds only → the app's own Info.plist,
/// which `bundle.sh release` fills with the shipped app credentials (Telegram api_id/hash, the
/// Google OAuth desktop client — identifiers of the app, never of a user). Users' keys never go there.
public enum Secrets {
    /// The Info.plist key that holds the shipped app credentials as a dictionary.
    public static let bundledKey = "BrownieCredentials"
    static let bundleable: Set<String> = ["GOOGLE_OAUTH_CLIENT_ID", "GOOGLE_OAUTH_CLIENT_SECRET", "TELEGRAM_API_ID", "TELEGRAM_API_HASH"]

    public static func value(_ key: String) -> String? {
        if let v = Keychain.get(key), !v.isEmpty { return v }
        #if DEBUG
        if let v = env[key], !v.isEmpty { return v }
        #endif
        if bundleable.contains(key), let d = Bundle.main.object(forInfoDictionaryKey: bundledKey) as? [String: String], let v = d[key], !v.isEmpty { return v }
        return nil
    }

    #if DEBUG
    private static let env: [String: String] = {
        var out: [String: String] = [:]
        for candidate in searchPaths {
            guard let text = try? String(contentsOf: candidate, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
                out[String(t[..<eq]).trimmingCharacters(in: .whitespaces)] = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            }
            break
        }
        return out
    }()
    private static var searchPaths: [URL] {
        var urls: [URL] = []
        if let p = ProcessInfo.processInfo.environment["BROWNIE_SECRETS"] { urls.append(URL(fileURLWithPath: p)) }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { dir = dir.deletingLastPathComponent(); urls.append(dir.appendingPathComponent(".secrets/brownie.env")) }
        urls.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/brownie/.secrets/brownie.env"))
        return urls
    }
    #endif
}
