import Foundation
import Domain

/// Did the user's reply answer the question, or was it about something else? Cheap rules first;
/// the on-device reader (never the cloud brain) decides the rest, so the words stay on the Mac.
public enum AskAnswering {
    static let acknowledgements: Set<String> = ["ok", "okay", "k", "done", "sure", "yes", "yep", "yeah", "no", "nope", "sent", "will do", "on it", "haan", "ha", "nahi", "ho gaya", "kar diya", "bhej diya", "theek hai", "thik hai", "cool", "noted", "got it", "👍", "✅"]
    static let stop: Set<String> = ["the", "and", "for", "with", "about", "that", "this", "you", "your", "can", "could", "would", "please", "pls", "have", "has", "had", "will", "what", "when", "where", "how", "why", "which", "who", "are", "was", "were", "not", "but", "its", "it's", "any", "all", "just", "also", "brownie", "hey", "dude", "bro", "bhai", "kya", "hai", "kaise", "kab", "bata", "do", "ye", "mai", "wala", "ka", "ki", "ke", "important", "message", "urgent", "really"]

    public static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 && !stop.contains($0) })
    }

    /// Yes / no from the rules alone, or nil when only reading both can tell.
    public static func quick(question: String, reply: String) -> Bool? {
        let r = reply.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        if acknowledgements.contains(r) { return true }
        let q = words(question), a = words(reply)
        guard !q.isEmpty, !a.isEmpty else { return nil }
        // shared content words, with a little stemming: "postgres" ~ "postgresql", "estimate" ~ "estimates"
        let shared = q.filter { qw in a.contains { aw in aw == qw || aw.hasPrefix(qw) || qw.hasPrefix(aw) } }
        let score = Double(shared.count) / Double(min(q.count, a.count))
        if score >= 0.34 { return true }
        if shared.isEmpty && a.count >= 6 { return false }   // a real message that shares nothing with the question
        return nil
    }

    static func prompt(question: String, reply: String) -> String {
        """
        Someone asked the user a question in a chat, and the user's next message is below. Does the user's message respond to that question — answer it, decline it, promise to get to it, or ask about it? Reply with exactly one word: yes or no.

        Their question: "\(question.prefix(300))"
        The user's next message: "\(reply.prefix(400))"

        One word:
        """
    }

    /// Fills in `addressed` for every answered ask that isn't judged yet, using the rules, then the local reader when there is one.
    public static func judge(_ asks: [Ask], reader: (any LocalModel)?) async -> [Ask] {
        var out = asks
        for i in out.indices where out[i].answeredAt != nil && out[i].addressed == nil {
            guard let reply = out[i].reply, !reply.isEmpty else { continue }
            if let q = quick(question: out[i].question, reply: reply) { out[i].addressed = q; continue }
            guard let reader, await reader.isLoaded else { continue }
            if let r = try? await reader.generate(GenerateRequest(prompt: prompt(question: out[i].question, reply: reply), maxOutputTokens: 4)) {
                let t = r.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if t.hasPrefix("yes") { out[i].addressed = true } else if t.hasPrefix("no") { out[i].addressed = false }
            }
        }
        return out
    }
}
