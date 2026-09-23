import Foundation

/// A thumbs-down on a card, with one reason. Brownie folds these into the next night's instructions,
/// so it gets better for this person without a model update.
public struct CardFeedback: Codable, Sendable, Equatable, Identifiable {
    public enum Verdict: String, Codable, Sendable, CaseIterable {
        case notMine, alreadyDone, tooFormal, wrongPerson, notImportant, wrongTiming, other
        /// The words on the menu.
        public var label: String {
            switch self {
            case .notMine: return "Not mine"
            case .alreadyDone: return "Already done"
            case .tooFormal: return "Too formal"
            case .wrongPerson: return "Wrong person"
            case .notImportant: return "Not important"
            case .wrongTiming: return "Not the right time"
            case .other: return "Something else…"
            }
        }
    }
    public let id: String
    public let cardID: String
    public let cardTitle: String
    /// Who the card was about — the chat, the recipient — when the recipe names one.
    public let person: String?
    public let sourceLabel: String
    public let verdict: Verdict
    public let note: String
    public let at: Date
    public init(id: String = UUID().uuidString, cardID: String, cardTitle: String, person: String?, sourceLabel: String, verdict: Verdict, note: String = "", at: Date) {
        self.id = id; self.cardID = cardID; self.cardTitle = cardTitle; self.person = person; self.sourceLabel = sourceLabel; self.verdict = verdict; self.note = note; self.at = at
    }
}

public extension Card {
    /// The person a card is addressed to, from its recipe.
    var person: String? {
        switch recipe {
        case .whatsapp(let chat, _, _): return chat
        case .imessage(let to, _, _): return to
        case .mail(let to, _, _, _): return to
        default: return nil
        }
    }
}
