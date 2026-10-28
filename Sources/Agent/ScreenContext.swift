import Foundation
import AppKit

/// What is in front of the user, in a few lines, handed to Hands before it plans.
///
/// Hands has always had a `screen` tool, but it is one the model *chooses* to call — so a goal that points at
/// something rather than naming it had nothing to resolve. Asked "can you handle this" over an open WhatsApp
/// chat, it planned "1. Tell me what you want handled" and asked back, because nothing in its input said
/// WhatsApp was frontmost or who the conversation was with.
///
/// This is the cheap half of the fix: a short header, not the whole tree. The app, the window, what has focus,
/// and the last few lines of readable content — enough to know what "this" means and who it is with. The full
/// tree stays behind the `screen` tool, for when detail is actually needed.
public enum ScreenContext {

    /// Words that point at something rather than naming it. A goal containing one of these cannot be acted on
    /// without knowing what is on screen, so the header is worth its tokens; an explicit goal pays nothing.
    static let deictic = ["this", "that", "it", "these", "those", "him", "her", "them", "the above", "here"]

    /// True when the goal leans on what the user is looking at.
    public static func needsScreen(_ goal: String) -> Bool {
        let words = Set(goal.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        return deictic.contains { d in d.contains(" ") ? goal.lowercased().contains(d) : words.contains(d) }
    }

    /// The header, or nil when nothing is frontmost. `lines` bounds how much content comes along: enough to
    /// see who a conversation is with and what was last said, not so much that it crowds out the task.
    public static func header(_ snap: UISnapshot?, lines: Int = 12) -> String? {
        guard let snap else { return nil }
        var out = "WHAT IS IN FRONT OF THE USER RIGHT NOW — you did not have to ask for this, and it may be what they mean by “this”:\n"
        out += "  app: \(clean(snap.app))\n"
        if !clean(snap.window).isEmpty { out += "  window: \(clean(snap.window))\n" }

        // What has keyboard focus tells you where typing would land — usually the message box in a chat.
        if let focused = snap.elements.first(where: { $0.actions.contains("Focus") || $0.role == "TextArea" || $0.role == "TextField" }) {
            let label = clean(focused.title.isEmpty ? focused.role : focused.title)
            if !label.isEmpty { out += "  the cursor is in: \(label)\n" }
        }

        // The readable content, newest last — in a chat this is the conversation, which is the point.
        let said = snap.elements
            .filter { $0.role == "StaticText" || $0.role == "TextArea" }
            .map { clean($0.value.isEmpty ? $0.title : $0.value) }
            .filter { $0.count > 2 }
            .suffix(lines)
        if !said.isEmpty {
            out += "  on screen:\n"
            for line in said { out += "    \(String(line.prefix(160)))\n" }
        }
        out += "If the request points at something (“this”, “handle it”, “reply to her”), it means what is above. Work out what it is and act on it — do not ask the user to repeat it.\n"
        return out
    }

    /// The accessibility tree is full of bidi marks and padding that make a line look different to the model
    /// than it does to a person.
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{200E}", with: "")
            .replacingOccurrences(of: "\u{200F}", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ").joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
