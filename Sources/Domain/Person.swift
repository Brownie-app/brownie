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
