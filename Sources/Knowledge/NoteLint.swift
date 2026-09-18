import Foundation
import Domain

/// The words of a People or Groups note, tidied where the brain's habits get in the way of reading. Notes are written
/// for the user, so "the user" becomes "you" (and the verb after it follows, where that is mechanical and safe); a
/// clause that only says nothing is recorded ("delivery is not confirmed", "no decision was established") goes and the
/// sentence around it stays; a bullet left with nothing to say, or that only said so ("Nothing new.", "No standing
/// facts yet.", "TBD"), goes; a line of the brain talking about the note itself ("Earlier plans remain historical
/// unless noted above:") keeps only the facts after its colon; and two bullets that say the same thing across About,
/// Now and Context are one fact, the newer kept in the higher section. Runs on the note taken apart by
/// `NoteSkeleton`, between its parse and `NoteAging`'s clock, so the status block, a comment, a table, a fence, a quote
/// and a sub-heading are never touched, a wikilink or a code span is never touched, a bullet with lines nested under
/// it is only put in your voice (a rule that could cut or drop it would take what sits under it), and Earlier — history,
/// and where the pipeline's retired lines are matched by their words — is left as it is. Idempotent: a clean note
/// passes through unchanged. Every list of habits is data, so the next one is one line here.
public enum NoteLint {
    /// What the lint did, in numbers; `counted` says it in words.
    struct Report: Equatable {
        var voiced = 0, hedges = 0, dropped = 0, merged = 0, meta = 0
        var counted: [String] {
            var out: [String] = []
            func n(_ v: Int, _ one: String, _ many: String) -> String { "\(v) \(v == 1 ? one : many)" }
            if voiced > 0 { out.append(n(voiced, "line put in your voice", "lines put in your voice")) }
            if hedges > 0 { out.append(n(hedges, "hedge removed", "hedges removed")) }
            if dropped > 0 { out.append(n(dropped, "empty bullet dropped", "empty bullets dropped")) }
            if merged > 0 { out.append(n(merged, "repeated bullet merged", "repeated bullets merged")) }
            if meta > 0 { out.append(n(meta, "meta line cut", "meta lines cut")) }
            return out
        }
    }

    /// The body with the word rules applied, and what they changed, in words. A topic or the portrait is returned as
    /// it is; so is a note carrying an unresolved sync conflict. The note is read through the skeleton's parser, so a
    /// note not yet in shape comes back in shape; `now` is what a bare "16 Sep" in a bullet's head is read against.
    public static func clean(body: String, kind: NoteMeta.Kind, now: Date = Date(), timeZone: TimeZone = .current) -> (body: String, changes: [String]) {
        guard kind == .person || kind == .group else { return (body, []) }
        var report = NoteSkeleton.Report()
        var parts = NoteSkeleton.parse(body, now: now, timeZone: timeZone, report: &report)
        guard !parts.conflict else { return (body, []) }
        clean(&parts, report: &report.lint)
        let out = NoteSkeleton.render(parts)
        return (out, out == body ? [] : report.lint.counted)
    }

    /// The rules on the pieces: every About, Now and Context bullet through the line rules, then the repeats folded.
    static func clean(_ p: inout NoteSkeleton.Parts, report: inout Report) {
        p.about = p.about.compactMap { it -> NoteSkeleton.Item? in
            guard it.kind != .verbatim else { return it }
            guard let text = polish(it.text, leaf: it.nested.isEmpty, report: &report) else { return nil }
            var out = it; out.text = text; return out
        }
        func bullets(_ bs: [NoteSkeleton.Bullet], report: inout Report) -> [NoteSkeleton.Bullet] {
            var out: [NoteSkeleton.Bullet] = []
            for b in bs {
                guard !b.verbatim else { out.append(b); continue }
                guard let text = polish(b.text, leaf: b.nested.isEmpty, report: &report) else { continue }
                var c = b; c.text = text; out.append(c)
            }
            return out
        }
        p.now = bullets(p.now, report: &report)
        p.context = bullets(p.context, report: &report)
        // Earlier's month lines get the voice and the hedges taken out clause by clause, never a clause dropped whole
        // unless it is filler: the retired lines are matched against these clauses, and those carry no hedges.
        p.earlier = p.earlier.map { line in
            var out = line
            out.clauses = line.clauses.compactMap { c -> String? in
                var w = c; voice(&w, report: &report); w = unhedged(w, report: &report)
                return w.isEmpty || filler(w) ? nil : w
            }
            return out.clauses.isEmpty ? line : out
        }
        merge(&p, report: &report)
    }

    // MARK: one bullet

    /// One bullet's words through the line rules, in the order that keeps one rule from undoing another: the meta head
    /// off first (its hedge would otherwise take the facts after the colon with it), then the voice, then the hedges,
    /// then the filler check. Nil when the bullet has nothing left to say.
    static func polish(_ text: String, leaf: Bool, report: inout Report) -> String? {
        var words = text
        guard leaf else { voice(&words, report: &report); return words }
        if let cut = metaCut(words) {
            report.meta += 1
            guard let facts = cut else { return nil }
            words = facts
        }
        voice(&words, report: &report)
        words = unhedged(words, report: &report)
        if filler(words) { report.dropped += 1; return nil }
        return words
    }

    /// A wikilink or a code span: words the rules never read.
    static let shielded = try! NSRegularExpression(pattern: #"\[\[[^\]]*\]\]|`[^`]*`"#)
    static func shields(_ s: String) -> [NSRange] { shielded.matches(in: s, range: NSRange(s.startIndex..., in: s)).map(\.range) }
    static func free(_ r: NSRange, of shields: [NSRange]) -> Bool { !shields.contains { NSIntersectionRange($0, r).length > 0 } }

    // MARK: voice

    static let userMark = try! NSRegularExpression(pattern: #"\b([Tt])he user(?:(['’]s)\b|\b(?! (?:experience|experiences|interface|interfaces|journey|journeys|base|story|stories|testing|research|feedback|guide|guides|name|names|account|accounts|id|ids|manual|manuals|flow|flows|profile|profiles|group|groups|level|levels|input|inputs|session|sessions|role|roles|permission|permissions|behaviou?rs?|personas?|acceptance|onboarding|management|retention|growth|segments?|surveys?|interviews?|stud(?:y|ies)|adoption|engagement|community|communities|agent|agents|device|devices)\b))"#)
    /// After "you said/plans/…", a "he" or "she" is the user again ("the user said he would" → "you said you would").
    static let pronounAfterYou = try! NSRegularExpression(pattern: #"\b([Yy]ou (?:said|says|believes?d?|thinks|thought|expects?|expected|plans?|planned|agreed?s?|confirms?|confirmed|mentions?|mentioned|notes?|noted|adds?|added|replies|replied|feels?|felt|hopes?|hoped|wants?|wanted|thinks|thought|indicated|indicates|stated|states)) (?:he|she) (would|will|had|has|is|was|could|can|might|may|should|did|does|wanted|wants|needs|needed|plans|planned|intends|intended|expects|expected)\b"#)
    static let verbAfterYou = try! NSRegularExpression(pattern: #"\b[Yy]ou (is|was|has|does|says|plans|agrees|expects|believes|needs|wants)\b"#)
    static let selfAfterYou = try! NSRegularExpression(pattern: #"\b[Yy]ou (himself|herself)\b"#)
    static let sentenceStart = try! NSRegularExpression(pattern: #"(?:^|[.!?]\s+)$"#)
    static let verbs = ["is": "are", "was": "were", "has": "have", "does": "do", "says": "say", "plans": "plan", "agrees": "agree", "expects": "expect", "believes": "believe", "needs": "need", "wants": "want"]
    /// A word before "you" after which "you" is an object and the verb belongs to something else ("the deck she sent
    /// you was late", "what matters to you is"): a preposition, or a verb that hands something to someone.
    static let objectCue: Set<String> = ["to", "for", "with", "from", "at", "of", "by", "about", "on", "in", "than", "like", "between", "among", "over", "under", "without", "before", "after", "near", "through", "via", "per", "toward", "towards", "into", "onto", "upon", "against", "sent", "send", "sends", "told", "tell", "tells", "gave", "give", "gives", "showed", "show", "shows", "owed", "owe", "owes", "left", "lent", "brought", "got", "met", "paid", "asked", "ask", "asks", "let", "lets", "keep", "keeps", "kept", "cost", "costs", "wish", "wishes"]

    /// "the user" to "you" — the possessive to "your", a capital kept, and one given at the head of a sentence — then
    /// the verb right after made to agree where "you" is the subject, and "himself"/"herself" right after made "yourself".
    /// Counts the line when it changed.
    static func voice(_ text: inout String, report: inout Report) {
        let out = voiced(text)
        if out != text { report.voiced += 1; text = out }
    }
    static func voiced(_ text: String) -> String {
        var s = text
        // one rule at a time over the whole line, right to left so a replacement never moves what is still to come;
        // the shield is found afresh each time, since the line changes length as it goes
        func pass(_ rule: NSRegularExpression, _ replace: (NSTextCheckingResult, NSMutableString) -> Void) {
            let ns = NSMutableString(string: s), shield = shields(s)
            for m in rule.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() where free(m.range, of: shield) { replace(m, ns) }
            s = ns as String
        }
        pass(userMark) { m, ns in
            let before = ns.substring(to: m.range.location)
            let capital = ns.substring(with: m.range(at: 1)) == "T" || sentenceStart.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil
            let word = m.range(at: 2).location == NSNotFound ? "you" : "your"
            ns.replaceCharacters(in: m.range, with: capital ? word.capitalized : word)
        }
        pass(verbAfterYou) { m, ns in
            guard !object(before: m.range.location, in: ns), let verb = verbs[ns.substring(with: m.range(at: 1))] else { return }
            ns.replaceCharacters(in: m.range(at: 1), with: verb)
        }
        pass(selfAfterYou) { m, ns in ns.replaceCharacters(in: m.range(at: 1), with: "yourself") }
        pass(pronounAfterYou) { m, ns in ns.replaceCharacters(in: m.range, with: ns.substring(with: m.range(at: 1)) + " you " + ns.substring(with: m.range(at: 2))) }
        return s
    }
    /// Whether the word before `location` marks "you" as an object: a cue word, or a past-tense verb ("reminded you").
    static func object(before location: Int, in ns: NSMutableString) -> Bool {
        let head = ns.substring(to: location).trimmingCharacters(in: .whitespaces)
        guard let last = head.split(whereSeparator: { !$0.isLetter }).last, head.last?.isLetter == true else { return false }
        let word = last.lowercased()
        return objectCue.contains(word) || (word.hasSuffix("ed") && word.count > 3)
    }

    // MARK: hedges

    /// The clauses that say nothing — that no outcome is recorded, that a plan is not an established outcome — as
    /// patterns matched anywhere in a clause, case-insensitively. A clause that matches goes; the rest of its sentence
    /// stays. Data, so the next brain habit is one line here.
    static let hedgePatterns: [NSRegularExpression] = [
        #"\bno (?:\w+ ){0,3}(?:outcome|decision|approval|resolution|completion|figures?|contact details|deal closure|full-time change|closed deal|pending action|actions?|requests?|obligations?|reply|response|follow-up|changes?|commitments?|dates?|time|timing|venue|resolution or confirmed alternative)\b[^.;]* (?:is|are|was|were) (?:recorded|established|confirmed|captured|noted)(?: here| yet)?"#,
        #"\b(?:this|these) (?:is|are) (?:a )?(?:plan|plans|leads?)\b[^.;]*\bnot (?:an )?(?:established|confirmed) outcome"#,
        #"\bnot independently confirmed\b"#,
        #"\bthe (?:available )?(?:summary|summaries|records?) (?:do|does) not (?:establish|confirm|record)\b[^.;]*"#,
        #"\bno later summary confirms\b[^.;]*"#,
        #"\bthe outcome and any (?:user|your) action are not recorded\b"#,
        #"\bnothing (?:is|was) recorded\b[^.;]*"#,
        #"\bremains? (?:under discussion|historical) unless noted above\b[^.;]*"#,
        #"\bdelivery is not confirmed\b"#,
        #"\bthe timing and transition are not independently confirmed\b"#,
        #"\bit does not create a new pending action\b"#,
        #"\b(?:the )?(?:outcome|result|reply|response|status|delivery|completion|timing|details?) (?:is|are|was|were) not (?:yet )?(?:recorded|established|confirmed|captured|known)\b"#,
        #"\bno\b[^.;,]{0,60}\b(?:is|are|was|were) (?:recorded|established|confirmed|captured|documented|noted)(?: here| yet)?"#,
        #"\bneither\b[^.;]{0,80}\bnor\b[^.;]{0,80}\b(?:is|are|was|were) (?:recorded|established|confirmed|captured)"#,
        #"[^.;]*\b(?:do|does|did) not (?:establish|confirm|record|create|imply)\b[^.;]*"#,
        #"\b(?:is|are|was|were) (?:intentionally |deliberately )?not recorded(?: here)?\b"#,
        #"\b(?:the )?actual (?:identifiers|numbers|amounts|figures|details)(?: and [^.;]{0,40})? (?:are|is) (?:intentionally |deliberately )?(?:not recorded|omitted|left out)(?: here)?"#,
        #"\bthese materials concern\b[^.;]*"#,
        #"\b(?:were|was|is|are) not consistently confirmed\b[^.;]*"#,
        #"\b(?:so )?there (?:is|are|was|were) no (?:reliable|firm|confirmed)\b[^.;]*"#,
        #"\b(?:these|this|those|that) (?:was|were|is|are) (?:just |only |purely )?conversational context\b[^.;]*"#,
        #"\bnot (?:confirmed|established|firm) (?:referrals?|outcomes?|plans?|commitments?|dates?|bookings?)\b[^.;]*"#,
        #"\b(?:is|are|was|were) resolved only at that level\b[^.;]*"#,
        #"\b(?:those|these|such) (?:references|mentions|names) are not treated as commitments\b[^.;]*"#,
        #"\b(?:amounts?|figures|account details|identifiers|account numbers)(?: and [^.;]{0,30})? (?:are|is|were) (?:intentionally |deliberately )?(?:omitted|left out|not (?:recorded|included|kept))\b[^.;]*"#,
        #"^(?:the )?[^.;]{0,60}\b(?:were|was|are|is) (?:just |only |still )?(?:proposals?|a proposal|ideas? only|tentative|speculative|hypothetical)\s*\.?\s*$"#,
        #"\b(?:individual |the )?(?:recurring )?(?:contacts|people|members) now have (?:their own |separate )notes\b[^.;]*"#,
    ].map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    /// Where one clause ends and the next begins: a semicolon, a spaced dash, a full stop before a capital, or a comma
    /// with a conjunction. The break belongs to the clause before it.
    /// A full stop that ends an abbreviation ("Mr. Taragi", "e.g. Slack", an initial) ends no sentence.
    static let abbreviation = #"(?<!\b[Mm]r|\b[Mm]rs|\b[Mm]s|\b[Dd]r|\b[Jj]r|\b[Ss]r|\b[Ss]t|\bvs|\betc|\be\.g|\bi\.e|\bcf|\bno|\b[A-Z])"#
    static let clauseBreak = try! NSRegularExpression(pattern: #";\s+|\s+[—–]\s+|"# + abbreviation + #"\.\s+(?=[A-Z\[("“])|,\s+(?:but|though|although|and|so|while|which|yet)\s+"#)
    static let aside = try! NSRegularExpression(pattern: #"\s*\(([^()]*)\)"#)
    static let terminal: Set<Character> = [".", "!", "?"]

    /// Whether a clause (or an aside) is one of the hedges.
    static func hedge(_ s: String) -> Bool {
        let r = NSRange(s.startIndex..., in: s)
        return hedgePatterns.contains { $0.firstMatch(in: s, range: r) != nil }
    }
    /// The words without their hedges: an aside in parentheses that is one goes whole; then the clauses, each judged on
    /// its own, the ones that hedge gone and the rest joined by the breaks that led into them, the end tidied (a
    /// dangling break off, the full stop back) and the first word given its capital when the clause that had it went.
    /// Sentences that are hedges from their first word to their full stop, whatever commas and "and"s they hold:
    /// the sentence goes whole, so no half of it is left as a fragment ("References to calls involving Arif.").
    static let sentencePatterns: [NSRegularExpression] = [
        #"^\s*(?:\w+\s+)?these materials concern\b"#,
        #"^\s*(?:individual |the )?(?:recurring )?(?:contacts|people|members) now have (?:their own |separate )notes\b"#,
        #"^\s*references to\b.*\b(?:do|does|did) not (?:establish|create|imply)\b"#,
        #"^\s*(?:the )?actual (?:identifiers|numbers|amounts|figures|details)\b.*\bnot recorded\b"#,
        #"^\s*(?:no|neither)\b.*\b(?:is|are|was|were) (?:recorded|established|confirmed|captured|documented|noted)(?: here| yet)?\s*$"#,
    ].map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    static let sentenceEnd = try! NSRegularExpression(pattern: #"(?<=[.!?])"# + abbreviation.replacingOccurrences(of: "|", with: #"\.|"#).replacingOccurrences(of: #"\b[A-Z])"#, with: #"\b[A-Z]\.)"#) + #"\s+(?=[A-Z\[("“])"#)
    static func withoutHedgeSentences(_ text: String, cut: inout Int) -> String {
        let shield = shields(text), whole = text as NSString
        var pieces: [String] = [], at = 0
        for m in sentenceEnd.matches(in: text, range: NSRange(location: 0, length: whole.length)) where free(m.range, of: shield) {
            pieces.append(whole.substring(with: NSRange(location: at, length: m.range.upperBound - at))); at = m.range.upperBound
        }
        pieces.append(whole.substring(from: at))
        let kept = pieces.filter { s in !sentencePatterns.contains { $0.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil } }
        cut += pieces.count - kept.count
        return kept.count == pieces.count ? text : tidy(kept.joined())
    }
    static func unhedged(_ text: String, report: inout Report) -> String {
        var cut = 0
        var s = withoutHedgeSentences(text, cut: &cut)
        let ns = NSMutableString(string: s)
        for m in aside.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() where hedge(ns.substring(with: m.range(at: 1))) {
            ns.replaceCharacters(in: m.range, with: ""); cut += 1
        }
        s = ns as String
        let shield = shields(s), whole = s as NSString
        var clauses: [(text: String, sep: String)] = [], at = 0
        for m in clauseBreak.matches(in: s, range: NSRange(location: 0, length: whole.length)) where free(m.range, of: shield) {
            clauses.append((whole.substring(with: NSRange(location: at, length: m.range.location - at)), whole.substring(with: m.range))); at = m.range.upperBound
        }
        clauses.append((whole.substring(from: at), ""))
        let alive = clauses.indices.filter { !hedge(clauses[$0].text) }
        cut += clauses.count - alive.count
        guard cut > 0 else { return text }
        report.hedges += cut
        // between two kept clauses goes the break that led into the second, so "A, and hedge, but B" reads "A, but B"
        var out = ""
        for (n, i) in alive.enumerated() { out += (n == 0 ? "" : clauses[i - 1].sep) + clauses[i].text }
        out = tidy(out)
        if !out.isEmpty, let last = text.trimmingCharacters(in: .whitespaces).last, terminal.contains(last), !terminal.contains(out.last!) { out += "." }
        if alive.first != 0 { out = capitalized(out) }
        return out
    }
    /// Spacing and punctuation put right after a cut: doubled spaces, a space or a comma before a full stop, a break
    /// left dangling at the end.
    static func tidy(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s*[,;]?\s*\.(?=\s|$)"#, with: ".", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?:\s*[;,:—–])+\s*$"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }
    /// The first word with a capital, when it is a plain lower-case word (not "iPhone", not a link).
    static func capitalized(_ s: String) -> String {
        guard let first = s.first, first.isLowercase, let word = s.split(whereSeparator: { !$0.isLetter }).first, word.allSatisfy(\.isLowercase) else { return s }
        return first.uppercased() + s.dropFirst()
    }

    // MARK: filler

    /// A bullet that only says nothing happened or holds a place, matched whole, case-insensitively, its end
    /// punctuation off. "No pending request or unresolved obligation is established by this exchange.", "Nothing
    /// new.", "Standing facts about Kanika.", "No standing facts yet.", "TBD".
    static let fillerPatterns: [NSRegularExpression] = [
        #"^no (?:pending|open|new|outstanding|unresolved|further|other|remaining|specific|additional|explicit) (?:\w+ ){0,3}(?:requests?|actions?|items?|asks?|obligations?|tasks?|commitments?|plans?|facts?|updates?|changes?|details?|information|info)\b[^.,;:—–]*$"#,
        #"^no standing facts\b[^.,;:—–]*$"#,
        #"^standing facts(?: about\b[^.,;:—–]*)?$"#,
        #"^nothing(?: (?:new|else|further|more|pending|outstanding|open|recorded|noted|of|note|to|report|add|record|yet|here|so|far|this|time|in|exchange|from|her|him|them|their|his|side|since|was|is|has|happened|changed|then|last|the|update|updates))*$"#,
        #"^(?:tbd|tba|tbc|n/a|na|none|none yet|unknown|not known|no details|no details yet|no updates?|no updates? yet|no changes?|no news|no news yet|placeholder)$"#,
        #"^no (?:details|information|info|facts|updates?) (?:yet|available|recorded|known|so far)$"#,
    ].map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    static func filler(_ text: String) -> Bool {
        let core = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".!?…-–— "))
        guard core.contains(where: { $0.isLetter || $0.isNumber }) else { return true }
        let r = NSRange(core.startIndex..., in: core)
        return fillerPatterns.contains { $0.firstMatch(in: core, range: r) != nil }
    }

    // MARK: meta

    /// The brain talking about the note itself, at the head of a bullet, through the colon that may follow: what
    /// comes after the colon is kept when it names facts. Case-insensitive.
    static let metaPatterns: [NSRegularExpression] = [
        #"^earlier (?:\w+ ){0,4}(?:remains?|are|is) historical(?: unless noted above)?\s*(?::|\.?\s*$)"#,
        #"^(?:this|the) (?:note|section|list|record) (?:only |now )?(?:is|was|has|holds|keeps|covers|records|tracks|lists|carries)\b[^:]*(?::|$)"#,
        #"^(?:\w+ ){0,3}(?:contacts|members|people|threads|chats) (?:now )?have (?:their own |separate )notes?\b[^:]*(?::|$)"#,
        #"^references to\b[^:]*\bdo(?:es)? not (?:establish|create|imply)\b[^:]*(?::|$)"#,
        #"^(?:carried|moved|kept|folded|copied) (?:over |forward |in |on )?from\b[^:]*(?::|$)"#,
        #"^(?:historical|history|for the record|for reference)(?: only| note)?\s*(?::|\.?\s*$)"#,
        #"^(?:the )?(?:following|below|these) (?:items|facts|points|bullets|lines) (?:are|were) (?:carried|moved|kept|recorded|retained|folded)\b[^:]*(?::|$)"#,
    ].map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    /// Nil when the bullet opens with words of its own; else the facts after the meta head's colon, or nil inside when
    /// there are none worth a bullet (fewer than two content words).
    static func metaCut(_ text: String) -> String?? {
        let r = NSRange(text.startIndex..., in: text)
        for p in metaPatterns {
            guard let m = p.firstMatch(in: text, range: r), let end = Range(m.range, in: text) else { continue }
            let rest = text[end.upperBound...].trimmingCharacters(in: .whitespaces)
            return .some(words(rest).count >= 2 ? capitalized(rest) : nil)
        }
        return nil
    }

    // MARK: repeats

    /// The words that carry no fact of their own, left out when two bullets are compared.
    static let stopWords: Set<String> = ["a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "by", "from", "as", "is", "are", "was", "were", "be", "been", "being", "am", "has", "have", "had", "do", "does", "did", "it", "its", "this", "that", "these", "those", "he", "she", "they", "them", "him", "his", "her", "hers", "their", "theirs", "you", "your", "yours", "i", "me", "my", "we", "us", "our", "not", "no", "so", "if", "then", "than", "also", "about", "into", "up", "out", "over", "will", "would", "can", "could", "should", "may", "might", "must", "shall", "s", "t", "since", "date", "unclear", "yet", "still", "now", "just", "very", "more", "most", "some", "any", "all", "there", "here", "when", "where", "who", "whom", "which", "what", "while", "because", "until", "after", "before", "during", "again", "each", "own", "same", "too", "only", "off", "once", "under", "both", "either", "neither", "per", "via", "etc"]
    /// A bullet's content words: lower-cased, its dates and stop words out.
    static func words(_ text: String) -> Set<String> {
        let lower = text.lowercased()
        let ns = NSMutableString(string: lower)
        for f in NoteSkeleton.days(in: lower).reversed() { ns.replaceCharacters(in: f.range, with: " ") }
        return Set((ns as String).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && !stopWords.contains($0) })
    }
    /// How alike two bullets are by their words: the overlap over the union.
    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let u = a.union(b).count
        return u == 0 ? 0 : Double(a.intersection(b).count) / Double(u)
    }

    /// Two bullets that say the same thing — their content words overlapping by Jaccard 0.6 or more — are one fact:
    /// the one with the newer date stays, else the longer, in the higher of the two sections (Now over Context; About
    /// stays About whichever way the pair goes), and the other goes. A bullet with lines nested under it never goes
    /// (the other does, unless it holds lines too), and a bullet of fewer than three content words is too short to
    /// call a repeat by its words alone ("Lunch" on two days is two lunches).
    static func merge(_ p: inout NoteSkeleton.Parts, report: inout Report) {
        enum Section: Int { case about, now, context }
        struct Entry { var origin: (section: Section, index: Int); var slot: (section: Section, index: Int); var words: Set<String>; var day: String; var length: Int; var leaf: Bool }
        var entries: [Entry] = []
        for (i, it) in p.about.enumerated() where it.kind != .verbatim {
            entries.append(Entry(origin: (.about, i), slot: (.about, i), words: words(it.text), day: NoteSkeleton.ending(it.text)?.day ?? "", length: it.text.count, leaf: it.nested.isEmpty))
        }
        for (section, bs) in [(Section.now, p.now), (.context, p.context)] {
            for (i, b) in bs.enumerated() where !b.verbatim { entries.append(Entry(origin: (section, i), slot: (section, i), words: words(b.text), day: b.day ?? "", length: b.text.count, leaf: b.nested.isEmpty)) }
        }
        var gone = [Bool](repeating: false, count: entries.count)
        for i in entries.indices where !gone[i] {
            for j in entries.indices where j > i && !gone[j] && !gone[i] {
                let a = entries[i], b = entries[j]
                guard min(a.words.count, b.words.count) >= 3, jaccard(a.words, b.words) >= 0.6 else { continue }
                let aStays = a.day != b.day ? a.day > b.day : a.length >= b.length
                var (stay, go) = aStays ? (i, j) : (j, i)
                if !entries[go].leaf { (stay, go) = (go, stay) }
                guard entries[go].leaf else { continue }
                gone[go] = true; report.merged += 1
                // Context's survivor over Now's copy takes the copy's place under Now; About never moves either way
                if entries[stay].slot.section == .context, entries[go].slot.section == .now { entries[stay].slot = entries[go].slot }
            }
        }
        guard report.merged > 0 else { return }
        func bullet(_ o: (section: Section, index: Int)) -> NoteSkeleton.Bullet { o.section == .now ? p.now[o.index] : p.context[o.index] }
        func kept(_ section: Section, _ bs: [NoteSkeleton.Bullet]) -> [NoteSkeleton.Bullet] {
            bs.indices.compactMap { i in
                if bs[i].verbatim { return bs[i] }
                guard let k = entries.indices.first(where: { !gone[$0] && entries[$0].slot.section == section && entries[$0].slot.index == i }) else { return nil }
                return bullet(entries[k].origin)
            }
        }
        let now = kept(.now, p.now), context = kept(.context, p.context)
        p.about = p.about.indices.compactMap { i in
            p.about[i].kind == .verbatim || entries.indices.contains { !gone[$0] && entries[$0].origin.section == .about && entries[$0].origin.index == i } ? p.about[i] : nil
        }
        p.now = now; p.context = context
    }
}
