import Foundation
import Domain

/// The bar a new loop must clear before it enters the ledger, kept by code because the judge, however well told,
/// still hands back sentiments ("Build something big", "Focus on her network") as promises, files the same promise
/// once per side, and now and then names the user as the other party. A loop is one specific deliverable one person
/// owes the other that can be seen to be done; everything else is the shape of a relationship and belongs in the notes.
public enum LoopQuality {
    /// Lead verbs (or phrases) that open an intention, a hope or a plan to talk, never a deliverable. Matched at the
    /// start of `what`, whole words only, so "keep" turns away "Keep doing the good work" but not "Keepsake".
    static let aspirations = ["focus", "discuss", "build a company", "build a business", "build something", "be", "become", "not back out", "not", "never",
                              "do not", "don't", "go full time", "go full-time", "go fulltime", "keep", "improve", "work on", "think about", "consider",
                              "explore", "try", "aim", "plan to discuss", "plan to talk", "plan to meet", "plan to chat", "continue", "stop", "stay", "remain",
                              "support", "help out", "look after", "take care", "make sure", "commit to", "chase more", "grow", "figure out", "work out",
                              "get better", "do better", "be more", "spend more", "put more"]
    /// Verbs that open a deliverable. Not exhaustive — any other verb-shaped first word with an object passes too —
    /// but these are known verbs, so they are never mistaken for a gerund ("bring", "ping") or a noun ("copy").
    static let deliverables: Set<String> = ["send", "share", "provide", "call", "pay", "book", "review", "reply", "confirm", "upload", "sign",
                                            "submit", "forward", "fix", "deliver", "ship", "schedule", "set", "introduce", "write", "finalise",
                                            "finalize", "prepare", "ping", "join", "copy", "email", "mail", "text", "message", "give", "bring",
                                            "hand", "drop", "return", "arrange", "organise", "organize", "order", "buy", "pick", "collect", "post",
                                            "publish", "fill", "complete", "update", "add", "remove", "create", "make", "draft", "print", "transfer",
                                            "wire", "register", "apply", "renew", "cancel", "respond", "answer", "read", "test", "connect", "invite",
                                            "attend", "come", "visit", "meet", "get", "check", "close", "open", "chase", "follow", "resend",
                                            "reshare", "let", "tell", "ask", "show", "take", "put", "sort", "settle", "clear", "move", "start",
                                            "run", "push", "merge", "release", "deploy", "record", "list", "find", "look", "attach", "scan",
                                            "photograph", "translate", "edit", "proofread", "design", "code", "install", "configure", "migrate",
                                            "enable", "unblock", "approve", "sync", "decide", "choose", "nominate", "recommend", "refer", "brief",
                                            "remind", "notify", "inform", "escalate", "raise", "file", "lodge", "process", "issue", "refund",
                                            "reimburse", "invoice", "bill", "quote", "estimate", "measure", "count", "verify", "validate",
                                            "resubmit", "reupload", "implement", "document", "comment", "present", "represent", "position", "mention",
                                            "question", "function", "commission", "reference", "influence", "experience", "witness", "address",
                                            "progress", "access", "express", "assess", "stress", "dress", "compress", "guess", "bless", "press"]
    /// First words that are not verbs at all: a `what` opening with one of these names no deliverable.
    static let notVerbs: Set<String> = ["the", "a", "an", "his", "her", "their", "my", "our", "your", "its", "this", "that", "these", "those", "some", "any",
                                        "it", "he", "she", "they", "we", "i", "you", "of", "for", "with", "about", "on", "in", "at", "from", "by", "and", "or",
                                        "but", "if", "when", "while", "as", "than", "more", "most", "less", "very", "so", "no", "yes", "maybe", "possibly",
                                        "probably", "hopefully", "eventually", "someday", "one", "two", "three", "there", "here", "what", "who", "how", "why",
                                        "where", "whether", "something", "anything", "nothing", "everything", "future", "goal", "idea", "hope", "wish"]
    /// Prefixes the judge sometimes leaves on a `what` that otherwise starts with a verb.
    static let modals = ["to ", "will ", "would ", "i'll ", "i’ll ", "i will ", "we'll ", "we’ll ", "we will ", "she'll ", "she’ll ", "he'll ", "he’ll ",
                         "they'll ", "they’ll ", "she will ", "he will ", "they will ", "going to ", "gonna ", "try to ", "try and ", "will try to ",
                         "attempt to ", "promise to ", "promised to ", "agreed to ", "agree to ", "plan to ", "planning to ", "intend to ", "need to ", "needs to ", "has to ", "have to "]

    /// Whether `what` names a deliverable. Deterministic; the reason for a no is in `reason(_:)`.
    public static func isCommitment(_ what: String) -> Bool { reason(what) == nil }

    /// Why `what` is no commitment, in one line for the log; nil when it clears the bar.
    public static func reason(_ what: String) -> String? {
        var s = what.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return "empty" }
        // "will try to send" — every leading modal is forgiven, one after another, and "try" alone is a hedge on a deliverable, not a wish
        var stripped = true
        while stripped { stripped = false; for m in modals where s.hasPrefix(m) { s = String(s.dropFirst(m.count)); stripped = true; break } }
        for a in aspirations where s == a || s.hasPrefix(a + " ") || s.hasPrefix(a + ",") {
            return "“\(a)” opens an intention, not a deliverable"
        }
        let words = s.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" && $0 != "-" }).map(String.init)
        guard let first = words.first, !first.isEmpty else { return "no verb to start with" }
        if deliverables.contains(first) {
            guard words.count > 1 else { return "“\(first)” names no object" }
            return nil
        }
        if notVerbs.contains(first) { return "“\(first)” is not a verb; a loop starts with what is owed" }
        if first.count > 4, first.hasSuffix("ing") { return "“\(first)” describes, it does not promise; a loop starts with a verb" }
        for suffix in ["ment", "tion", "sion", "ness", "ance", "ence", "ity"] where first.count > suffix.count + 2 && first.hasSuffix(suffix) {
            return "“\(first)” is a noun, not a verb; a loop starts with what is owed"
        }
        guard words.count > 1 else { return "“\(first)” names no object" }
        return nil
    }

    /// The same promise reported once per side ("they promised: Provide her sister's number" beside "you promised:
    /// Provide Vivek's sister's number") is one loop. Two loops within three days of each other, in opposite
    /// directions, with the same person, whose content words (possessives, pronouns and names stripped) overlap by
    /// six in ten or more are a mirror: the first stays, the later one goes.
    public static func dedupeMirrored(_ loops: [Loop]) -> [Loop] {
        var kept: [Loop] = []
        for l in loops {
            if kept.contains(where: { mirrors($0, l) }) { continue }
            kept.append(l)
        }
        return kept
    }
    static func mirrors(_ a: Loop, _ b: Loop) -> Bool {
        guard a.direction != b.direction, PersonKey.same(a.person, b.person), abs(a.openedAt.timeIntervalSince(b.openedAt)) <= 3 * 86400 else { return false }
        let wa = contentWords(a.what), wb = contentWords(b.what)
        guard !wa.isEmpty, !wb.isEmpty else { return false }
        return Double(wa.intersection(wb).count) / Double(min(wa.count, wb.count)) >= 0.6
    }
    /// The words that carry what a promise is about: lowercased, possessives and pronouns gone, names gone (a
    /// capitalised word past the first is a name — the side that says "her sister" and the side that says
    /// "Vivek's sister" mean the same sister), short and function words gone.
    static let functionWords: Set<String> = ["the", "and", "for", "with", "about", "that", "this", "you", "your", "his", "her", "their", "our", "my", "its",
                                             "him", "them", "she", "they", "from", "into", "onto", "over", "will", "would", "can", "could", "please", "again",
                                             "also", "then", "now", "soon", "some", "any", "all"]
    static func contentWords(_ what: String) -> Set<String> {
        var out = Set<String>()
        for (i, raw) in what.split(whereSeparator: { $0.isWhitespace }).enumerated() {
            var w = String(raw)
            for p in ["'s", "’s", "s'", "s’"] where w.hasSuffix(p) { w = String(w.dropLast(p.count)) }
            let word = w.lowercased().filter { $0.isLetter || $0.isNumber }
            guard word.count > 2, !functionWords.contains(word) else { continue }
            if i > 0, let f = w.first, f.isUppercase { continue }   // a name mid-sentence
            out.insert(word)
        }
        return out
    }

    /// A label that names nobody in particular — "another contact", "someone", "the team" — is no other party for a
    /// loop: the judge wrote around a name it did not have, and a promise to nobody cannot be kept or chased.
    static let nobody = try! NSRegularExpression(pattern: #"^\s*(?:(?:an?|the|another|some|one|other)\s+)?(?:contacts?|someone|somebody|anyone|people|person|colleagues?|friends?|team|group|members?|others?|them|they|him|her|unknown|n/?a|tbd|user|recipient|sender|caller|client|vendor|company|number)\s*$"#, options: .caseInsensitive)
    public static func isPersonLabel(_ person: String) -> Bool {
        let t = person.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.contains(where: \.isLetter) else { return false }
        return nobody.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) == nil
    }

    /// The ledger as the bar would have kept it: loops that are no commitment, or whose other party is nobody or the
    /// user, leave whatever their status — a settled sentiment is not history worth a ✅ line either. Run once at
    /// bootstrap for a ledger written before the bar existed; on a clean ledger it changes nothing.
    public static func sweep(_ loops: [Loop], selfNames: [String]) -> (kept: [Loop], dropped: [(loop: Loop, reason: String)]) {
        var kept: [Loop] = [], dropped: [(Loop, String)] = []
        for l in loops {
            if let why = reason(l.what) { dropped.append((l, why)) }
            else if !isPersonLabel(l.person) { dropped.append((l, "the other party is nobody in particular (\(l.person))")) }
            else if SelfNames.isSelf(l.person, among: selfNames) { dropped.append((l, "the other party is the user (\(l.person))")) }
            else { kept.append(l) }
        }
        return (kept, dropped)
    }

    /// The gate the coordinator runs new loops through, in order: nothing that is not a commitment, nothing whose
    /// other party is nobody or the user, and no mirror of a loop already admitted tonight or still open from an
    /// earlier night (`existing`). `rejected` carries the reason for each loop turned away, for the log.
    public static func admit(_ loops: [Loop], selfNames: [String] = [], existing: [Loop] = []) -> (kept: [Loop], rejected: [(loop: Loop, reason: String)]) {
        var kept: [Loop] = [], rejected: [(Loop, String)] = []
        let open = existing.filter { $0.status == .open }
        for l in loops {
            if let why = reason(l.what) { rejected.append((l, why)); continue }
            if !isPersonLabel(l.person) { rejected.append((l, "the other party is nobody in particular (\(l.person))")); continue }
            if SelfNames.isSelf(l.person, among: selfNames) { rejected.append((l, "the other party is the user (\(l.person))")); continue }
            if let twin = (kept + open).first(where: { mirrors($0, l) }) { rejected.append((l, "mirrors “\(twin.what)” (\(twin.direction.rawValue))")); continue }
            kept.append(l)
        }
        return (kept, rejected)
    }
}
