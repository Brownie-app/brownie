import Foundation
import AppKit
import ApplicationServices

/// A compact, numbered snapshot of the frontmost app's UI via the Accessibility API. Elements get
/// stable ids for one snapshot so the brain can say "press 14".
public struct UISnapshot: Sendable {
    public struct Element: Sendable, Equatable {
        public let id: Int
        public let role: String
        public let title: String
        public let value: String
        public let frame: CGRect
        public let actions: [String]
        public let depth: Int
    }
    public let app: String
    public let window: String
    public let elements: [Element]

    /// Elements whose label, value or role mentions the words — how Hands finds "Add to Cart" without reading the whole tree.
    public func matching(_ query: String) -> [Element] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return elements.filter { $0.title.lowercased().contains(q) || $0.value.lowercased().contains(q) || $0.role.lowercased() == q }
    }
    public func contains(_ query: String) -> Bool { window.lowercased().contains(query.lowercased()) || !matching(query).isEmpty }

    public var text: String {
        var out = "App: \(app) · Window: \(window)\n"
        for e in elements {
            let indent = String(repeating: "  ", count: min(e.depth, 8))
            var line = "\(indent)[\(e.id)] \(e.role)"
            if !e.title.isEmpty { line += " “\(e.title)”" }
            if !e.value.isEmpty { line += " = \(e.value.prefix(80))" }
            if !e.actions.isEmpty { line += " (\(e.actions.joined(separator: ",")))" }
            out += line + "\n"
        }
        return out
    }
}

/// Not Sendable by design — lives on one actor.
public final class AXSession {
    private var refs: [Int: AXUIElement] = [:]
    /// What each id looked like when it was numbered, so a stale reference (Chrome rebuilds its tree constantly) can be found again.
    private var descs: [Int: UISnapshot.Element] = [:]
    /// Where the last screenshot sat, so a click given in image pixels lands on the screen.
    public var screenMap: ScreenMap?

    public init() {}
    private var enhanced = Set<pid_t>()
    public func snapshot(maxElements: Int = 400) -> UISnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Chrome, Electron and Catalyst apps only expose their web content once an assistive client asks for it.
        if !enhanced.contains(app.processIdentifier) {
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            enhanced.insert(app.processIdentifier)
        }
        var winRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef)
        let root: AXUIElement = (winRef as! AXUIElement?) ?? axApp
        refs.removeAll(); descs.removeAll()
        var elements: [UISnapshot.Element] = []
        var next = 1
        // Breadth-first: toolbars, address bars and buttons sit near the top of the tree; a web page's thousand
        // nodes sit deep. Depth-first would spend the whole cap inside the page and never number the toolbar.
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var head = 0
        while head < queue.count, elements.count < maxElements {
            let (el, depth) = queue[head]; head += 1
            guard depth < 14 else { continue }
            let role = attr(el, kAXRoleAttribute) as? String ?? "?"
            let title = (attr(el, kAXTitleAttribute) as? String) ?? (attr(el, kAXDescriptionAttribute) as? String) ?? (attr(el, kAXPlaceholderValueAttribute) as? String) ?? ""
            var value = ""
            if let v = attr(el, kAXValueAttribute) { value = (v as? String) ?? ((v as? NSNumber).map { $0.stringValue } ?? "") }
            var actionsRef: CFArray?
            AXUIElementCopyActionNames(el, &actionsRef)
            let actions = ((actionsRef as? [String]) ?? []).map { $0.replacingOccurrences(of: "AX", with: "") }
            let interesting = !actions.isEmpty || !title.isEmpty || !value.isEmpty || ["AXTextField", "AXTextArea", "AXButton", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXLink", "AXStaticText", "AXRow", "AXCell"].contains(role)
            if interesting, role != "AXGroup" || !title.isEmpty {
                let id = next; next += 1
                refs[id] = el
                let e = UISnapshot.Element(id: id, role: String(role.dropFirst(2)), title: title, value: value, frame: frame(el), actions: actions, depth: depth)
                descs[id] = e
                elements.append(e)
            }
            if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] { for k in kids { queue.append((k, depth + 1)) } }
        }
        return UISnapshot(app: app.localizedName ?? "?", window: attr(root, kAXTitleAttribute) as? String ?? "", elements: elements)
    }

    /// Every element in the window whose label, value or role says these words — the whole tree, not the numbered cap.
    /// A web page has thousands of nodes; the product links Hands wants are deep. Matches are numbered on top of the current snapshot.
    public func search(_ query: String, limit: Int = 12, maxNodes: Int = 20000, budget: TimeInterval = 4) -> [UISnapshot.Element] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let app = NSWorkspace.shared.frontmostApplication else { return [] }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef)
        let root: AXUIElement = (winRef as! AXUIElement?) ?? axApp
        var out: [UISnapshot.Element] = []
        var taken: [AXUIElement] = []
        var next = (refs.keys.max() ?? 0) + 1
        // each queued node remembers the nearest link/button above it: a product's title is plain text, the thing to press is the link around it
        var queue: [(AXUIElement, Int, AXUIElement?)] = [(root, 0, nil)]
        var head = 0, seen = 0
        let started = Date()
        while head < queue.count, seen < maxNodes, out.count < limit, Date().timeIntervalSince(started) < budget {
            let (el, depth, pressable) = queue[head]; head += 1; seen += 1
            let role = attr(el, kAXRoleAttribute) as? String ?? "?"
            let title = (attr(el, kAXTitleAttribute) as? String) ?? (attr(el, kAXDescriptionAttribute) as? String) ?? (attr(el, kAXPlaceholderValueAttribute) as? String) ?? ""
            var value = ""
            if let v = attr(el, kAXValueAttribute) { value = (v as? String) ?? ((v as? NSNumber).map { $0.stringValue } ?? "") }
            let shortRole = String(role.dropFirst(2))
            let isPressable = ["AXLink", "AXButton", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXRow", "AXCell", "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
            if title.lowercased().contains(q) || value.lowercased().contains(q) || shortRole.lowercased() == q {
                // plain text inside a link: hand back the link, carrying the text as its label
                let target = (!isPressable && (role == "AXStaticText" || role == "AXImage") && pressable != nil) ? pressable! : el
                if !taken.contains(where: { CFEqual($0, target) }) {
                    taken.append(target)
                    let tRole = target == el ? shortRole : String((attr(target, kAXRoleAttribute) as? String ?? "AX?").dropFirst(2))
                    let tTitle = target == el ? title : ((attr(target, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (title.isEmpty ? value : title))
                    var actionsRef: CFArray?
                    AXUIElementCopyActionNames(target, &actionsRef)
                    let actions = ((actionsRef as? [String]) ?? []).map { $0.replacingOccurrences(of: "AX", with: "") }
                    let e = UISnapshot.Element(id: next, role: tRole, title: tTitle, value: target == el ? value : "", frame: frame(target), actions: actions, depth: depth)
                    refs[next] = target; descs[next] = e; next += 1
                    out.append(e)
                }
            }
            if depth < 40, let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] {
                let below: AXUIElement? = (role == "AXLink" || role == "AXButton") ? el : pressable
                for k in kids { queue.append((k, depth + 1, below)) }
            }
        }
        return out
    }

    /// A numbered element, resolved once: the live reference when its role still reads, else the description it was
    /// numbered with and one re-find. `el` is nil when neither the old reference nor the re-find answered; `desc` still
    /// carries the frame it had, which is enough to click.
    public struct Resolved {
        public let el: AXUIElement?
        public let desc: UISnapshot.Element
        public let live: Bool
    }
    /// One resolution per action. Chrome throws references away within a second or two, so a stale one is re-found
    /// exactly once: the same role and title in a fresh shallow snapshot, else the same words near the same place deep
    /// in the page (a 2 s search). The old id is re-pointed at whatever was found, so the caller's numbering holds.
    public func resolve(_ id: Int) -> Resolved? {
        guard let want = descs[id] else { return nil }
        if let el = refs[id], attr(el, kAXRoleAttribute) != nil { return Resolved(el: el, desc: want, live: true) }
        let keep = (refs, descs)
        var found: AXUIElement?
        if let fresh = snapshot() { found = Self.rematch(want, in: fresh.elements).flatMap { refs[$0.id] } }
        refs = keep.0; descs = keep.1
        if found == nil, !(want.title.isEmpty && want.value.isEmpty) {
            let words = want.title.isEmpty ? want.value : want.title
            let hits = search(String(words.prefix(40)), limit: 8, budget: 2)
            found = Self.nearest(want, in: hits).flatMap { refs[$0.id] }
            refs = keep.0; descs = keep.1
        }
        if let found { refs[id] = found }
        return Resolved(el: found, desc: want, live: false)
    }
    /// The live element for an id, or nil — the recipe replayer's and the typer's view of `resolve`.
    func element(_ id: Int) -> AXUIElement? { resolve(id)?.el }
    /// Among deep search hits, the one with the same role nearest the old place; failing the role, the first hit.
    static func nearest(_ want: UISnapshot.Element, in hits: [UISnapshot.Element]) -> UISnapshot.Element? {
        hits.filter { $0.role == want.role }.min(by: { dist($0.frame, want.frame) < dist($1.frame, want.frame) }) ?? hits.first
    }
    /// The same element in a newer snapshot: same role and title, closest frame; a title-less element must match by frame.
    static func rematch(_ want: UISnapshot.Element, in elements: [UISnapshot.Element]) -> UISnapshot.Element? {
        let same = elements.filter { $0.role == want.role && $0.title == want.title }
        guard !same.isEmpty else { return nil }
        if want.title.isEmpty { return same.min(by: { dist($0.frame, want.frame) < dist($1.frame, want.frame) }).flatMap { dist($0.frame, want.frame) < 40 ? $0 : nil } }
        return same.min(by: { dist($0.frame, want.frame) < dist($1.frame, want.frame) })
    }
    static func dist(_ a: CGRect, _ b: CGRect) -> CGFloat { abs(a.midX - b.midX) + abs(a.midY - b.midY) }

    func perform(_ action: String, on id: Int) -> Bool {
        guard let el = element(id) else { return false }
        return AXUIElementPerformAction(el, ("AX" + action) as CFString) == .success
    }

    func setValue(_ text: String, on id: Int) -> Bool {
        guard let el = element(id) else { return false }
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFTypeRef) == .success
    }

    /// The element that has keyboard focus in the frontmost app, registered so it can be typed into.
    public func focusedTextElement() -> UISnapshot.Element? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        var f: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute as CFString, &f)
        guard let f else { return nil }
        let el = f as! AXUIElement
        let role = String((attr(el, kAXRoleAttribute) as? String ?? "AX?").dropFirst(2))
        let title = (attr(el, kAXTitleAttribute) as? String) ?? (attr(el, kAXDescriptionAttribute) as? String) ?? (attr(el, kAXPlaceholderValueAttribute) as? String) ?? ""
        let id = (refs.keys.max() ?? 0) + 1
        refs[id] = el
        return .init(id: id, role: role, title: title, value: (attr(el, kAXValueAttribute) as? String) ?? "", frame: frame(el), actions: [], depth: 0)
    }

    func focus(_ id: Int) -> Bool {
        guard let el = element(id) else { return false }
        return AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }
    func value(of id: Int) -> String {
        guard let el = element(id), let v = attr(el, kAXValueAttribute) else { return "" }
        return (v as? String) ?? ((v as? NSNumber).map { $0.stringValue } ?? "")
    }
    func frame(of id: Int) -> CGRect? { element(id).map(frame) }
    /// True when the frontmost app has a key window that can take typing.
    public func hasKeyWindow() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        var w: CFTypeRef?; AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString, &w)
        return w != nil
    }

    // MARK: thin calls on a resolved element — one AX round trip each, no re-resolving

    /// AXPress on the element itself; false when the action is refused.
    func press(_ el: AXUIElement) -> Bool { AXUIElementPerformAction(el, kAXPressAction as CFString) == .success }
    func canSetValue(_ el: AXUIElement) -> Bool { var ok = DarwinBoolean(false); return AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &ok) == .success && ok.boolValue }
    func set(_ text: String, on el: AXUIElement) -> Bool { AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFTypeRef) == .success }
    func focus(_ el: AXUIElement) -> Bool { AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success }
    func value(of el: AXUIElement) -> String {
        guard let v = attr(el, kAXValueAttribute) else { return "" }
        return (v as? String) ?? ((v as? NSNumber).map { $0.stringValue } ?? "")
    }

    /// The frontmost app's focused window, and its title read straight off it — no tree walk.
    private func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        var w: CFTypeRef?; AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString, &w)
        return w.map { $0 as! AXUIElement }
    }
    public func windowTitle() -> String { focusedWindow().flatMap { attr($0, kAXTitleAttribute) as? String } ?? "" }
    /// The focused window's frame in screen points, or nil when there is none.
    public func windowBounds() -> CGRect? { focusedWindow().map(frame).flatMap { $0.width > 0 ? $0 : nil } }

    /// The window title, the focused element and what sits at `point` — three or four calls, cheap enough to take
    /// before and after every action.
    public func signature(at point: CGPoint? = nil) -> ScreenSignature {
        var focus = ""
        if let app = NSWorkspace.shared.frontmostApplication {
            var f: CFTypeRef?
            AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute as CFString, &f)
            if let f { focus = words(of: f as! AXUIElement) }
        }
        return ScreenSignature(window: windowTitle(), focus: focus, atPoint: point.map { elementAt($0).map(words(of:)) ?? "" })
    }
    /// The deepest element under a screen point, by the app's own hit test.
    func elementAt(_ p: CGPoint) -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        var el: AXUIElement?
        return AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(app.processIdentifier), Float(p.x), Float(p.y), &el) == .success ? el : nil
    }
    /// "Role “title”" (or the value when there is no title) — an element's words for a signature.
    private func words(of el: AXUIElement) -> String {
        let role = String((attr(el, kAXRoleAttribute) as? String ?? "AX?").dropFirst(2))
        let title = (attr(el, kAXTitleAttribute) as? String) ?? (attr(el, kAXDescriptionAttribute) as? String) ?? ""
        let label = title.isEmpty ? ((attr(el, kAXValueAttribute) as? String) ?? "") : title
        return "\(role) “\(label.prefix(60))”"
    }

    /// The title an id was numbered with — for narration, never a live read (a stale reference would cost a re-find).
    func titleOf(_ id: Int) -> String { descs[id]?.title ?? "" }

    private func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: CFTypeRef?; AXUIElementCopyAttributeValue(el, name as CFString, &v); return v
    }
    private func frame(_ el: AXUIElement) -> CGRect {
        var p = CGPoint.zero, s = CGSize.zero
        if let pv = attr(el, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
        if let sv = attr(el, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
        return CGRect(origin: p, size: s)
    }
}

/// Synthetic input. Note: CGEvent clicks move the real pointer; Hands prefers AX actions, which don't.
public enum VirtualInput {
    public static func click(_ p: CGPoint) {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(40_000)
        }
    }
    static func type(_ text: String) {
        for scalar in text.unicodeScalars {
            var u = [UniChar](String(scalar).utf16)
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true); down?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u); down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false); up?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u); up?.post(tap: .cghidEventTap)
            usleep(8_000)
        }
    }
    static let keyCodes: [String: CGKeyCode] = ["return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
                                                "pagedown": 121, "pageup": 116, "home": 115, "end": 119, "a": 0, "c": 8, "v": 9, "x": 7, "z": 6, "s": 1, "f": 3, "n": 45, "w": 13, "t": 17, "l": 37, "r": 15, "k": 40]
    /// "cmd+shift+a" → the key code and modifier flags, or nil for a key this table does not know — so the caller can
    /// say so instead of reporting a press that never happened.
    public static func parse(_ combo: String) -> (code: CGKeyCode, flags: CGEventFlags)? {
        var flags = CGEventFlags()
        var code: CGKeyCode?
        for p in combo.lowercased().split(separator: "+").map(String.init) {
            switch p { case "cmd", "command": flags.insert(.maskCommand); case "shift": flags.insert(.maskShift); case "alt", "option", "opt": flags.insert(.maskAlternate); case "ctrl", "control": flags.insert(.maskControl); default: code = keyCodes[p] }
        }
        return code.map { ($0, flags) }
    }
    static func key(_ combo: String) {
        guard let (code, flags) = parse(combo) else { return }
        let d = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true); d?.flags = flags; d?.post(tap: .cghidEventTap)
        let u = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false); u?.flags = flags; u?.post(tap: .cghidEventTap)
    }
}
