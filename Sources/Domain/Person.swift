import Foundation

/// One person is one identity, everywhere. Every place that asks "is this the same person" — the loops
/// ledger, the asks ledger, card dedupe, the quiet check, the household ledger — compares through here,
/// so "Kanika Pandey Loadmill" and "Kanika Pandey" are one person in all of them at once.
public enum PersonKey {
    /// The comparable core of a chat name: the parenthesised suffix and any phone number go, diacritics
    /// fold, case folds, and the first two alphabetic words remain. "Nitesh (+919540752593)" → "nitesh";
    /// "Kanika Pandey Loadmill" → "kanika pandey"; "Zoë Müller" → "zoe muller". A name with no letters
    /// at all (a bare number) has no key, and an empty key never matches anything.
    public static func normalise(_ label: String) -> String {
        var t = label
        while let open = t.range(of: "(") {
            let close = t[open.upperBound...].range(of: ")")
            t.removeSubrange(open.lowerBound..<(close?.upperBound ?? t.endIndex))
        }
        t = t.replacingOccurrences(of: #"\+\s*[\d\s-]+"#, with: " ", options: .regularExpression)
        t = t.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
        return t.split(whereSeparator: { !$0.isLetter }).prefix(2).joined(separator: " ")
    }

    /// Equal keys, or one side is a single word equal to the other's first word ("Arjun" and "Arjun Mehta").
    /// The forgiving comparison the ledgers use among themselves; it is not enough to pick a person's
    /// note — the registry decides that, because two people can share a first name.
    public static func same(_ a: String, _ b: String) -> Bool {
        let ka = normalise(a), kb = normalise(b)
        guard !ka.isEmpty, !kb.isEmpty else { return false }
        if ka == kb { return true }
        let wa = ka.split(separator: " "), wb = kb.split(separator: " ")
        return (wa.count == 1 && wa[0] == wb[0]) || (wb.count == 1 && wb[0] == wa[0])
    }

    /// Strictly equal keys — the rule for matching a label against a note title, where a first name
    /// alone must never claim someone else's note.
    public static func sameKey(_ a: String, _ b: String) -> Bool {
        let ka = normalise(a)
        return !ka.isEmpty && ka == normalise(b)
    }

    /// The label as a name: the parenthesised suffix and any phone number dropped, spacing tidied.
    /// "Nitesh (+919540752593)" → "Nitesh". Falls back to the label itself when nothing is left.
    public static func displayName(_ label: String) -> String {
        var t = label
        while let open = t.range(of: "(") {
            let close = t[open.upperBound...].range(of: ")")
            t.removeSubrange(open.lowerBound..<(close?.upperBound ?? t.endIndex))
        }
        t = t.replacingOccurrences(of: #"\+\s*[\d\s-]+"#, with: " ", options: .regularExpression)
        let tidy = t.split(separator: " ").joined(separator: " ")
        return tidy.isEmpty ? label.trimmingCharacters(in: .whitespaces) : tidy
    }
}

/// The user's own names — the Mac's full user name, the account name, the household member marked `isMe` — and
/// the one question every ledger and every People rule asks of a label: is this the user? The user is never a
/// person in the vault: no People note, no registry record, no loop with themselves as the other party. A note the
/// brain titled after them ("Vivek Upreti — Career Materials") is about the user, and what is about the user lives
/// in README.md or in a topic note, never under People/.
public enum SelfNames {
    /// The names as they will be compared: trimmed, empty ones dropped, none twice.
    public static func clean(_ names: [String?]) -> [String] {
        var out: [String] = []
        for n in names.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }) where !n.isEmpty && !PersonKey.normalise(n).isEmpty && !out.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) { out.append(n) }
        return out
    }
    /// True when the label is the user under any spelling (`PersonKey.same`, so "Vivek" alone is the user when the
    /// user is Vivek Upreti) or is a title that opens with a self name and a dash ("Vivek Upreti — Career Materials").
    public static func isSelf(_ label: String, among names: [String]) -> Bool {
        guard !names.isEmpty else { return false }
        return names.contains { PersonKey.same(label, $0) || prefixed(label, by: $0) != nil }
    }
    /// The title without the self name and its " — ": "Vivek Upreti — Career Materials (Jul–Aug 2026)" → "Career
    /// Materials (Jul–Aug 2026)". Nil when the title does not open that way, or when nothing would be left.
    public static func stripped(_ title: String, among names: [String]) -> String? {
        for n in names { if let rest = prefixed(title, by: n), !rest.isEmpty { return rest } }
        return nil
    }
    /// What follows "<name> — " (or "<name> - ") at the start of the title, case aside; nil when the title does not open so.
    static func prefixed(_ title: String, by name: String) -> String? {
        let t = title.trimmingCharacters(in: .whitespaces), lower = t.lowercased(), n = name.lowercased()
        for dash in [" — ", " – ", " - "] where lower.hasPrefix(n + dash) {
            return String(t.dropFirst(n.count + dash.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

/// A stable handle for a person as a source knows them — a phone, a user id, a chat id — spelled one way
/// so the registry can recognise someone whose chat name changed.
public enum PersonHandle {
    /// "whatsapp:+919540752593" — digits only, any spacing or punctuation dropped.
    public static func whatsapp(phoneDigits: String) -> String {
        "whatsapp:+" + phoneDigits.filter(\.isNumber)
    }
    /// "imessage:+919540752593" for a number, "imessage:someone@icloud.com" for an address.
    public static func imessage(_ handle: String) -> String {
        let h = handle.trimmingCharacters(in: .whitespaces)
        if h.contains("@") { return "imessage:" + h.lowercased() }
        let digits = h.filter(\.isNumber)
        return digits.isEmpty ? "imessage:" + h.lowercased() : "imessage:+" + digits
    }
    public static func slack(userID: String) -> String { "slack:" + userID }
    public static func teams(userID: String) -> String { "teams:" + userID }
    public static func telegram(chatID: Int64) -> String { "telegram:\(chatID)" }
}
