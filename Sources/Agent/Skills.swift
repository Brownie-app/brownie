import Foundation
import AppKit
import Domain
import Support

// MARK: - Pure checks (tested)

public enum BrowserSkill {
    public static let browsers: Set<String> = ["google chrome", "safari", "arc", "firefox", "brave browser", "microsoft edge", "chromium", "vivaldi", "opera"]
    public static func isBrowser(_ app: String) -> Bool { browsers.contains(app.lowercased()) }
    /// "amazon.com" → "https://amazon.com"; a search phrase becomes a Google search.
    public static func normalise(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://") { return t }
        if t.contains(" ") || !t.contains(".") { return "https://www.google.com/search?q=" + (t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t) }
        return "https://" + t
    }
    /// A site's own search page for a query — one URL instead of find-the-box, type, press Return. A site not in
    /// the list becomes a Google search scoped to it.
    public static func searchURL(site: String, query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).addingPercentEncoding(withAllowedCharacters: queryChars) ?? ""
        var s = site.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://", "http://", "www."] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        while s.hasSuffix("/") { s.removeLast() }
        switch s {
        case "amazon", "amazon.com": return "https://www.amazon.com/s?k=\(q)"
        case "amazon.in": return "https://www.amazon.in/s?k=\(q)"
        case "google", "google.com": return "https://www.google.com/search?q=\(q)"
        case "youtube", "youtube.com": return "https://www.youtube.com/results?search_query=\(q)"
        case "flipkart", "flipkart.com": return "https://www.flipkart.com/search?q=\(q)"
        case "wikipedia", "wikipedia.org", "en.wikipedia.org": return "https://en.wikipedia.org/w/index.php?search=\(q)"
        case "github", "github.com": return "https://github.com/search?q=\(q)"
        case "linkedin", "linkedin.com": return "https://www.linkedin.com/search/results/all/?keywords=\(q)"
        case "x", "x.com", "twitter", "twitter.com": return "https://x.com/search?q=\(q)"
        case "reddit", "reddit.com": return "https://www.reddit.com/search/?q=\(q)"
        case "maps", "google maps", "maps.google.com", "google.com/maps": return "https://www.google.com/maps/search/?api=1&query=\(q)"
        default:
            let scoped = ("site:" + s + " " + query.trimmingCharacters(in: .whitespacesAndNewlines)).addingPercentEncoding(withAllowedCharacters: queryChars) ?? ""
            return "https://www.google.com/search?q=\(scoped)"
        }
    }
    /// ASCII letters, digits and the four unreserved marks: everything else, including & + = space and accents, is encoded.
    static let queryChars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// The page is there when the title stops being a blank tab and differs from what it was.
    public static func loaded(title: String, before: String) -> Bool {
        let t = title.lowercased()
        if t.isEmpty || t.hasPrefix("new tab") || t.hasPrefix("untitled") || t.hasPrefix("start page") { return false }
        return t != before.lowercased()
    }
}

public enum ChatWindowCheck {
    /// True when the conversation header (top of the window, right of the list) names this person.
    public static func headerNames(_ snap: UISnapshot, person: String) -> Bool {
        let first = person.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.split(separator: " ").first.map(String.init) ?? person.lowercased()
        guard !first.isEmpty, let win = snap.elements.first(where: { $0.role == "Window" })?.frame, win.width > 0 else { return false }
        return snap.elements.contains { e in
            (e.role == "StaticText" || e.role == "Button" || e.role == "Heading") && e.frame.minY < win.minY + win.height * 0.14 && e.frame.minX > win.minX + win.width * 0.3
                && e.title.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.contains(first)
        }
    }
    static let messageWords = ["message", "compose", "reply", "write", "type a message", "text message"]
    static let textish: Set<String> = ["TextField", "TextArea", "SearchField", "ComboBox"]
    /// The message composer in a chat window: a text box whose label says message/reply/compose, never search.
    public static func composer(in snap: UISnapshot) -> UISnapshot.Element? {
        let fields = snap.elements.filter { textish.contains($0.role) && !$0.title.lowercased().contains("search") && !$0.title.lowercased().contains("find") }
        if let f = fields.first(where: { e in messageWords.contains { e.title.lowercased().contains($0) } }) { return f }
        // WhatsApp's composer is a TextArea near the bottom of the window with no label at all
        if let win = snap.elements.first(where: { $0.role == "Window" })?.frame, win.height > 0 {
            return fields.filter { $0.role == "TextArea" && $0.frame.minY > win.minY + win.height * 0.7 }.max(by: { $0.frame.width < $1.frame.width })
        }
        return nil
    }
}

public enum TypingCheck {
    /// Did the text land? The field's value should contain the start of what was typed.
    public static func landed(expected: String, value: String) -> Bool {
        let want = expected.lowercased().trimmingCharacters(in: .whitespaces)
        guard !want.isEmpty else { return true }
        return value.lowercased().contains(String(want.prefix(12)))
    }
}

// MARK: - The typer both recipes and Hands use

public enum RobustTyper {
    /// Types into a numbered field so that it lands: click to focus, key events, then paste, then the AX value — reading the field back each time.
    public static func type(_ text: String, into id: Int, session: AXSession, log: Log) async -> Bool {
        let landed = { (s: AXSession) -> Bool in TypingCheck.landed(expected: text, value: s.value(of: id)) }
        await MainActor.run { _ = session.focus(id); if let f = session.frame(of: id), f.width > 0 { VirtualInput.click(CGPoint(x: f.midX, y: f.midY)) } }
        try? await Task.sleep(nanoseconds: 300_000_000)
        VirtualInput.key("cmd+a"); usleep(80_000); VirtualInput.type(text)
        try? await Task.sleep(nanoseconds: 400_000_000)
        if await MainActor.run(body: { landed(session) }) { return true }
        await MainActor.run { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
        VirtualInput.key("cmd+a"); usleep(80_000); VirtualInput.key("cmd+v")
        try? await Task.sleep(nanoseconds: 500_000_000)
        if await MainActor.run(body: { landed(session) }) { return true }
        if await MainActor.run(body: { session.setValue(text, on: id) && landed(session) }) { return true }
        let now = await MainActor.run { String(session.value(of: id).prefix(40)) }
        log.warn("typing did not land (value now: “\(now)”)")
        return false
    }
}
