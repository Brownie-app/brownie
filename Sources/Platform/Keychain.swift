import Foundation
import Security

/// Secrets live here and nowhere else. Service is fixed; account is the key name.
public enum Keychain {
    private static let service = "app.brownie"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var quietMode = false
    nonisolated(unsafe) private static var blockedKeys: [String] = []

    /// Whether a read may put a permission prompt on the screen. At 3 AM nobody is there to answer one, and a
    /// modal prompt would hold the whole night — as it once did, for four and a half hours over a Gmail token — so
    /// the overnight run reads quietly: an item this build is not yet allowed to read comes back as missing, the key
    /// is remembered in `blocked`, and the morning says what to click.
    public static var quiet: Bool {
        get { lock.lock(); defer { lock.unlock() }; return quietMode }
        set { lock.lock(); quietMode = newValue; if newValue { blockedKeys = [] }; lock.unlock() }
    }
    /// The keys a quiet read could not have without asking, in the order they were wanted.
    public static var blocked: [String] { lock.lock(); defer { lock.unlock() }; return blockedKeys }

    public static func get(_ key: String) -> String? {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if quiet { q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            lock.lock(); if !blockedKeys.contains(key) { blockedKeys.append(key) }; lock.unlock()
            return nil
        }
        guard status == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public static func set(_ key: String, _ value: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard let value, let d = value.data(using: .utf8) else { return }
        var add = base; add[kSecValueData as String] = d
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    /// After the app moves or is re-signed, an old item asks for permission on every launch. Once the
    /// user has allowed one read, rewriting the item makes this build its owner — no more prompts.
    public static func reown(_ key: String) {
        guard let v = get(key) else { return }
        set(key, v)
    }

    public static func wipeAll() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(q as CFDictionary)
    }
}
