import Foundation

/// Turns a tool call into the line the user sees: `key {"combo":"cmd+l"}` → "Pressing ⌘L".
/// Pure, so the wording is tested; `label` resolves a numbered element to its title when the tree is known.
public enum HandsNarrator {
    public static func line(tool: String, args: String, label: (Int) -> String = { _ in "" }) -> String {
        let a = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any] ?? [:]
        func el(_ key: String = "id") -> String {
            let id = a[key] as? Int ?? Int(a[key] as? String ?? "") ?? 0
            let t = label(id).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "element \(id)" : "“\(t.prefix(40))”"
        }
        switch tool {
        case "plan": return "Planning the steps"
        case "step_done": return "Step \(a["n"] as? Int ?? 0) done"
        case "find": return "Looking for \(quote(a["text"]))"
        case "wait_for": return "Waiting for \(quote(a["text"])) to appear"
        case "open_url": return "Going to \((a["url"] as? String ?? "the page").replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""))"
        case "open_chat": return "Opening the \(a["app"] as? String ?? "chat") conversation with \(a["name"] as? String ?? "them")"
        case "type_message": return "Putting the message in the box: \(quote(a["text"]))"
        case "screen": return "Looking at the screen"
        case "look": return "Taking a screenshot to see the page"
        case "list_apps": return "Checking which apps are open"
        case "open_app": return "Opening \(a["name"] as? String ?? "the app")"
        case "press": return "Pressing \(el())"
        case "set_value": return "Filling \(el()) with \(quote(a["text"]))"
        case "type": return "Typing \(quote(a["text"]))"
        case "key": return "Pressing \(keys(a["combo"] as? String ?? ""))"
        case "click": return "Clicking on the screen"
        case "wait":
            let s = a["seconds"] as? Double ?? (a["seconds"] as? Int).map(Double.init) ?? 1
            return "Waiting \(s == s.rounded() ? String(Int(s)) : String(s)) s for the app to settle"
        case "need_user": return "Stopping — \(a["what"] as? String ?? "the next step is yours")"
        case "done": return "Done — \(a["summary"] as? String ?? "finished")"
        case "could_not": return "Couldn't — \(a["reason"] as? String ?? "gave up")"
        default: return tool.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func quote(_ v: Any?) -> String {
        let s = (v as? String ?? "").replacingOccurrences(of: "\n", with: " ")
        let short = s.count > 48 ? String(s.prefix(45)) + "…" : s
        return "“\(short)”"
    }

    /// "cmd+shift+a" → "⌘⇧A"; "return" → "Return".
    public static func keys(_ combo: String) -> String {
        let names: [String: String] = ["cmd": "⌘", "command": "⌘", "meta": "⌘", "shift": "⇧", "alt": "⌥", "option": "⌥", "opt": "⌥", "ctrl": "⌃", "control": "⌃",
                                       "return": "Return", "enter": "Return", "tab": "Tab", "escape": "Esc", "esc": "Esc", "space": "Space", "delete": "Delete", "backspace": "Delete",
                                       "up": "↑", "down": "↓", "left": "←", "right": "→", "`": "`"]
        let parts = combo.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        var out = ""
        for (i, p) in parts.enumerated() {
            let p = p.isEmpty && i > 0 ? "+" : p   // "cmd++" is ⌘ and the plus key
            if let n = names[p] { out += n; if n.count > 1, i < parts.count - 1 { out += " " } }
            else if p.count == 1 { out += p.uppercased() }
            else { out += (out.isEmpty ? "" : " ") + p.capitalized }
        }
        return out.isEmpty ? "a key" : out
    }
}
