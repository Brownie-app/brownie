import Foundation

/// Checking what Brownie says it was told against what was actually said.
///
/// Every claim in the app descends from a model: a source's messages become a summary, the summary becomes a
/// loop, the loop becomes a note, the note becomes a card's evidence. Each step is prose written by a model from
/// prose written by a model, and nothing along the way ever looks at the message again. That has two costs, and
/// an audit of one real ledger found both:
///
/// - **Invention.** A loop read "Call Asha back about the potential 9 lakh funding". No message, log or
///   ingest record anywhere mentioned a figure. It reached a card marked `verified`, because the card's two
///   pieces of evidence — a summary and a People note — agreed with each other, and the note had been written
///   from that summary. Two descendants of one invention, corroborating it.
/// - **Corruption.** The same container registry id appeared in three loops as `100200300400500`,
///   `10020030040050010` and `10020030045040500`. A date appeared as "October 109", a name with a letter
///   dropped. Each one passes any check made against the model's own quote, because the quote carries the same wrong value.
///
/// So a quote the model wrote cannot be the thing a claim is checked against: it is the claim again, in other
/// words. The only check worth making compares the claim to **the message**, read back from the source. That is
/// what this is for. It stores nothing: `SourceLine`s are fetched for the check and dropped, so this adds no
/// retention and no new copy of anyone's messages.
public enum Verbatim {

    /// How much of a claim's wording must appear in a message before that message counts as the one it came
    /// from. Low, because a judge rewrites a promise into an imperative ("Send Kiran the signed NDA" from "yeah
    /// I'll get the NDA over to you") and little of the original survives; the specifics check below is what
    /// does the real work, and it is exact.
    public static let supportOverlap = 0.34

    /// The longest a stored span may be. A span exists to show the reader the line it came from, not to keep a
    /// copy of the conversation.
    public static let spanLimit = 240

    /// Words too common to prove anything. Shared with the overlap score so that "the user said the file"
    /// matching "the user said the date" scores zero rather than three quarters.
    static let weightless: Set<String> = [
        "the", "and", "for", "with", "about", "that", "this", "you", "your", "was", "were", "have", "has", "had",
        "will", "said", "says", "user", "asked", "told", "from", "are", "not", "but", "they", "them", "then",
        "than", "into", "onto", "also", "would", "once", "after", "before", "when", "what", "there",
    ]
    // "back" is deliberately not in that list. It looks like a filler word and is not one: "call back" and
    // "call" are different promises, and with it discounted a loop reading "Call Asha back" scored 0.33
    // against the message "will call you back" — just under the bar, and so got no span at all.

    /// Comparison only — never what is stored. Case, punctuation, the bidi marks a chat export is full of, and
    /// runs of whitespace all differ between a message and a model's retelling of it without either being wrong.
    public static func fold(_ s: String) -> String {
        let stripped = s.unicodeScalars.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == " " || $0 == "\n" || $0 == "\t" }
        return String(String.UnicodeScalarView(stripped)).lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The meaningful words of a string, for scoring.
    public static func words(_ s: String) -> Set<String> {
        Set(fold(s).split(separator: " ").map(String.init).filter { $0.count > 2 && !weightless.contains($0) })
    }

    /// The real message a claim most plausibly came from, as a span — or nil when nothing in `lines` supports it.
    ///
    /// Nil is not a verdict that the claim is false. It means the source could not be read back, or the claim is
    /// too far from anything in the window to say. Callers must treat nil as "unproven", never as "disproven":
    /// refusing every loop whose chat happens to be unreadable would be a worse app than the one that invents.
    public static func support(for claim: String, in lines: [SourceLine], minOverlap: Double = supportOverlap) -> Span? {
        let target = words(claim)
        guard !target.isEmpty else { return nil }
        var best: (line: SourceLine, score: Double)? = nil
        for line in lines {
            let w = words(line.text)
            guard !w.isEmpty else { continue }
            let score = Double(w.intersection(target).count) / Double(min(w.count, target.count))
            if score > (best?.score ?? 0) { best = (line, score) }
        }
        guard let best, best.score >= minOverlap else { return nil }
        return Span(best.line)
    }

    /// Does this exact wording appear in one of the messages? Used where the model was asked to copy a line out
    /// rather than describe it — a quote that fails this was not copied, whatever it is labelled.
    public static func appears(_ text: String, in lines: [SourceLine]) -> Bool {
        let needle = fold(text)
        guard needle.count >= 8 else { return false }   // "ok" appears in everything and proves nothing
        return lines.contains { fold($0.text).contains(needle) }
    }
}

/// One real message, as read back from its source for a check. Deliberately not `ChatMessage`: that type lives in
/// `LocalSources`, which `Domain` and `Proactive` cannot see, and the check needs nothing from it but these three.
public struct SourceLine: Sendable, Equatable {
    public let id: String
    public let said: Date
    public let text: String
    public init(id: String, said: Date, text: String) { self.id = id; self.said = said; self.text = text }
}

/// Reading a conversation back, so what the night says about it can be checked against it.
///
/// Passed in as a closure for the reason `contacts` and `bucketProofs` are: the layers that need to check a
/// claim cannot see the layers that can read a chat, and a night under test must be able to say what the
/// messages were without a WhatsApp database.
///
/// Returning `[]` means "could not read it", not "there was nothing". Every caller treats the two the same way
/// and declines to judge, because refusing a claim whose source happens to be unreadable is how an app that
/// invents becomes an app that says nothing.
public typealias SourceLineLookup = @Sendable (_ person: String, _ around: Date) async -> [SourceLine]

/// A line of a real message, kept so a claim can be shown the thing it came from.
///
/// This is what `Loop.quote` was always described as and never was. The difference matters: `quote` is the
/// reader's retelling, which can say anything; a `Span` is bytes that were in a message, with the message's own
/// id beside them, and a claim it does not support is a claim nothing supports.
public struct Span: Codable, Sendable, Equatable {
    /// Verbatim, as it appeared — capped at `Verbatim.spanLimit`, never reworded.
    public let text: String
    /// The message it was taken from, so the app can open the conversation at that line.
    public let messageID: String
    public let said: Date
    public init(text: String, messageID: String, said: Date) {
        self.text = String(text.prefix(Verbatim.spanLimit)); self.messageID = messageID; self.said = said
    }
    public init(_ line: SourceLine) { self.init(text: line.text, messageID: line.id, said: line.said) }
}

/// The parts of a sentence that are either exactly right or simply wrong.
///
/// Most of a claim is paraphrase, and paraphrase is allowed to drift: "call him back" and "ring Asha" are the
/// same promise. Amounts, counts, dates, times and long identifiers are not like that. There is no near miss on
/// nine lakh, and `10020030040050010` is not a rounding of `100200300400500`. Those are the words worth
/// checking one at a time against the message, and they are the ones every failure in the audit turned on.
public enum Specifics {

    /// An amount or a count: "9 lakh", "2,00,000", "40%", "3 pm".
    static let amount = #/\b\d[\d,.]*\s*(lakh|lakhs|lac|lacs|crore|crores|cr|k|m|bn|%|am|pm|rs\.?|inr|usd|eur|gbp)?\b/#
    /// A date written any of the ways people write one. Case-insensitive, or "30 Sep" is read as the number 30
    /// and the month is never checked at all.
    static let date = #/(?i)\b(\d{4}-\d{2}-\d{2}|\d{1,2}(st|nd|rd|th)?\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*|(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s*\d{1,2}(st|nd|rd|th)?)\b/#
    /// A number long enough that nobody would retype it from memory — a registry id, an order number, an
    /// account. These are the ones that came back corrupted three different ways in the audit.
    static let identifier = #/\b[0-9]{6,}\b/#
    /// A tagged name that has to be exact to be any use: `api-worker:latest`, `v2.4.1`, `#design`.
    static let tagged = #/\b[A-Za-z][A-Za-z0-9._-]*[:#][A-Za-z0-9._-]+\b/#

    /// Numbers too small and too common to be worth checking: "the three tasks", "one more", "slide 2". These
    /// drift harmlessly in a retelling and flagging them would make the gate fire on almost every loop.
    static let trivial: Set<String> = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "one", "two", "three"]

    /// Every specific in a piece of text, in the order it appears, deduplicated.
    ///
    /// Where two patterns cover the same ground the longer wins: "30 Sep" is the date, and reporting "30"
    /// beside it would check the day against the message while letting the month through unchecked.
    public static func found(in text: String) -> [String] {
        // `needsDigit` keeps the digit rule where it belongs. It exists to drop bare words the amount pattern
        // picks up, and a tagged name — `api-worker:latest`, `#design` — has no digit and is still the
        // most exact thing in the sentence.
        var hits: [(range: Range<String.Index>, needsDigit: Bool)] = []
        hits += text.matches(of: amount).map { ($0.range, true) }
        hits += text.matches(of: date).map { ($0.range, true) }
        hits += text.matches(of: identifier).map { ($0.range, true) }
        hits += text.matches(of: tagged).map { ($0.range, false) }
        hits.sort { a, b in
            a.range.lowerBound == b.range.lowerBound
                ? a.range.upperBound > b.range.upperBound
                : a.range.lowerBound < b.range.lowerBound
        }
        var out: [String] = []
        var taken: [Range<String.Index>] = []
        for hit in hits {
            if taken.contains(where: { $0.lowerBound <= hit.range.lowerBound && hit.range.upperBound <= $0.upperBound }) { continue }
            let t = String(text[hit.range]).trimmingCharacters(in: .whitespaces)
            let bare = t.replacingOccurrences(of: ",", with: "").lowercased()
            guard !t.isEmpty, !trivial.contains(bare), !hit.needsDigit || t.contains(where: \.isNumber) else { continue }
            taken.append(hit.range)
            if !out.contains(t) { out.append(t) }
        }
        return out
    }

    /// The specifics in `claim` that no message in `lines` contains.
    ///
    /// Compared folded, so "9 lakh" matches "9 Lakh" and "₹9 lakh"; and compared against the message's own
    /// digits, so a corrupted id fails even though the model's quote of it agrees with the model's claim.
    ///
    /// Known limit: a figure written as digits in the claim and as words in the message ("9 lakh" against
    /// "nine lakh") reads as unsupported, and the clause carrying it is cut. The loop keeps its promise
    /// and loses a true detail — a worse answer than it could give, but a true one, and the trade only goes
    /// this way. Every cut is logged by name, so the cost of this is visible rather than silent.
    public static func unsupported(in claim: String, against lines: [SourceLine]) -> [String] {
        guard !lines.isEmpty else { return [] }   // nothing to check against is not the same as checked and failed
        let haystack = lines.map { Verbatim.fold($0.text) }
        return found(in: claim).filter { spec in
            let f = Verbatim.fold(spec)
            let digits = f.filter(\.isNumber)
            return !haystack.contains { hay in
                hay.contains(f) || (!digits.isEmpty && hay.filter(\.isNumber).contains(digits) && hay.contains(digits))
            }
        }
    }
}

/// Removing from a claim the part that nothing in the message supports, without losing the part that does.
///
/// Dropping the whole loop would be the easy rule and the wrong one: "Call Asha back" was a real promise, and
/// only "about the potential 9 lakh funding" was invented. Losing a real promise to punish an invented clause
/// trades a visible error for an invisible one. So the clause goes and the promise stays — and when the clause
/// cannot be found cleanly, only then is the whole claim refused.
public enum Claim {

    /// Words that open a clause which can be cut off the end without breaking the sentence before it.
    static let openers = ["about", "regarding", "re", "for", "of", "worth", "around", "with", "at", "on", "by", "to", "in"]

    /// `claim` with every clause carrying an unsupported specific removed, or nil when it cannot be done without
    /// leaving nonsense. The caller logs both outcomes: a silent repair is as bad as a silent invention.
    public static func withoutUnsupported(_ claim: String, specifics: [String]) -> String? {
        guard !specifics.isEmpty else { return claim }
        var out = claim
        for spec in specifics {
            guard let hit = out.range(of: spec, options: .caseInsensitive) else { continue }
            guard let cut = clauseStart(in: out, before: hit.lowerBound) else { return nil }
            let end = out[hit.upperBound...].firstIndex(of: ",") ?? out.endIndex
            out.removeSubrange(cut..<end)
        }
        let tidied = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—"))
        // What is left has to still be a promise: a verb and an object, not "Call" on its own.
        return tidied.split(separator: " ").count >= 2 ? tidied : nil
    }

    /// Where the clause containing `index` begins: the last clause-opening word, or the last comma, before it.
    static func clauseStart(in text: String, before index: String.Index) -> String.Index? {
        let head = text[text.startIndex..<index]
        if let comma = head.lastIndex(of: ",") { return comma }
        var best: String.Index? = nil
        for opener in openers {
            var search = head.startIndex
            while let r = head.range(of: " \(opener) ", options: .caseInsensitive, range: search..<head.endIndex) {
                if best == nil || r.lowerBound > best! { best = r.lowerBound }
                search = r.upperBound
            }
        }
        return best
    }
}
