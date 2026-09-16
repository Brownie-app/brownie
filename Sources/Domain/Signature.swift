import Foundation

/// The optional sign-off under what Brownie drafts: "— via my personal assistant Brownie · usebrownie.com".
/// Off by default; the user turns it on in Settings. Never added twice, never to something that isn't a message.
public enum Signature {
    public static let site = "usebrownie.com"
    public static let line = "— via my personal assistant Brownie · \(site)"

    public static func apply(_ text: String, enabled: Bool) -> String {
        guard enabled else { return text }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !body.contains(site) else { return text }
        return body + "\n\n" + line
    }
    /// The draft without the sign-off, for editing and for showing the two apart.
    public static func strip(_ text: String) -> String {
        guard let r = text.range(of: "\n\n" + line) ?? text.range(of: line) else { return text }
        return String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func has(_ text: String) -> Bool { text.contains(site) }
}
