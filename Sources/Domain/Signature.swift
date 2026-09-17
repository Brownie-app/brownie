import Foundation

/// The optional sign-off under what Brownie drafts: a rule, then "Sent via Brownie · https://usebrownie.com".
/// The address is written out because a chat or a mail composer only makes a link of a URL it can see;
/// there is no way to hide one under a word in plain text. Off by default; the user turns it on in
/// Settings. Never added twice, never to something that isn't a message.
public enum Signature {
    public static let site = "usebrownie.com"
    public static let link = "https://\(site)"
    public static let line = "---\nSent via Brownie · \(link)"
    /// The sign-off on one line, for Settings copy.
    public static let shown = "Sent via Brownie · \(link)"

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
