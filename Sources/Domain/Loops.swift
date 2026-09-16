import Foundation

/// Which way a promise points. `mine`: the user said they'd do something. `theirs`: someone
/// said they'd do something for the user.
public enum LoopDirection: String, Codable, Sendable { case mine, theirs }
/// `lapsed`: open for 90 days with nothing happening — let go, kept only so it is never found again as new.
public enum LoopStatus: String, Codable, Sendable {
    case open, closed, dismissed, lapsed
    /// A status this build does not know (a ledger written by a newer Brownie) reads as closed: better to stop
    /// tracking a loop than to nag about one, and the whole ledger must never fail to load over one word.
    public init(from decoder: any Decoder) throws {
        self = LoopStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .closed
    }
}

/// A commitment found in the user's messages, tracked until the next read sees it done.
/// The ledger of these is what the Loops screen shows.
public struct Loop: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let direction: LoopDirection
    public let person: String
    public let what: String
    /// The line that opened it, as the reader summarised it — never the raw message.
    public let quote: String
    /// "WhatsApp · Fri" — where and when it was said.
    public let sourceLabel: String
    public let due: String?
    /// The real date behind `due`, when the judge could name one (from `dueISO`).
    public var dueDate: Date?
    /// True once a due-aware card was made for this loop, so it isn't made twice.
    public var nudgedForDue: Bool?
    public var status: LoopStatus
    public let openedAt: Date
    /// When Brownie first learned of it — the night it was found, whereas `openedAt` is when it was said. A promise
    /// from an old recording read late is dated by the recording but counts as news from here, so it is not let go
    /// the night it is found. Absent in ledgers written before the field existed: then `openedAt` stands in.
    public var noticedAt: Date?
    public var closedAt: Date?
    public var closedHow: String?
    /// What closed it: "reply" (the user's own message), "judge", "user" (the Loops screen), "lapsed", or
    /// "household:<member id>" when another member's Brownie closed it (older ledgers hold a bare "household").
    public var closedBy: String?
    /// When it was let go for want of news; `closedAt` is set to the same moment.
    public var lapsedAt: Date?
    /// Card ids fired for this loop; a fired card with the loop still open at the next read comes back.
    public var firedCardIDs: [String]
    public var cameBackCount: Int
    /// Household loops: who is on it — "me", a member's first name, or "either". Nil for the user's own loops.
    public var owner: String?

    public init(id: String = UUID().uuidString, direction: LoopDirection, person: String, what: String, quote: String, sourceLabel: String,
                due: String?, dueDate: Date? = nil, status: LoopStatus = .open, openedAt: Date, noticedAt: Date? = nil, closedAt: Date? = nil, closedHow: String? = nil,
                closedBy: String? = nil, lapsedAt: Date? = nil, firedCardIDs: [String] = [], cameBackCount: Int = 0) {
        self.id = id; self.direction = direction; self.person = person; self.what = what; self.quote = quote; self.sourceLabel = sourceLabel
        self.due = due; self.dueDate = dueDate; self.status = status; self.openedAt = openedAt; self.noticedAt = noticedAt; self.closedAt = closedAt; self.closedHow = closedHow
        self.closedBy = closedBy; self.lapsedAt = lapsedAt; self.firedCardIDs = firedCardIDs; self.cameBackCount = cameBackCount
    }

    /// One line for the judge: what it already knows is open, so it reports closures instead of re-finding them.
    public var judgeLine: String {
        "loop \(id.prefix(8)) · \(direction == .mine ? "the user → \(person)" : "\(person) → the user") · \(what) · said \(sourceLabel)\(due.map { " · due \($0)" } ?? "")\(firedCardIDs.isEmpty ? "" : " · the user already sent a message about this (card fired)")"
    }
}

/// Every request that left the Mac for the brain, byte for byte. What "What left your Mac" shows.
public struct SendRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: Int64
    public let at: Date
    /// "Judge what matters", "Prepare the cards", "Update your notes", "Pre-meeting brief", …
    public let purpose: String
    public let model: String
    public let bytes: Int
    /// One line about what was inside: "24 summaries, the calendar for 2 days, 9 note titles".
    public let detail: String
    /// One line about what came back: "8 candidates".
    public var cameBack: String
    /// The exact text sent (system + input, and tool results for an agent loop), capped.
    public let payload: String
    public init(id: Int64, at: Date, purpose: String, model: String, bytes: Int, detail: String, cameBack: String, payload: String) {
        self.id = id; self.at = at; self.purpose = purpose; self.model = model; self.bytes = bytes; self.detail = detail; self.cameBack = cameBack; self.payload = payload
    }
}

/// Something the user taught Hands by doing it once. Steps are what the accessibility tree saw;
/// parameters are the parts that change each run.
public struct TaughtRecipe: Codable, Sendable, Identifiable, Equatable {
    public struct Step: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case launch, click, type, key }
        public let kind: Kind
        public let app: String
        /// For click: the element's role and title ("Row “Rohan”"). For type: the field's title. For key: the combo.
        public let target: String
        public let role: String
        /// For type: the text typed. May be replaced by a parameter.
        public var text: String
        /// Where the element sat in its window, as fractions (0–1) of the window's width and height — survives resizes.
        public var fx: Double?
        public var fy: Double?
        /// Words near the element (its own text, or the text of the link/row around it) — how an unlabelled "Group" is told apart.
        public var context: String?
        /// For a browser: the page's address when the step was recorded, so replay can go straight there.
        public var url: String?
        public init(kind: Kind, app: String, target: String, role: String = "", text: String = "", fx: Double? = nil, fy: Double? = nil, context: String? = nil, url: String? = nil) {
            self.kind = kind; self.app = app; self.target = target; self.role = role; self.text = text; self.fx = fx; self.fy = fy; self.context = context; self.url = url
        }
        /// A step whose label says nothing ("Group", "text field") — only its place and context can find it again.
        public var isUnlabelled: Bool { let t = target.lowercased(); return t.isEmpty || t == role.lowercased() || ["group", "text field", "?", "webarea", "image"].contains(t) }
    }
    public struct Parameter: Codable, Sendable, Identifiable, Equatable {
        public enum Fill: String, Codable, Sendable { case fixed, ask, fromNotes }
        public let id: String
        public let name: String       // "person", "message"
        public let original: String   // what the user did the first time
        public var fill: Fill
        public init(id: String = UUID().uuidString, name: String, original: String, fill: Fill = .fixed) { self.id = id; self.name = name; self.original = original; self.fill = fill }
    }
    public enum Schedule: Codable, Sendable, Equatable {
        case onDemand
        case weekly(weekday: Int, hour: Int, minute: Int)   // weekday 1 = Sunday
        /// When a file matching `pattern` (glob, case-insensitive) appears in `folder`. The path fills the `file` parameter.
        case folder(path: String, pattern: String)
        public var line: String {
            switch self {
            case .onDemand: return "When you ask"
            case .weekly(let d, let h, let m):
                let day = Calendar.current.weekdaySymbols[max(0, min(6, d - 1))]
                return "Every " + day + ", " + String(h) + ":" + String(format: "%02d", m)
            case .folder(let p, let pat): return "When " + pat + " arrives in " + (p as NSString).abbreviatingWithTildeInPath
            }
        }
        public var isTrigger: Bool { if case .folder = self { return true }; return false }
    }
    public let id: String
    public var name: String
    public var steps: [Step]
    public var parameters: [Parameter]
    public var schedule: Schedule
    public let createdAt: Date
    public var runs: Int
    public var lastRunAt: Date?

    public init(id: String = UUID().uuidString, name: String, steps: [Step], parameters: [Parameter], schedule: Schedule = .onDemand, createdAt: Date, runs: Int = 0, lastRunAt: Date? = nil) {
        self.id = id; self.name = name; self.steps = steps; self.parameters = parameters; self.schedule = schedule; self.createdAt = createdAt; self.runs = runs; self.lastRunAt = lastRunAt
    }

    /// The most reliable way in for the apps this recipe touches — app link first, the screen last.
    public var method: String {
        let apps = Set(steps.map(\.app))
        if apps.count == 1, let a = apps.first {
            if a == "WhatsApp", steps.contains(where: { $0.kind == .type && !$0.target.lowercased().contains("search") }) { return "WhatsApp link" }   // falls back to the tree when Contacts has no number
            if a == "Messages" || a == "Mail" || a == "Finder" || a == "Notes" || a == "Calendar" { return "AppleScript" }
        }
        return "Screen"
    }
    public var appsLine: String { Array(Set(steps.map(\.app))).sorted().joined(separator: ", ") }
}

/// A brief for a meeting, written ten minutes before it from the People notes and open loops.
public struct Brief: Codable, Sendable, Identifiable, Equatable {
    public let id: String            // the calendar event identifier
    public let title: String
    public let startsAt: Date
    public let attendees: [String]
    public let text: String          // Markdown
    public let loops: [Loop]
    public let createdAt: Date
    public init(id: String, title: String, startsAt: Date, attendees: [String], text: String, loops: [Loop], createdAt: Date) {
        self.id = id; self.title = title; self.startsAt = startsAt; self.attendees = attendees; self.text = text; self.loops = loops; self.createdAt = createdAt
    }
}
