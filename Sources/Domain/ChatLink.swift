import Foundation

/// "Open the chat" from a person's note: which of the registry's handles ("whatsapp:+91…", "imessage:x@icloud.com",
/// "slack:U123") to use and the link that opens that chat. WhatsApp and iMessage come first because their address
/// opens the chat itself; Slack, Teams and Telegram only open the app. A handle with no address (or one whose app
/// takes none) yields no link, and the caller falls back to looking the name up in Contacts.
public enum ChatLink {
    public struct Pick: Equatable, Sendable { public let app: String; public let address: String }
    static let order = ["whatsapp", "imessage", "telegram", "slack", "teams"]

    /// The handle to open: the first WhatsApp one, else the first iMessage one, else the first of the rest; nil with no handles.
    public static func pick(_ handles: [String]) -> Pick? {
        let picks = handles.compactMap { h -> Pick? in
            guard let colon = h.firstIndex(of: ":") else { return nil }
            return Pick(app: h[..<colon].lowercased(), address: String(h[h.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
        return picks.min { (order.firstIndex(of: $0.app) ?? order.count) < (order.firstIndex(of: $1.app) ?? order.count) }
    }

    /// The link the chat app opens straight to the person, as the Hands skill builds it: `whatsapp://send?phone=<digits>`
    /// (digits only), `imessage://<digits>` for a number and `imessage://<address>` for an Apple ID. Nil when the address is
    /// missing or the app has no per-person link.
    public static func url(app: String, address: String) -> URL? {
        switch app.lowercased() {
        case "whatsapp":
            let digits = address.filter(\.isNumber)
            return digits.isEmpty ? nil : URL(string: "whatsapp://send?phone=\(digits)")
        case "imessage":
            if address.contains("@") { return URL(string: "imessage://\(address.lowercased())") }
            let digits = address.filter(\.isNumber)
            return digits.isEmpty ? nil : URL(string: "imessage://\(digits)")
        default: return nil
        }
    }
}
