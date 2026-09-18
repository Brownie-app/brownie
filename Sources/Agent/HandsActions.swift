import Foundation

// The rules behind Hands' actions, kept pure so every one of them is tested: how a screenshot point becomes a
// screen point, how a press is carried out and judged, which of several matches is the one to press, which text
// box a label means, and how a run is summed up. The AX calls that feed them stay thin, in AXSession.

/// Where the last screenshot sat on the screen. The model answers in image pixels; a click has to land in screen
/// points, which differ by the window's origin and by the capture scale (2× on Retina, then downsized to fit).
public struct ScreenMap: Sendable, Equatable {
    /// The window's bounds in screen points (top-left origin, the space CGEvent clicks and AX frames use).
    public let windowBounds: CGRect
    /// The size, in pixels, of the image the model was shown.
    public let imageSize: CGSize
    public init(windowBounds: CGRect, imageSize: CGSize) { self.windowBounds = windowBounds; self.imageSize = imageSize }

    /// An image point → the screen point under it.
    public func toScreen(_ p: CGPoint) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0 else { return p }
        return CGPoint(x: windowBounds.minX + p.x * windowBounds.width / imageSize.width,
                       y: windowBounds.minY + p.y * windowBounds.height / imageSize.height)
    }
    /// True when an image point is inside the image, so the mapped click lands in the window at all.
    public func covers(_ p: CGPoint) -> Bool { p.x >= 0 && p.y >= 0 && p.x <= imageSize.width && p.y <= imageSize.height }
    /// What the model is told next to the picture.
    public var note: String { "Screenshot of the window, \(Int(imageSize.width))×\(Int(imageSize.height)). Give click coordinates in this image." }
}

/// A cheap fingerprint of what is on screen: the window's title, what has keyboard focus, and the words of the
/// element sitting at one point of interest. Two of these, before and after an action, say whether anything happened.
public struct ScreenSignature: Sendable, Equatable {
    public var window: String
    /// "Role “title”" of the focused element, or "" when nothing has focus.
    public var focus: String
    /// The words (role + title/value) of the element at the probed point, or nil when no point was probed.
    public var atPoint: String?
    public init(window: String, focus: String = "", atPoint: String? = nil) { self.window = window; self.focus = focus; self.atPoint = atPoint }

    /// Plain-words lines for what differs from `before`; empty when nothing does.
    public func changes(since before: ScreenSignature) -> [String] {
        var out: [String] = []
        if window != before.window { out.append("the window is now “\(window.prefix(70))”") }
        if focus != before.focus { out.append(focus.isEmpty ? "nothing has focus now" : "focus is now \(focus.prefix(60))") }
        if let a = atPoint, let b = before.atPoint, a != b { out.append(a.isEmpty ? "what was there is gone" : "what sits there is now \(a.prefix(60))") }
        return out
    }
    public var line: String { "window “\(window.prefix(70))”" + (focus.isEmpty ? "" : " · focus \(focus.prefix(50))") }
}

/// How a numbered element gets pressed. AXPress when the element is there and answers; otherwise a real click on the
/// middle of the frame it had when it was numbered — a web page wants a click anyway — as long as that frame is on
/// the window. `axPress` is nil when there is nothing to press (no element, or no Press action), else AXPress's verdict.
public enum PressPlan: Sendable, Equatable {
    case pressed
    case click(CGPoint)
    case cannot(String)

    public static func decide(axPress: Bool?, frame: CGRect, window: CGRect?) -> PressPlan {
        if axPress == true { return .pressed }
        guard frame.width > 0, frame.height > 0 else { return .cannot(axPress == false ? "the press was refused and where it sits is unknown; find it again" : "it isn't on screen any more; find it again") }
        let mid = CGPoint(x: frame.midX, y: frame.midY)
        if let window, window.width > 0, window.height > 0, !window.contains(mid) { return .cannot("it sits at (\(Int(mid.x)), \(Int(mid.y))), outside the window — scroll it into view and find it again") }
        return .click(mid)
    }
}

/// The line the model reads after a press: what was done, to which element, and what changed — so the next step
/// is chosen from evidence, not hope. "nothing changed" is the exact phrase the stall guard counts.
public enum PressOutcome {
    public enum How: Sendable { case pressed, clicked }
    public static func report(label: String, role: String, title: String, how: How, before: ScreenSignature, after: ScreenSignature) -> String {
        let what = "\(label) \(role) “\(title.prefix(70))”"
        let diff = after.changes(since: before)
        switch how {
        case .pressed:
            return diff.isEmpty ? "pressed \(what) but nothing changed — it may need scrolling into view, or it is not the thing to press; try press_text with different words or look"
                : "pressed \(what) → \(diff.joined(separator: "; "))"
        case .clicked:
            return diff.isEmpty ? "clicked the middle of \(what) but nothing changed — it may need scrolling into view, or it is not the thing to press; try press_text with different words or look"
                : "clicked the middle of \(what) — the page changed (\(diff.joined(separator: "; ")))"
        }
    }
}

/// Which of several matches is the one to press: an exact title first, then the ones that carry the whole phrase, then
/// links, buttons and fields over plain text, then the shortest title, then top-to-bottom. `nth` picks further down.
public enum PressPick {
    public enum Role: String, Sendable { case link, button, field, any }
    static let pressable: Set<String> = ["Link", "Button", "MenuItem", "CheckBox", "RadioButton", "PopUpButton", "TextField", "TextArea", "SearchField", "ComboBox"]
    static let roleSets: [Role: Set<String>] = [.link: ["Link"], .button: ["Button", "MenuItem", "CheckBox", "RadioButton", "PopUpButton"], .field: ["TextField", "TextArea", "SearchField", "ComboBox"]]

    static func tier(_ role: String) -> Int {
        if pressable.contains(role) { return 0 }
        switch role { case "Row", "Cell": return 1; case "Heading", "StaticText", "Image": return 2; default: return 3 }
    }
    /// 0 exact title, 1 the whole phrase inside the title or value, 2 every word somewhere, 3 anything else.
    static func match(_ e: UISnapshot.Element, _ q: String) -> Int {
        let t = StepMatch.norm(e.title), v = StepMatch.norm(e.value)
        if t == q { return 0 }
        if t.contains(q) || v.contains(q) { return 1 }
        let words = q.split(separator: " ").map(String.init)
        if !words.isEmpty, words.allSatisfy({ t.contains($0) || v.contains($0) }) { return 2 }
        return 3
    }
    public static func fits(_ e: UISnapshot.Element, _ role: Role) -> Bool { role == .any || (roleSets[role]?.contains(e.role) ?? true) }

    /// Best first. Elements of the wrong role are left out entirely.
    public static func rank(hits: [UISnapshot.Element], text: String, role: Role = .any) -> [UISnapshot.Element] {
        let q = StepMatch.norm(text)
        return hits.filter { fits($0, role) }.sorted { a, b in
            let ka = (match(a, q), tier(a.role), a.title.count, a.frame.minY, a.frame.minX), kb = (match(b, q), tier(b.role), b.title.count, b.frame.minY, b.frame.minX)
            return ka < kb
        }
    }
    public static func choose(hits: [UISnapshot.Element], text: String, nth: Int = 1, role: Role = .any) -> UISnapshot.Element? {
        let r = rank(hits: hits, text: text, role: role)
        let i = max(1, nth) - 1
        return i < r.count ? r[i] : nil
    }
    /// "[12] Link “Apple iPhone 17…”" lines for a handful of candidates.
    public static func list(_ es: some Sequence<UISnapshot.Element>) -> String {
        es.map { "[\($0.id)] \($0.role) “\($0.title.prefix(70))”" + ($0.value.isEmpty ? "" : " = \($0.value.prefix(40))") }.joined(separator: "\n")
    }
}

/// Which text box a label means: a field whose title (Chrome folds the placeholder into it) or value says the words —
/// exact title first, then the shortest, then the topmost. `relaxed` also takes a field that shares one word with the
/// label, or the only field there is.
public enum FieldPick {
    public static let roles: Set<String> = ["TextField", "TextArea", "SearchField", "ComboBox"]
    public static func choose(hits: [UISnapshot.Element], label: String, relaxed: Bool = false) -> UISnapshot.Element? {
        let q = StepMatch.norm(label)
        let fields = hits.filter { roles.contains($0.role) }
        let words = q.split(separator: " ").map(String.init).filter { $0.count > 2 }
        func score(_ e: UISnapshot.Element) -> Int? {
            let t = StepMatch.norm(e.title), v = StepMatch.norm(e.value)
            if t == q { return 0 }
            if !q.isEmpty, t.contains(q) || v.contains(q) { return 1 }
            if relaxed, words.contains(where: { t.contains($0) }) { return 2 }
            return nil
        }
        let scored = fields.compactMap { e in score(e).map { ($0, e) } }
        if let best = scored.min(by: { ($0.0, $0.1.title.count, $0.1.frame.minY) < ($1.0, $1.1.title.count, $1.1.frame.minY) }) { return best.1 }
        return relaxed && fields.count == 1 ? fields[0] : nil
    }
}

/// One line at the end of a run for the log: turns, which tools and how often, how it ended.
public struct HandsRunSummary: Sendable {
    public private(set) var counts: [String: Int] = [:]
    public private(set) var calls = 0
    public init() {}
    public mutating func record(_ tool: String) { counts[tool, default: 0] += 1; calls += 1 }
    public func line(turns: Int?, outcome: String) -> String {
        let tools = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
        return "run over: \(turns.map { "\($0) turns" } ?? "turns unknown"), \(calls) tool calls" + (tools.isEmpty ? "" : " (\(tools))") + " · outcome \(outcome)"
    }
}
