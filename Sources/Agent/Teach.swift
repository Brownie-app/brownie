import Foundation
import AppKit
import ApplicationServices
import Contacts
import Domain
import Support

/// "Show me once": watches what the user does in other apps through the accessibility tree —
/// which app, which element (by role and title), what was typed. Never pixels, never a recording,
/// never a secure field. Stops itself the moment the next press would be Send/Pay/Delete.
@MainActor
public final class Recorder {
    public private(set) var steps: [TaughtRecipe.Step] = []
    public private(set) var isRecording = false
    public var onChange: (() -> Void)?
    /// Set when the recorder stopped by itself, with why.
    public private(set) var stoppedBecause: String?

    private var monitors: [Any] = []
    private var lastApp: String?
    private var buffer = ""
    private var bufferField = ""
    private var bufferApp = ""
    private var bufferPlace: (Double?, Double?) = (nil, nil)
    private var bufferURL: String?
    private let log = Log("teach")
    private let stopWords = ["send", "pay", "submit", "delete", "purchase", "buy", "post", "confirm", "place order", "transfer"]

    public init() {}

    public func start() {
        guard !isRecording else { return }
        steps = []; stoppedBecause = nil; lastApp = nil; buffer = ""
        isRecording = true
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] e in Task { @MainActor in self?.click(e) } } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] e in Task { @MainActor in self?.key(e) } } as Any)
        log.info("recording")
    }

    public func stop() {
        if buffer.isEmpty, let app = app(), let v = focusedFieldValue(app.pid), !v.isEmpty, !steps.contains(where: { $0.kind == .type && $0.text == v }) {
            steps.append(.init(kind: .type, app: app.name, target: focusedFieldTitle(app.pid), role: "TextField", text: v))
        }
        flush()
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []; isRecording = false
        log.info("stopped with \(steps.count) steps")
        onChange?()
    }

    private func app() -> (name: String, pid: pid_t)? {
        guard let a = NSWorkspace.shared.frontmostApplication, a.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return (Self.clean(a.localizedName ?? "App"), a.processIdentifier)
    }
    /// WhatsApp and friends pad accessibility titles with direction marks and zero-width characters.
    nonisolated public static func clean(_ s: String) -> String {
        String(s.unicodeScalars.filter { !["\u{200E}", "\u{200F}", "\u{200B}", "\u{2060}", "\u{FEFF}"].contains(String($0)) }).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func noteApp(_ name: String) {
        if lastApp != name { flush(); steps.append(.init(kind: .launch, app: name, target: name)); lastApp = name }
    }

    private func click(_ e: NSEvent) {
        guard let app = app() else { return }
        noteApp(app.name)
        // AX coordinates have the origin top-left of the primary screen; Cocoa's is bottom-left.
        let p = NSEvent.mouseLocation
        let h = NSScreen.screens.first?.frame.height ?? 0
        var el: AXUIElement?
        AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(h - p.y), &el)
        guard let el else { return }
        var elPid: pid_t = 0; AXUIElementGetPid(el, &elPid)
        if elPid == ProcessInfo.processInfo.processIdentifier { return }   // a click back on Brownie itself is not a step
        if let owner = NSRunningApplication(processIdentifier: elPid)?.localizedName, owner == "Dock" || owner == "Window Server" { return }   // the Dock launch is already the "open" step
        var role = attr(el, kAXRoleAttribute) as? String ?? "?"
        if role == "AXSecureTextField" { return }
        var title = (attr(el, kAXTitleAttribute) as? String) ?? (attr(el, kAXDescriptionAttribute) as? String) ?? ""
        // A text inside a button or row: the row is what Hands will look for later.
        if role == "AXStaticText" || role == "AXImage" || role == "AXGroup" {
            var node = el
            for _ in 0..<4 {
                guard let parent = attr(node, kAXParentAttribute) else { break }
                node = parent as! AXUIElement
                if let r = attr(node, kAXRoleAttribute) as? String, ["AXButton", "AXRow", "AXCell", "AXLink", "AXMenuItem"].contains(r) {
                    let t = (attr(node, kAXTitleAttribute) as? String) ?? (attr(node, kAXDescriptionAttribute) as? String) ?? ""
                    if !t.isEmpty { role = r; title = t }
                    break
                }
            }
        }
        if title.isEmpty, let v = attr(el, kAXValueAttribute) as? String { title = v }
        if title.isEmpty, role == "AXStaticText" || role == "AXCell" || role == "AXRow" || role == "AXGroup" { title = rowTitle(el) }
        title = Self.clean(String(title.prefix(80)))
        // where it sat, and the words around it — the only way back to an unlabelled element on a web page
        let (fx, fy) = fractions(el, pid: app.pid)
        let context = Self.clean(String(rowTitle(el).prefix(80)))
        let url = pageURL(app.pid)
        if role == "AXTextField" || role == "AXTextArea" || role == "AXSearchField" || role == "AXComboBox" { flush(); bufferField = title; bufferApp = app.name; bufferPlace = (fx, fy); bufferURL = url; return }   // typing follows
        let typedIntoMessageBox = !buffer.isEmpty && ["message", "compose", "reply", "type a message", "write"].contains(where: { bufferField.lowercased().contains($0) })
        flush()
        let low = title.lowercased()
        if role == "AXButton", stopWords.contains(where: { low == $0 || low.hasPrefix($0 + " ") }) || typedIntoMessageBox {
            stoppedBecause = "You pressed “\(title)” after writing the message — that sends. Hands will always stop before that step and leave it to you."
            stop(); return
        }
        steps.append(.init(kind: .click, app: app.name, target: title.isEmpty ? String(role.dropFirst(2)) : title, role: String(role.dropFirst(2)), fx: fx, fy: fy, context: context == title ? nil : (context.isEmpty ? nil : context), url: url))
        onChange?()
    }

    /// The element's centre as fractions of its window.
    private func fractions(_ el: AXUIElement, pid: pid_t) -> (Double?, Double?) {
        var p = CGPoint.zero, sz = CGSize.zero
        if let pv = attr(el, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
        if let sv = attr(el, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &sz) }
        var w: CFTypeRef?; AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &w)
        guard let w else { return (nil, nil) }
        var wp = CGPoint.zero, ws = CGSize.zero
        if let pv = attr(w as! AXUIElement, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &wp) }
        if let sv = attr(w as! AXUIElement, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &ws) }
        guard let (fx, fy) = StepMatch.fraction(CGRect(origin: p, size: sz), in: CGRect(origin: wp, size: ws)) else { return (nil, nil) }
        return (fx, fy)
    }
    /// A browser's page address, from its web area, when the app is a browser.
    private func pageURL(_ pid: pid_t) -> String? {
        guard let name = NSRunningApplication(processIdentifier: pid)?.localizedName, BrowserSkill.isBrowser(name) else { return nil }
        var w: CFTypeRef?; AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &w)
        guard let w else { return nil }
        var found: String?
        func walk(_ n: AXUIElement, depth: Int) {
            guard found == nil, depth < 8 else { return }
            if (attr(n, kAXRoleAttribute) as? String) == "AXWebArea", let u = attr(n, "AXURL") as? URL { found = u.absoluteString; return }
            if let kids = attr(n, kAXChildrenAttribute) as? [AXUIElement] { for k in kids { walk(k, depth: depth + 1) } }
        }
        walk(w as! AXUIElement, depth: 0)
        return found
    }

    /// A row's text is usually on a child; take the first few static texts.
    private func rowTitle(_ el: AXUIElement) -> String {
        var node = el
        for _ in 0..<3 {
            if let role = attr(node, kAXRoleAttribute) as? String, role == "AXRow" || role == "AXCell" { break }
            guard let parent = attr(node, kAXParentAttribute) else { break }
            node = parent as! AXUIElement
        }
        var texts: [String] = []
        func walk(_ n: AXUIElement, depth: Int) {
            guard depth < 4, texts.count < 3 else { return }
            if let r = attr(n, kAXRoleAttribute) as? String, r == "AXStaticText", let v = attr(n, kAXValueAttribute) as? String, !v.isEmpty { texts.append(v) }
            if let kids = attr(n, kAXChildrenAttribute) as? [AXUIElement] { for k in kids { walk(k, depth: depth + 1) } }
        }
        walk(node, depth: 0)
        return texts.first ?? ""
    }

    private func key(_ e: NSEvent) {
        guard let app = app() else { return }
        noteApp(app.name)
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        if e.keyCode == 48 || e.keyCode == 53 || (123...126).contains(e.keyCode) { if mods.contains(.command) { flush() }; return }   // tab, esc, arrows, ⌘-tab: navigation, not content
        if mods.contains(.command) || mods.contains(.control) {
            flush()
            var combo: [String] = []
            if mods.contains(.command) { combo.append("cmd") }; if mods.contains(.control) { combo.append("ctrl") }; if mods.contains(.option) { combo.append("alt") }
            if e.modifierFlags.contains(.shift) { combo.append("shift") }
            combo.append((e.charactersIgnoringModifiers ?? "").lowercased())
            steps.append(.init(kind: .key, app: app.name, target: combo.joined(separator: "+")))
            onChange?(); return
        }
        if e.keyCode == 36 {   // Return: in a message field this is Send. Record the text, stop here.
            let hadText = !buffer.isEmpty
            flush()
            if hadText { stoppedBecause = "You pressed Return, which sends. Hands will stop before that and leave it to you."; stop() }
            return
        }
        if e.keyCode == 51 { if !buffer.isEmpty { buffer.removeLast() }; return }
        guard let chars = e.characters, !chars.isEmpty, !isSecureFocused(app.pid) else { return }
        let printable = chars.filter { !$0.isNewline && ($0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol || $0 == " ") }
        guard !printable.isEmpty else { return }
        if bufferField.isEmpty { bufferField = focusedFieldTitle(app.pid); bufferApp = app.name }
        buffer += printable
        onChange?()
    }

    private func isSecureFocused(_ pid: pid_t) -> Bool {
        var f: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &f)
        guard let f else { return false }
        return (attr(f as! AXUIElement, kAXRoleAttribute) as? String) == "AXSecureTextField"
    }
    private func focusedFieldTitle(_ pid: pid_t) -> String {
        var f: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &f)
        guard let f else { return "" }
        let el = f as! AXUIElement
        return Self.clean((attr(el, kAXTitleAttribute) as? String) ?? (attr(el, kAXDescriptionAttribute) as? String) ?? (attr(el, kAXPlaceholderValueAttribute) as? String) ?? "text field")
    }

    private func flush() {
        guard !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { buffer = ""; bufferField = ""; return }
        // What the field holds is truer than what we counted: autocorrect, IME, dropped events.
        var text = buffer
        if let app = app(), let v = focusedFieldValue(app.pid), !v.isEmpty, v.count >= buffer.count / 2 { text = v }
        steps.append(.init(kind: .type, app: bufferApp, target: bufferField.isEmpty ? "text field" : bufferField, role: "TextField", text: text, fx: bufferPlace.0, fy: bufferPlace.1, url: bufferURL))
        buffer = ""; bufferField = ""; bufferPlace = (nil, nil); bufferURL = nil
        onChange?()
    }
    private func focusedFieldValue(_ pid: pid_t) -> String? {
        var f: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &f)
        guard let f else { return nil }
        let el = f as! AXUIElement
        if (attr(el, kAXRoleAttribute) as? String) == "AXSecureTextField" { return nil }
        return attr(el, kAXValueAttribute) as? String
    }

    /// What's happening now, for the live list: the text being typed so far.
    public var pendingText: String { buffer }

    private func attr(_ el: AXUIElement, _ name: String) -> AnyObject? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(el, name as CFString, &v); return v }

    /// Guesses the parts that should change each run: the person (what was typed into a search box, else
    /// the row that was picked), and the message (the last thing typed anywhere else).
    nonisolated public static func suggestParameters(_ steps: [TaughtRecipe.Step]) -> [TaughtRecipe.Parameter] {
        var out: [TaughtRecipe.Parameter] = []
        let isSearch = { (s: TaughtRecipe.Step) in s.kind == .type && (s.target.lowercased().contains("search") || s.target.lowercased().contains("find") || s.target.lowercased().contains("to:")) }
        let chrome: Set<String> = ["search", "compose", "new", "new chat", "back", "send", "attach", "menu"]
        // In a browser the address bar is not a person, and a site's search box is a "search", not a message.
        if let app = steps.first(where: { $0.kind == .launch })?.app, BrowserSkill.isBrowser(app) {
            let addr = { (s: TaughtRecipe.Step) in s.target.lowercased().contains("address") }
            if let site = steps.first(where: { $0.kind == .type && !addr($0) && isSearch($0) }) { out.append(.init(name: "search", original: site.text, fill: .fixed)) }
            if let typed = steps.last(where: { $0.kind == .type && !addr($0) && !isSearch($0) && !$0.text.isEmpty }) { out.append(.init(name: "text", original: typed.text, fill: .fixed)) }
            return out
        }
        if let search = steps.first(where: isSearch) {
            out.append(.init(name: "person", original: search.text, fill: .fixed))
        } else if let person = steps.first(where: { $0.kind == .click && ($0.role == "Row" || $0.role == "Cell" || $0.role == "StaticText") && !$0.target.isEmpty && $0.target.count < 40 && !chrome.contains($0.target.lowercased()) }) {
            out.append(.init(name: "person", original: person.target, fill: .fixed))
        }
        if let typed = steps.last(where: { $0.kind == .type && $0.text.count > 0 && !isSearch($0) }) {
            out.append(.init(name: "message", original: typed.text, fill: .fixed))
        }
        return out
    }
    nonisolated public static func suggestName(_ steps: [TaughtRecipe.Step], parameters: [TaughtRecipe.Parameter]) -> String {
        let app = steps.first(where: { $0.kind == .launch })?.app ?? "an app"
        if BrowserSkill.isBrowser(app) {
            let host = steps.compactMap(\.url).compactMap { URL(string: $0)?.host?.replacingOccurrences(of: "www.", with: "") }.first
            let search = parameters.first { $0.name == "search" }?.original
            if let host, let search { return "Search \(host) for \(search)" }
            if let host { return "Do the \(host) thing in \(app)" }
        }
        if let p = parameters.first(where: { $0.name == "person" }) { return "Message \(p.original) in \(app)" }
        return "Do the \(app) thing"
    }
}

/// Replays a taught recipe. The ladder: an app link when one exists, then the accessibility tree
/// by role and title, then — only where allowed — the screen agent. Always stops before Send.
public struct RecipeRunner: Sendable {
    public enum Outcome: Sendable, Equatable { case pausedForUser(String), done(String), couldNot(String) }
    public typealias ScreenFallback = @Sendable (_ goal: String, _ onStep: @escaping @Sendable (String) -> Void) async -> Outcome?
    private let screen: ScreenFallback?
    private let screenForbidden: Set<String>
    private let log = Log("recipe")

    public init(screenFallback: ScreenFallback?, screenForbidden: Set<String>) { self.screen = screenFallback; self.screenForbidden = screenForbidden }

    /// `values`: parameter name → value for this run.
    /// The recipe's steps with this run's values filled in — the file, the person, the message.
    public static func substituted(_ recipe: TaughtRecipe, values: [String: String]) -> [TaughtRecipe.Step] {
        recipe.steps.map { s -> TaughtRecipe.Step in
            var s = s
            // A trigger recipe's file: `{file}` anywhere in typed text or a target becomes the path; `{filename}` its name.
            if let file = values["file"] {
                let name = (file as NSString).lastPathComponent
                s.text = s.text.replacingOccurrences(of: "{file}", with: file).replacingOccurrences(of: "{filename}", with: name)
                if s.target.contains("{file") { s = .init(kind: s.kind, app: s.app, target: s.target.replacingOccurrences(of: "{file}", with: file).replacingOccurrences(of: "{filename}", with: name), role: s.role, text: s.text) }
            }
            for p in recipe.parameters {
                guard let v = values[p.name], v != p.original, !p.original.isEmpty else { continue }
                if s.kind == .type, s.text == p.original { s.text = v }
                if s.kind == .click, s.target.lowercased() == p.original.lowercased() || (p.name == "person" && s.target.lowercased().contains(p.original.lowercased())) { return .init(kind: .click, app: s.app, target: v, role: s.role) }
            }
            return s
        }
    }

    public func run(_ recipe: TaughtRecipe, values: [String: String], onStep: @escaping @Sendable (String) -> Void) async -> Outcome {
        let steps = Self.substituted(recipe, values: values)
        log.info("run “\(recipe.name)”: \(steps.count) steps, values \(values)")
        // Rung 1: an app link does the whole thing without touching the screen.
        if recipe.method == "WhatsApp link", let msg = steps.last(where: { $0.kind == .type && !$0.target.lowercased().contains("search") })?.text {
            let person = recipe.parameters.first(where: { $0.name == "person" }).flatMap { values[$0.name] ?? $0.original } ?? steps.first(where: { $0.kind == .click && ($0.role == "Row" || $0.role == "Cell" || $0.role == "StaticText") })?.target
            // Only when Contacts knows the number does the link land in the right chat; otherwise replay the steps as recorded.
            if let person, let phone = ContactLookup.phone(for: person), !phone.isEmpty {
                let q = msg.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                await MainActor.run { NSWorkspace.shared.open(URL(string: "whatsapp://send?phone=\(phone)&text=\(q)")!) }
                log.info("whatsapp link to \(person) (\(phone))")
                onStep("Opened the WhatsApp chat with \(person); the message is in the box")
                return .pausedForUser("Press Send in WhatsApp when you're ready")
            }
            log.info("no phone for \(person ?? "?") in Contacts — replaying the recorded steps")
        }
        // Rung 2: the accessibility tree, element by element.
        let session = AXSession()
        let person = recipe.parameters.first(where: { $0.name == "person" }).flatMap { values[$0.name] ?? $0.original }
        var chatVerified = false
        var lastClick: CGRect = .zero
        var lastURL: String?
        let norm = { (x: String) in x.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.trimmingCharacters(in: .whitespaces) }
        for s in steps {
            if Task.isCancelled { log.info("stopped by the user"); return .couldNot("stopped") }
            if s.kind != .launch { await bringFront(s.app) }   // a dialog or another app in front would swallow the step
            switch s.kind {
            case .launch:
                await MainActor.run { NSWorkspace.shared.launchApplication(s.app) }
                // Wait until it is actually in front (a cold launch can take seconds).
                for _ in 0..<12 { if await MainActor.run(body: { NSWorkspace.shared.frontmostApplication?.localizedName == s.app }) { break }; try? await Task.sleep(nanoseconds: 400_000_000) }
                try? await Task.sleep(nanoseconds: 700_000_000)
                onStep("Opened \(s.app)")
            case .click:
                let rowish: Set<String> = ["Row", "Cell", "StaticText", "Button", "Link"]
                let isPersonPick = person != nil && rowish.contains(s.role) && norm(s.target).contains(norm(person!).split(separator: " ").first.map(String.init) ?? "\u{0}")
                // A browser step recorded on a page: go there first, so the element exists to be found.
                if let u = s.url, BrowserSkill.isBrowser(s.app), lastURL != u, let url = URL(string: u), let appURL = AppLauncher.locate(s.app) {
                    _ = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: .init()) { a, e in c.resume(returning: e == nil && a != nil) } }
                    lastURL = u; onStep("Went to \(URL(string: u)?.host ?? u)")
                    for _ in 0..<16 { try? await Task.sleep(nanoseconds: 500_000_000); if let w = await MainActor.run(body: { session.snapshot(maxElements: 10)?.window }), BrowserSkill.loaded(title: w, before: "") { break } }
                }
                var ok = false
                var tried: Set<Int> = []
                for attempt in 0..<4 {   // the element may still be loading; a wrong pick is retried on the next candidate
                    let picked: (Int, CGRect)? = await MainActor.run {
                        guard let snap = session.snapshot() else { return nil }
                        let want = norm(s.target)
                        let first = want.split(separator: " ").first.map(String.init) ?? want
                        let win = snap.elements.first { $0.role == "Window" }?.frame ?? .zero
                        // After a search the pick is in the list pane: left of centre, below the search box.
                        let inList = { (e: UISnapshot.Element) in isPersonPick ? (win == .zero || (e.frame.midX < win.midX && e.frame.minY > win.minY + 60)) : true }
                        let candidates = snap.elements.filter { !tried.contains($0.id) && inList($0) }
                        var hit = isPersonPick
                            ? (candidates.first(where: { $0.role == s.role && norm($0.title) == want })
                                ?? candidates.first(where: { norm($0.title) == want })
                                ?? candidates.first(where: { rowish.contains($0.role) && (norm($0.title).contains(want) || norm($0.value).contains(want)) })
                                ?? candidates.first(where: { norm($0.title).contains(want) || norm($0.value).contains(want) })
                                ?? (first.count > 2 ? candidates.first(where: { rowish.contains($0.role) && (norm($0.title).hasPrefix(first) || norm($0.title).contains(" " + first)) }) : nil))
                            : StepMatch.candidate(for: s, in: UISnapshot(app: snap.app, window: snap.window, elements: candidates))
                        // deep in a web page: the shallow snapshot won't have it, the word search will
                        if hit == nil, !s.isUnlabelled, let deep = session.search(s.target, limit: 6).first(where: { !tried.contains($0.id) }) { hit = deep }
                        guard let hit else { return nil }
                        tried.insert(hit.id)
                        // Rows and their texts rarely answer AXPress in web-view apps; a real click on the centre does.
                        if rowish.contains(hit.role), hit.frame.width > 0 { VirtualInput.click(CGPoint(x: hit.frame.midX, y: hit.frame.midY)) }
                        else if !session.perform("Press", on: hit.id), hit.frame.width > 0 { VirtualInput.click(CGPoint(x: hit.frame.midX, y: hit.frame.midY)) }
                        lastClick = hit.frame
                        return (hit.id, hit.frame)
                    }
                    if picked == nil { try? await Task.sleep(nanoseconds: UInt64(500_000_000 + attempt * 300_000_000)); continue }
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    if isPersonPick {
                        // The one check that matters: is the conversation with this person actually open now?
                        if await chatIsOpen(session, person: person!) { ok = true; chatVerified = true; break }
                        log.warn("clicked “\(s.target)” but the header doesn't show \(person!) — trying the next match")
                        continue
                    }
                    ok = true; break
                }
                log.info("click “\(s.target)” (\(s.role)): \(ok ? "ok" : "not found")")
                if ok { onStep(isPersonPick ? "Opened the chat with \(person!)" : "Pressed “\(s.target)”") }
                else if isPersonPick { return .couldNot("Couldn't open the chat with \(person!) — nothing was typed") }
                else if let o = await fallback(recipe, s, "In \(s.app), press “\(s.target)”", onStep) { return o }
                else { return .couldNot("Couldn't find “\(s.target)” in \(s.app), and the screen is off for that app") }
            case .type:
                let isMessageBox = ["message", "compose", "reply", "write"].contains { s.target.lowercased().contains($0) }
                if isMessageBox, person != nil, !chatVerified {
                    if await chatIsOpen(session, person: person!) { chatVerified = true }
                    else { log.warn("refusing to type: the chat with \(person!) is not the one open"); return .couldNot("The chat with \(person!) isn't open, so nothing was typed") }
                }
                let typed = await typeRobustly(session, s, near: lastClick)
                log.info("type into “\(s.target)”: \(typed ? "ok" : "failed")")
                if typed { onStep("Typed the message into “\(s.target)”") }
                else if let o = await fallback(recipe, s, "In \(s.app), type into “\(s.target)”: \(s.text)", onStep) { return o }
                else { return .couldNot("Couldn't type into “\(s.target)” in \(s.app)") }
            case .key:
                // Return in a message box is Send. Hands never presses that; it hands over here.
                if ["return", "enter", "cmd+return", "cmd+enter"].contains(s.target.lowercased()) { return .pausedForUser("Everything is in place — the next step is Return, which sends. That's yours.") }
                VirtualInput.key(s.target); onStep("Pressed \(s.target)")
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        return .pausedForUser("Everything is in place. The last step is yours.")
    }

    /// Typing that checks its work. Real key events first — apps built on web views ignore an AX value
    /// set and never run their search or enable their Send button — then paste, then the AX value.
    private func typeRobustly(_ session: AXSession, _ s: TaughtRecipe.Step, near: CGRect = .zero) async -> Bool {
        let want = s.target.lowercased()
        let isSearch = want.contains("search") || want.contains("find")
        let messageWords = ["message", "compose", "reply", "write"]
        let isMessage = messageWords.contains { want.contains($0) }
        for attempt in 0..<3 {
            let field: Int? = await MainActor.run { () -> Int? in
                guard let snap = session.snapshot() else { return nil }
                let textish: Set<String> = ["TextField", "TextArea", "SearchField", "ComboBox"]
                // The wrong kind of box is worse than no box: a search never goes into a message field, and vice versa.
                let fields = snap.elements.filter { e in
                    let t = e.title.lowercased()
                    return textish.contains(e.role) && !(isSearch && messageWords.contains { t.contains($0) }) && !(isMessage && (t.contains("search") || t.contains("find")))
                }
                if let f = fields.first(where: { $0.title.lowercased() == want }) ?? fields.first(where: { !$0.title.isEmpty && ($0.title.lowercased().contains(want) || want.contains($0.title.lowercased())) }) { return f.id }
                // a field with no name: the one at the recorded place
                if s.fx != nil, let f = StepMatch.candidate(for: .init(kind: .click, app: s.app, target: "", role: "TextField", fx: s.fx, fy: s.fy), in: UISnapshot(app: snap.app, window: snap.window, elements: fields)) { return f.id }
                // A field that appeared where we just clicked (WhatsApp's search box shows only once its label is clicked).
                if near.width > 0, let f = fields.min(by: { abs($0.frame.midY - near.midY) < abs($1.frame.midY - near.midY) }), abs(f.frame.midY - near.midY) < 40 { return f.id }
                if let f = session.focusedTextElement(), textish.contains(f.role), !(isSearch && messageWords.contains { w in f.title.lowercased().contains(w) }), !(isMessage && f.title.lowercased().contains("search")) { return f.id }
                if want == "text field", let f = fields.last { return f.id }
                return nil
            }
            guard let id = field else {
                if isSearch, attempt == 0, near.width > 0 { VirtualInput.click(CGPoint(x: near.midX, y: near.midY)) }   // click the label again; the box may need it
                try? await Task.sleep(nanoseconds: 700_000_000); continue
            }
            if await RobustTyper.type(s.text, into: id, session: session, log: log) { await settle(isSearch); return true }
            log.warn("typing attempt \(attempt + 1) into “\(s.target)” did not land")
            if attempt == 2 { return await MainActor.run { !session.value(of: id).isEmpty } }
        }
        log.warn("no \(isSearch ? "search" : (isMessage ? "message" : "text")) field for “\(s.target)” — not typing anywhere else")
        return false
    }
    /// Makes sure the step's app is the one in front before acting; gives up quietly after 3 s.
    private func bringFront(_ app: String) async {
        for _ in 0..<6 {
            let front = await MainActor.run { NSWorkspace.shared.frontmostApplication?.localizedName.map(Recorder.clean) }
            if front == app { return }
            await MainActor.run { NSWorkspace.shared.launchApplication(app) }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        log.warn("\(app) is not in front (something else is — a dialog?)")
    }

    /// True when the conversation header (top of the window, right of the list) names this person.
    private func chatIsOpen(_ session: AXSession, person: String) async -> Bool {
        await MainActor.run { session.snapshot().map { ChatWindowCheck.headerNames($0, person: person) } ?? false }
    }

    /// Search results need a moment to appear before the next click looks for them.
    private func settle(_ isSearch: Bool) async { try? await Task.sleep(nanoseconds: isSearch ? 1_500_000_000 : 300_000_000) }

    private func fallback(_ r: TaughtRecipe, _ s: TaughtRecipe.Step, _ goal: String, _ onStep: @escaping @Sendable (String) -> Void) async -> Outcome? {
        guard let screen, !screenForbidden.contains(s.app) else { return nil }
        onStep("Couldn't find it in the tree — looking at the screen")
        return await screen(goal, onStep)
    }
}

/// Name → phone digits, from the user's Contacts (already granted for chat names).
public enum ContactLookup {
    public static func phone(for name: String) -> String? {
        let store = CNContactStore()
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }
        let req = CNContactFetchRequest(keysToFetch: [CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor])
        req.predicate = CNContact.predicateForContacts(matchingName: name)
        var found: String?
        try? store.enumerateContacts(with: req) { c, stop in
            if let p = c.phoneNumbers.first?.value.stringValue { found = p.filter(\.isNumber); stop.pointee = true }
        }
        if let f = found, f.count == 10 { return "91" + f }   // a bare Indian number
        return found
    }
}
