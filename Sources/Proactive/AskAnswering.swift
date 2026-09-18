import Foundation
import Domain

/// Where an ask stands, read from the exchange after it — the user's lines and theirs. Cheap rules first;
/// the on-device reader (never the cloud brain) decides the rest, so the words stay on the Mac.
public enum AskAnswering {
    /// The user's short replies that answer a question by themselves.
    static let acknowledgements: Set<String> = ["ok", "okay", "k", "done", "sure", "yes", "yep", "yeah", "sent", "on it", "haan", "ha", "ho gaya", "kar diya", "bhej diya", "theek hai", "thik hai", "cool", "noted", "got it", "sorted", "sending", "👍", "✅"]
    /// The user says later: the ask is a promise now.
    static let laters = ["will do", "tomorrow", "kal", "later", "give me", "by evening", "next week", "i'll", "i will", "will send", "will share", "will get back", "will check", "will let you know", "tonight", "by eod", "end of day", "this week", "in a bit", "shortly", "soon", "abhi nahi", "thoda time", "parso", "baad mein", "kal tak"]
    /// The user says no.
    static let refusals = ["no", "nope", "nah", "can't", "cant", "cannot", "not possible", "won't be able", "wont be able", "unable to", "nahi", "nahi ho payega", "nahi ho paayega", "nahi kar", "not happening", "no way"]
    /// A "no" that refuses nothing.
    static let notRefusals = ["no problem", "no worries", "no issue", "no issues", "no prob", "no tension", "no wait", "no idea"]
    /// Their word that it is settled: a receipt closes on its own …
    static let receipts = ["got it", "received", "works now", "working now", "done", "ok done", "sorted", "resolved", "fixed", "mil gaya", "ho gaya", "all good", "that works", "it works"]
    /// … the ones that mean it wherever they stand in the line ("thanks, received"); a bare "done" counts only as the line's first word ("let me know when done" is a wait, not a receipt) …
    static let receiptsAnywhere = ["got it", "received", "works now", "working now", "ok done", "mil gaya", "ho gaya", "all good", "that works", "it works", "sorted", "resolved", "fixed"]
    /// … and thanks close only when the user gave something to be thanked for, not a promise to.
    static let thanks = ["thanks", "thank you", "thx", "ty", "tysm", "shukriya", "dhanyavad", "perfect", "great", "awesome", "cool", "thik hai", "theek hai", "ok", "okay", "noted", "cheers"]
    /// A word that turns a receipt around: "not done yet" is no receipt, and "once fixed, ping me" is a wait.
    static let negations = ["not", "nahi", "doesn't", "didn't", "don't", "isn't", "still", "yet", "never", "cannot", "can't", "hasn't", "haven't", "doesnt", "didnt", "dont", "if", "when", "once", "after", "unless", "until"]
    /// What a line may open with before the word that counts: "ok, will do" · "sorry, can't" · "great, thanks".
    static let softeners: Set<String> = ["ok", "okay", "oh", "ah", "ohh", "yes", "yeah", "haan", "arre", "sorry", "hmm", "umm", "great", "cool", "perfect", "awesome", "alright", "sure", "yep", "wow", "hey", "hi", "bhai", "bro", "dude", "man"]
    static let stop: Set<String> = ["the", "and", "for", "with", "about", "that", "this", "you", "your", "can", "could", "would", "please", "pls", "have", "has", "had", "will", "what", "when", "where", "how", "why", "which", "who", "are", "was", "were", "not", "but", "its", "it's", "any", "all", "just", "also", "brownie", "hey", "dude", "bro", "bhai", "kya", "hai", "kaise", "kab", "bata", "do", "ye", "mai", "wala", "ka", "ki", "ke", "important", "message", "urgent", "really"]

    public static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 && !stop.contains($0) })
    }
    /// The line as the rules read it: lowercased, one kind of apostrophe, every other mark a space, wrapped in spaces so a phrase matches whole words only.
    static func norm(_ s: String) -> String {
        let t = s.lowercased().replacingOccurrences(of: "’", with: "'").map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " }
        return " " + String(t).split(separator: " ").joined(separator: " ") + " "
    }
    static func has(_ n: String, _ phrases: [String]) -> Bool { phrases.contains { n.contains(" \($0) ") } }
    static func opens(_ n: String, _ phrases: [String]) -> Bool { phrases.contains { n.hasPrefix(" \($0) ") } }
    /// The line with its opening softeners gone, so "sorry, can't" reads as a refusal and "ok done" as a receipt.
    static func lead(_ n: String) -> String {
        var words = n.split(separator: " ").map(String.init)
        while let f = words.first, softeners.contains(f) { words.removeFirst() }
        return " " + words.joined(separator: " ") + " "
    }

    /// Shared content words, with a little stemming: "postgres" ~ "postgresql", "estimate" ~ "estimates". Nil when either side has none.
    static func overlap(question: String, line: String) -> (score: Double, lineWords: Int)? {
        let q = words(question), a = words(line)
        guard !q.isEmpty, !a.isEmpty else { return nil }
        let shared = q.filter { qw in a.contains { aw in aw == qw || aw.hasPrefix(qw) || qw.hasPrefix(aw) } }
        return (Double(shared.count) / Double(min(q.count, a.count)), a.count)
    }

    /// What one of the user's lines says about the question, or nil when it says nothing the rules can read.
    static func mine(question: String, line: String) -> AskOutcome? {
        let bare = line.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        let n = norm(line), l = lead(n), count = n.split(separator: " ").count
        if acknowledgements.contains(bare) || acknowledgements.contains(l.trimmingCharacters(in: .whitespaces)) { return .answered }
        if has(n, laters) { return .promised }
        let refuses = (opens(l, refusals) && count <= 12) || (has(l, ["not possible", "nahi ho payega", "nahi ho paayega", "won't be able", "wont be able", "not happening", "no way"]) && count <= 20)
        if refuses, !opens(l, notRefusals) { return .declined }
        return (overlap(question: question, line: line)?.score ?? 0) >= 0.34 ? .answered : nil
    }
    /// Does one of their lines say the ask is settled? A receipt ("got it", "works now") does on its own — they may have
    /// found it themselves; thanks do only after the user gave something, and never after a promise or a refusal, which
    /// is what the thanks were for. A line with a question in it is a new ask, not a receipt.
    static func theirs(line: String, afterPromise: Bool, anyMine: Bool) -> Bool {
        guard !line.contains("?") else { return false }
        let n = norm(line), l = lead(n), count = n.split(separator: " ").count
        guard count >= 1, count <= 12, !has(n, negations) else { return false }
        if opens(n, receipts) || opens(l, receipts) || has(n, receiptsAnywhere) { return true }
        return (opens(n, thanks) || opens(l, thanks)) && anyMine && !afterPromise
    }

    /// A verdict and the line that decided it.
    public struct Verdict: Equatable, Sendable { public let outcome: AskOutcome; public let at: Date }

    /// The verdict from the rules alone, or nil when only reading the exchange can tell. Oldest line first: the user's
    /// newest closing word stands ("can't today" then "sent" is answered); a promise never undoes an answer; their
    /// receipt closes whatever came before. With no word from the user and no receipt the ask is open; so is one where
    /// the user's lines, read together, are a real message that shares nothing with the question; too little to tell is nil.
    public static func rules(question: String, window: [AskLine]) -> Verdict? {
        guard !window.isEmpty else { return nil }
        var verdict: Verdict?
        var anyMine = false, lastMine: AskOutcome?, rest: [String] = []
        for l in window {
            if l.mine {
                anyMine = true; lastMine = mine(question: question, line: l.text)
                switch lastMine {
                case .promised?: if verdict?.outcome != .answered && verdict?.outcome != .confirmedByThem { verdict = Verdict(outcome: .promised, at: l.at) }
                case let o?: verdict = Verdict(outcome: o, at: l.at)
                case nil: rest.append(l.text)
                }
            } else if theirs(line: l.text, afterPromise: lastMine == .promised || lastMine == .declined, anyMine: anyMine) {
                verdict = Verdict(outcome: .confirmedByThem, at: l.at)
            }
        }
        if let verdict { return verdict }
        guard anyMine else { return Verdict(outcome: .open, at: window.last?.at ?? .distantPast) }
        guard let o = overlap(question: question, line: rest.joined(separator: "\n")), o.score == 0, o.lineWords >= 6 else { return nil }
        return Verdict(outcome: .open, at: window.last?.at ?? .distantPast)
    }

    static func prompt(question: String, window: [AskLine]) -> String {
        let lines = window.map { "\($0.mine ? "You" : "Them"): \($0.text)" }.joined(separator: "\n")
        return """
        Someone asked the user a question in a chat. The messages after it follow — "Them:" is the person who asked, "You:" is the user. Where does the question stand? Reply with exactly one word:
        answered — the user answered it, or dealt with it
        confirmed — the person who asked says it is settled (thanks, got it, works now)
        declined — the user said no
        promised — the user said they would get to it later
        open — nothing here settles it

        Them (the question): "\(question.prefix(300))"
        \(lines)

        One word (answered, confirmed, declined, promised or open):
        """
    }
    /// The reader's word, read leniently: the first word decides ("yes" and "no" from an older prompt still count), or failing that any of the five found in the first line.
    static func parse(_ text: String) -> AskOutcome? {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let table: [(String, AskOutcome)] = [("answer", .answered), ("confirm", .confirmedByThem), ("declin", .declined), ("promis", .promised), ("open", .open)]
        let first = String(t.prefix { $0.isLetter })
        if let hit = (table + [("yes", .answered), ("no", .open)]).first(where: { first.hasPrefix($0.0) }) { return hit.1 }
        let line = t.split(separator: "\n").first.map(String.init) ?? t
        return table.first { line.contains($0.0) }?.1
    }

    /// Fills in the outcome of every ask not yet judged that has something after it — the rules first, then the local
    /// reader when there is one. An ask already settled or let go is never judged again; an ask judged before there
    /// were windows is read from the reply it kept.
    public static func judge(_ asks: [Ask], reader: (any LocalModel)?) async -> [Ask] {
        var out = asks
        for i in out.indices where out[i].awaitsVerdict {
            let window = out[i].window ?? out[i].legacyWindow
            guard !window.isEmpty else { continue }
            if let v = rules(question: out[i].question, window: window) { out[i].settle(v.outcome, at: v.at, by: "rules"); continue }
            guard let reader, await reader.isLoaded else { continue }
            guard let r = try? await reader.generate(GenerateRequest(prompt: prompt(question: out[i].question, window: window), maxOutputTokens: 4)), let o = parse(r.text) else { continue }
            let at = (o == .confirmedByThem ? window.last { !$0.mine } : window.last { $0.mine })?.at ?? window.last!.at
            out[i].settle(o, at: at, by: "reader")
        }
        return out
    }
}

public extension Ask {
    /// The verdict, with `addressed` kept in step for whatever still reads the flag.
    mutating func settle(_ outcome: AskOutcome, at: Date, by: String, how: String? = nil) {
        self.outcome = outcome; outcomeAt = at; outcomeBy = by; outcomeHow = how; addressed = outcome.addressed
    }
    /// Not yet judged, and still worth judging: not settled, not let go.
    var awaitsVerdict: Bool { outcome == nil && !isSettled && lapsedAt == nil }
    /// Settled by the user's own reply in the chat — an answer or a no, not their word and not the judge's.
    var byReply: Bool {
        switch outcome {
        case nil, .declined?: return true
        case .answered?: return outcomeBy != "judge"
        default: return false
        }
    }
    /// The window an ask from before there were windows stands in for: the reply it kept, one line per message, all the user's.
    var legacyWindow: [AskLine] {
        guard let reply, !reply.isEmpty, let at = answeredAt else { return [] }
        return reply.split(separator: "\n").map { AskLine(at: at, mine: true, text: String($0)) }
    }
}
