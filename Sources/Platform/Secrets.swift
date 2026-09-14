import Foundation

/// Debug-only convenience: reads `.secrets/brownie.env` from the repo so the founder doesn't retype
/// keys while testing. Release builds never read it; users enter keys in Settings → Keychain.
public enum Secrets {
    public static func value(_ key: String) -> String? {
        if let v = Keychain.get(key), !v.isEmpty { return v }
        #if DEBUG
        return env[key].flatMap { $0.isEmpty ? nil : $0 }
        #else
        return nil
        #endif
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
