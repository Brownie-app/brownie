import Foundation
import Domain

/// What was promised out loud. The reader writes a transcript's summary with lines like
/// `At [03:12] the user says "I'll send it by Thursday" to Meera.` — this turns them into loops
/// deterministically, so a spoken promise never depends on the judge noticing it.
public enum TranscriptPromises {
    public struct Found: Sendable, Equatable {
        public let loop: Loop
        public let seconds: TimeInterval
    }

    static let pattern = try! NSRegularExpression(pattern: #"At \[(\d{1,2}:\d{2}(?::\d{2})?)\][,:]?\s+(the user|[A-Z][\w'’-]*(?: [A-Z][\w'’-]*)?)\s+(says|said|asks|asked|promises|promised|agrees|agreed|tells|told|offers|offered|commits|committed)(?:\s+[^"“]{0,40}?)?[:,]?\s*["“]([^"”]+)["”](?:\s+to\s+([A-Z][\w'’-]*(?: [A-Z][\w'’-]*)?))?"#)
    static let askWords: Set<String> = ["asks", "asked"]
    static let iWill = try! NSRegularExpression(pattern: #"^(i['’]ll|i will|i can|let me|i['’]m going to|i['’]d)\b"#, options: .caseInsensitive)
    static let youCan = try! NSRegularExpression(pattern: #"^(can you|could you|will you|would you|please)\b"#, options: .caseInsensitive)

    /// Loops from one transcript summary. `recording` names the file; `date` is when it was recorded. A file stamped
    /// in the future or absurdly far back still holds real promises, so they are kept but opened as of `now`. Every
    /// loop is noticed as of `now` too: a recording read months late ("Read further back", an old memo dropped in the
    /// folder) opens a loop dated by the recording that has its whole term ahead of it, not one born lapsed.
    public static func parse(summary: String, recording: String, date: Date, now: Date) -> [Found] {
        let ns = summary as NSString
        let date = DateSanity.item(date, now: now) ?? now
        var out: [Found] = []
        for m in pattern.matches(in: summary, range: NSRange(location: 0, length: ns.length)) {
            let stamp = ns.substring(with: m.range(at: 1))
            let speaker = ns.substring(with: m.range(at: 2))
            let verb = ns.substring(with: m.range(at: 3)).lowercased()
            let quote = ns.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces)
            let addressee = m.range(at: 5).location == NSNotFound ? nil : ns.substring(with: m.range(at: 5))
            let userSpoke = speaker.lowercased() == "the user"
            let isAsk = askWords.contains(verb) || youCan.firstMatch(in: quote, range: NSRange(location: 0, length: (quote as NSString).length)) != nil
            let isOffer = iWill.firstMatch(in: quote, range: NSRange(location: 0, length: (quote as NSString).length)) != nil || ["promises", "promised", "agrees", "agreed", "commits", "committed", "offers", "offered"].contains(verb)
            // who owes whom
            let direction: LoopDirection, person: String
            if userSpoke {
                if isAsk { direction = .theirs; person = addressee ?? "someone" }          // the user asked them for something
                else if isOffer { direction = .mine; person = addressee ?? "someone" }      // the user promised
                else { continue }
            } else {
                if isAsk { direction = .mine; person = speaker }                            // they asked the user
                else if isOffer { direction = .theirs; person = speaker }                  // they promised the user
                else { continue }
            }
            let what = tidy(quote)
            let f = DateFormatter(); f.dateFormat = "EEE d MMM"
            let loop = Loop(id: "rec-" + stableID(recording, stamp, quote), direction: direction, person: person, what: what, quote: quote,
                            sourceLabel: "Recording · \(recording) · \(stamp)", due: dueWords(quote), dueDate: nil, status: .open, openedAt: date, noticedAt: now)
            out.append(Found(loop: loop, seconds: secondsOf(stamp)))
        }
        return out
    }

    /// "I'll send it by Thursday" → "send it by Thursday"; "can you share the deck?" → "share the deck".
    static func tidy(_ q: String) -> String {
        var s = q.trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
        for prefix in ["i'll ", "i’ll ", "i will ", "i can ", "let me ", "i'm going to ", "i’m going to ", "i'd ", "i’d ", "can you ", "could you ", "will you ", "would you ", "please ", "we'll ", "we’ll ", "we will "] {
            if s.lowercased().hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)); break }
        }
        return s.isEmpty ? q : s
    }
    static let dueRe = try! NSRegularExpression(pattern: #"\b(by|before|on|until|till) (monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|tonight|today|the \d{1,2}(?:st|nd|rd|th)?|\d{1,2}(?:st|nd|rd|th)?(?: of)? [A-Z][a-z]+|end of (?:the )?(?:day|week|month)|next week|eod|eow)\b"#, options: .caseInsensitive)
    static func dueWords(_ q: String) -> String? {
        let ns = q as NSString
        guard let m = dueRe.firstMatch(in: q, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range)
    }
    static func secondsOf(_ stamp: String) -> TimeInterval {
        let p = stamp.split(separator: ":").compactMap { Int($0) }
        return p.count == 3 ? TimeInterval(p[0] * 3600 + p[1] * 60 + p[2]) : TimeInterval((p.first ?? 0) * 60 + (p.last ?? 0))
    }
    static func stableID(_ parts: String...) -> String {
        let raw = parts.joined(separator: "|").lowercased()
        return String(raw.utf8.reduce(into: UInt64(1469598103934665603)) { $0 = ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 16)
    }

    /// The card the preparer should make for each promise the user made out loud.
    public static func candidates(_ found: [Found]) -> [ActionItem] {
        found.filter { $0.loop.direction == .mine }.map { f in
            var it = ActionItem(title: "You said you'd \(f.loop.what)", action: "Do it, or tell \(f.loop.person) when", importance: "Said out loud to \(f.loop.person) — “\(f.loop.quote)”", dueDate: f.loop.due, sources: [f.loop.sourceLabel], urgency: f.loop.due == nil ? .medium : .high)
            it.loopID = f.loop.id
            return it
        }
    }
}
