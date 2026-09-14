import Foundation

public enum Urgency: String, Codable, Sendable, Comparable {
    case low, medium, high
    public static func < (a: Urgency, b: Urgency) -> Bool { a.rank < b.rank }
    private var rank: Int { switch self { case .low: return 0; case .medium: return 1; case .high: return 2 } }
}

/// Part 1 output: found and ranked, not verified.
public struct ActionItem: Codable, Sendable, Equatable {
    public let title: String
    public let action: String
    public let importance: String
    public let dueDate: String?
    public let sources: [String]
    public let urgency: Urgency
    public init(title: String, action: String, importance: String, dueDate: String?, sources: [String], urgency: Urgency) {
        self.title = title; self.action = action; self.importance = importance; self.dueDate = dueDate; self.sources = sources; self.urgency = urgency
    }
}

public struct Evidence: Codable, Sendable, Equatable {
    public let source: String
    public let when: String
    public let text: String
    public init(source: String, when: String, text: String) { self.source = source; self.when = when; self.text = text }
}

/// Routing only. The executor runs it; it never contains anything the user hasn't seen as the draft.
public enum Recipe: Codable, Sendable, Equatable {
    case imessage(to: String, body: String, attachments: [String])
    case whatsapp(chat: String, body: String, phone: String? = nil)
    case mail(to: String, subject: String, body: String, attachments: [String])
    case calendar(title: String, startISO: String, endISO: String, notes: String)
    case note(relativePath: String, body: String)
    case browser(url: String)
    case computerUse(goal: String)

    public var channelName: String {
        switch self {
        case .imessage: return "iMessage"
        case .whatsapp: return "WhatsApp"
        case .mail: return "Mail"
        case .calendar: return "Calendar"
        case .note: return "Notes"
        case .browser: return "Browser"
        case .computerUse: return "Hands"
        }
    }
    /// Plain-words steps shown on the card before firing.
    public var stepsInWords: [String] {
        switch self {
        case .imessage(let to, _, let att):
            return ["Open Messages to \(to)"] + (att.isEmpty ? [] : ["Attach \(att.joined(separator: ", "))"]) + ["Paste the draft and stop at Send — you press it"]
        case .whatsapp(let chat, _, _): return ["Open the WhatsApp chat with \(chat)", "Paste the draft into the message field", "Stop and show you the Send button — you press it"]
        case .mail(let to, _, _, let att): return ["Compose an email to \(to)"] + (att.isEmpty ? [] : ["Attach \(att.joined(separator: ", "))"]) + ["Stop at Send"]
        case .calendar(let title, _, _, _): return ["Open a new event “\(title)” with the details filled in", "Stop at Save"]
        case .note(let path, _): return ["Create the note \(path) in your knowledge base", "Open it"]
        case .browser(let url): return ["Open \(url) in your browser"]
        case .computerUse(let goal): return ["Hands: \(goal)", "Pause before anything irreversible"]
        }
    }
}

public enum CardState: String, Codable, Sendable { case ready, fired, dismissed, snoozed, expired }
public enum Verification: String, Codable, Sendable { case verified, unverified }

/// Part 2 output: verified and staged. What the For You screen shows.
public struct Card: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let sourceLabel: String
    public let why: String
    public let actionLabel: String
    public let dueLine: String
    public let urgency: Urgency
    public let draftLabel: String
    public let draft: String
    public let recipe: Recipe
    public let evidence: [Evidence]
    public let verification: Verification
    public let verifiedLine: String
    public var state: CardState
    public let createdAt: Date
    public var snoozedUntil: Date?
    public var resolvedAt: Date?

    public init(id: String, title: String, sourceLabel: String, why: String, actionLabel: String, dueLine: String,
                urgency: Urgency, draftLabel: String, draft: String, recipe: Recipe, evidence: [Evidence],
                verification: Verification, verifiedLine: String, state: CardState = .ready, createdAt: Date) {
        self.id = id; self.title = title; self.sourceLabel = sourceLabel; self.why = why; self.actionLabel = actionLabel
        self.dueLine = dueLine; self.urgency = urgency; self.draftLabel = draftLabel; self.draft = draft; self.recipe = recipe
        self.evidence = evidence; self.verification = verification; self.verifiedLine = verifiedLine; self.state = state; self.createdAt = createdAt
    }

    /// Ready cards expire two mornings after they were made; snoozed ones come back when due.
    public static let lifetime: TimeInterval = 2 * 86400
    public func housekept(now: Date) -> Card {
        var c = self
        if c.state == .snoozed, let u = c.snoozedUntil, u <= now { c.state = .ready; c.snoozedUntil = nil }
        if c.state == .ready, now.timeIntervalSince(c.createdAt) > Card.lifetime { c.state = .expired; c.resolvedAt = now }
        return c
    }
    /// A copy with a new draft; the recipe's body follows so what you edited is what gets sent.
    public func withDraft(_ text: String) -> Card {
        let r: Recipe
        switch recipe {
        case .imessage(let to, _, let att): r = .imessage(to: to, body: text, attachments: att)
        case .whatsapp(let chat, _, let phone): r = .whatsapp(chat: chat, body: text, phone: phone)
        case .mail(let to, let subject, _, let att): r = .mail(to: to, subject: subject, body: text, attachments: att)
        case .calendar(let t, let a, let b, _): r = .calendar(title: t, startISO: a, endISO: b, notes: text)
        case .note(let path, _): r = .note(relativePath: path, body: text)
        case .browser, .computerUse: r = recipe
        }
        return Card(id: id, title: title, sourceLabel: sourceLabel, why: why, actionLabel: actionLabel, dueLine: dueLine, urgency: urgency,
                    draftLabel: draftLabel, draft: text, recipe: r, evidence: evidence, verification: verification, verifiedLine: verifiedLine, state: state, createdAt: createdAt)
    }

    public var fireLabel: String {
        switch recipe {
        case .imessage(let to, _, _): return "Send to \(to)"
        case .whatsapp(let chat, _, _): return "Send to \(chat)"
        case .mail(let to, _, _, _): return "Email \(to)"
        case .calendar: return "Add to Calendar"
        case .note: return "Open the brief"
        case .browser: return "Open in browser"
        case .computerUse: return "Let Hands do it"
        }
    }
}

public enum FireEvent: Sendable, Equatable {
    case step(String, done: Bool)
    case pausedForUser(String)
    case finished(FireOutcome)
}
public enum FireOutcome: String, Codable, Sendable { case done, pausedAtUserStep, stopped, couldNot }

public protocol CardExecutor: Sendable {
    func fire(_ card: Card, onEvent: @escaping @Sendable (FireEvent) -> Void) async throws -> FireOutcome
}
