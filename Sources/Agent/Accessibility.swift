import Foundation
import AppKit
import ApplicationServices

/// A compact, numbered snapshot of the frontmost app's UI via the Accessibility API. Elements get
/// stable ids for one snapshot so the brain can say "press 14".
public struct UISnapshot: Sendable {
    public struct Element: Sendable {
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
        refs.removeAll()
        var elements: [UISnapshot.Element] = []
        var next = 1
        func walk(_ el: AXUIElement, depth: Int) {
            guard elements.count < maxElements, depth < 14 else { return }
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
                elements.append(.init(id: id, role: String(role.dropFirst(2)), title: title, value: value, frame: frame(el), actions: actions, depth: depth))
            }
            if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] { for k in kids { walk(k, depth: depth + 1) } }
        }
        walk(root, depth: 0)
        return UISnapshot(app: app.localizedName ?? "?", window: attr(root, kAXTitleAttribute) as? String ?? "", elements: elements)
    }

    func element(_ id: Int) -> AXUIElement? { refs[id] }

    func perform(_ action: String, on id: Int) -> Bool {
        guard let el = refs[id] else { return false }
        return AXUIElementPerformAction(el, ("AX" + action) as CFString) == .success
    }

    func setValue(_ text: String, on id: Int) -> Bool {
        guard let el = refs[id] else { return false }
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
        guard let el = refs[id] else { return false }
        return AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }
    func value(of id: Int) -> String {
        guard let el = refs[id], let v = attr(el, kAXValueAttribute) else { return "" }
        return (v as? String) ?? ((v as? NSNumber).map { $0.stringValue } ?? "")
    }
    func frame(of id: Int) -> CGRect? { refs[id].map(frame) }

    func snapshotRole(_ id: Int) -> String { refs[id].flatMap { attr($0, kAXRoleAttribute) as? String }.map { String($0.dropFirst(2)) } ?? "?" }
    func titleOf(_ id: Int) -> String { refs[id].flatMap { (attr($0, kAXTitleAttribute) as? String) ?? (attr($0, kAXDescriptionAttribute) as? String) } ?? "" }

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
    static let keyCodes: [String: CGKeyCode] = ["return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126, "a": 0, "c": 8, "v": 9, "x": 7, "z": 6, "s": 1, "f": 3, "n": 45, "w": 13, "t": 17, "l": 37]
    static func key(_ combo: String) {
        let parts = combo.lowercased().split(separator: "+").map(String.init)
        var flags = CGEventFlags()
        var code: CGKeyCode?
        for p in parts {
            switch p { case "cmd", "command": flags.insert(.maskCommand); case "shift": flags.insert(.maskShift); case "alt", "option": flags.insert(.maskAlternate); case "ctrl", "control": flags.insert(.maskControl); default: code = keyCodes[p] }
        }
        guard let code else { return }
        let d = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true); d?.flags = flags; d?.post(tap: .cghidEventTap)
        let u = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false); u?.flags = flags; u?.post(tap: .cghidEventTap)
    }
}
