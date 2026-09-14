import Foundation
import AppKit
import Domain
import Support

/// Part 3: the only write-capable step, on a user tap. Channel recipes stop before the
/// irreversible step; `computerUse` is delegated to Hands (injected).
public struct RecipeExecutor: CardExecutor {
    public typealias HandsRunner = @Sendable (String, @escaping @Sendable (FireEvent) -> Void) async throws -> FireOutcome
    private let hands: HandsRunner?
    private let knowledgeRoot: URL
    private let log = Log("executor")

    public init(knowledgeRoot: URL, hands: HandsRunner? = nil) { self.knowledgeRoot = knowledgeRoot; self.hands = hands }

    public func fire(_ card: Card, onEvent: @escaping @Sendable (FireEvent) -> Void) async throws -> FireOutcome {
        log.info("fire \(card.recipe.channelName)")
        switch card.recipe {
        case .imessage(let to, let body, _):
            onEvent(.step("Opening Messages to \(to)", done: false))
            try await Self.appleScript("""
            tell application "Messages"
              activate
            end tell
            """)
            onEvent(.step("Opening Messages to \(to)", done: true))
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(body, forType: .string)
            onEvent(.step("Draft copied to the clipboard — paste it into the chat with \(to)", done: true))
            onEvent(.pausedForUser("Press Send in Messages when you're ready")); return .pausedAtUserStep
        case .whatsapp(let chat, let body, let phone):
            onEvent(.step("Opening the WhatsApp chat with \(chat)", done: false))
            let q = body.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let digits = (phone ?? "").filter(\.isNumber)
            if let url = URL(string: digits.isEmpty ? "whatsapp://send?text=\(q)" : "whatsapp://send?phone=\(digits)&text=\(q)") { NSWorkspace.shared.open(url) }
            onEvent(.step("Opening the WhatsApp chat with \(chat)", done: true))
            onEvent(.step(digits.isEmpty ? "Pick the chat with \(chat); the draft is in the message field" : "The draft is in the message field", done: true))
            onEvent(.pausedForUser("Press Send in WhatsApp when you're ready")); return .pausedAtUserStep
        case .mail(let to, let subject, let body, _):
            onEvent(.step("Composing an email to \(to)", done: false))
            var c = URLComponents(string: "mailto:\(to)")!
            c.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
            if let url = c.url { NSWorkspace.shared.open(url) }
            onEvent(.step("Composing an email to \(to)", done: true))
            onEvent(.pausedForUser("Press Send in Mail when you're ready")); return .pausedAtUserStep
        case .calendar(let title, let startISO, let endISO, let notes):
            onEvent(.step("Opening a new event", done: false))
            try await Self.appleScript("""
            tell application "Calendar"
              activate
              tell calendar 1
                set e to make new event with properties {summary:"\(Self.esc(title))", start date:(current date), description:"\(Self.esc(notes))\n\(startISO) → \(endISO)"}
                show e
              end tell
            end tell
            """)
            onEvent(.step("Event created in Calendar — check the time and Save", done: true))
            onEvent(.pausedForUser("Adjust the time and Save")); return .pausedAtUserStep
        case .note(let rel, let body):
            onEvent(.step("Writing \(rel)", done: false))
            let url = knowledgeRoot.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
            onEvent(.step("Writing \(rel)", done: true)); onEvent(.finished(.done)); return .done
        case .browser(let s):
            onEvent(.step("Opening \(s)", done: false))
            if let url = URL(string: s) { NSWorkspace.shared.open(url) }
            onEvent(.step("Opening \(s)", done: true)); onEvent(.finished(.done)); return .done
        case .computerUse(let goal):
            guard let hands else { onEvent(.finished(.couldNot)); return .couldNot }
            return try await hands(goal, onEvent)
        }
    }

    static func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }

    static func appleScript(_ source: String) async throws {
        try await MainActor.run {
            var err: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&err)
            if let err { throw NSError(domain: "AppleScript", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(err)"]) }
        }
    }
}
