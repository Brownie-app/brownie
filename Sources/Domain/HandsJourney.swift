import Foundation

/// What Hands is doing, as a person would tell it: a short plan in their words, the step it is on,
/// and the last thing it did under that step. Pure, so the shape is tested; fed by tool events.
public struct HandsJourney: Sendable, Equatable, Codable {
    public enum State: String, Sendable, Codable { case pending, current, done, skipped }
    public struct Step: Sendable, Equatable, Codable, Identifiable {
        public var id: Int { index }
        public let index: Int
        public let title: String
        public var state: State
        public var note: String?
        /// The narrated actions taken under this step, newest last (kept short).
        public var actions: [String]
        public init(index: Int, title: String, state: State = .pending, note: String? = nil, actions: [String] = []) { self.index = index; self.title = title; self.state = state; self.note = note; self.actions = actions }
    }
    public var steps: [Step] = []
    /// Actions narrated before any plan existed (or after the last step closed).
    public var loose: [String] = []
    public static let maxActionsPerStep = 6

    public init() {}

    public var hasPlan: Bool { !steps.isEmpty }
    public var current: Step? { steps.first { $0.state == .current } }
    public var doneCount: Int { steps.filter { $0.state == .done || $0.state == .skipped }.count }
    /// "Step 2 of 5 · Go to amazon.com" — the headline while working; nil without a plan.
    public var progressLine: String? {
        guard let c = current else { return steps.isEmpty ? nil : (doneCount == steps.count ? "All \(steps.count) steps done" : nil) }
        return "Step \(c.index + 1) of \(steps.count) · \(c.title)"
    }
    /// The most recent narrated action, wherever it landed.
    public var lastAction: String? { current?.actions.last ?? steps.last(where: { !$0.actions.isEmpty })?.actions.last ?? loose.last }

    /// 2–6 non-empty, distinct lines; anything else is not a plan.
    public static func validate(_ raw: [String]) -> [String]? {
        var seen = Set<String>(), out: [String] = []
        for r in raw {
            let t = r.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".-•0123456789) ")).trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
            out.append(String(t.prefix(90)))
        }
        return (2...6).contains(out.count) ? out : nil
    }

    public mutating func setPlan(_ titles: [String]) {
        steps = titles.enumerated().map { Step(index: $0.offset, title: $0.element, state: $0.offset == 0 ? .current : .pending) }
    }
    /// Closes step `index` (1-based as the brain counts) and opens the next pending one. Out-of-range numbers are ignored.
    public mutating func stepDone(_ number: Int, note: String? = nil, skipped: Bool = false) {
        let i = number - 1
        guard steps.indices.contains(i) else { return }
        for j in 0...i where steps[j].state != .done && steps[j].state != .skipped { steps[j].state = (j == i && skipped) ? .skipped : .done }
        if let note, !note.isEmpty { steps[i].note = note }
        if let next = steps.firstIndex(where: { $0.state == .pending }) { steps[next].state = .current }
    }
    public mutating func add(_ line: String) {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines); guard !t.isEmpty else { return }
        if let c = steps.firstIndex(where: { $0.state == .current }) {
            steps[c].actions.append(t); if steps[c].actions.count > Self.maxActionsPerStep { steps[c].actions.removeFirst() }
        } else { loose.append(t); if loose.count > Self.maxActionsPerStep { loose.removeFirst() } }
    }

    /// The journey a firing's event stream describes.
    public static func fold(_ events: [FireEvent]) -> HandsJourney {
        var j = HandsJourney()
        for e in events {
            switch e {
            case .plan(let s): j.setPlan(s)
            case .stepDone(let n, let note): j.stepDone(n, note: note)
            case .step(let s, _): j.add(s)
            case .pausedForUser(let s): j.add(s)
            case .finished: break
            }
        }
        return j
    }
}
