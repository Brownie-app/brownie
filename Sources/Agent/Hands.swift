import Foundation
import AppKit
import Domain
import Support

/// Hands: the computer-use loop over the Accessibility tree, grounded in the knowledge base, with a
/// confirmation policy the model cannot override. Runs only while the user is present.
public actor Hands {
    public struct Policy: Sendable {
        /// Words in an element's title that mean "irreversible" — Hands stops before pressing these.
        public var alwaysAskBefore = ["send", "pay", "submit", "delete", "purchase", "buy", "post", "confirm order", "place order", "transfer"]
        public var maxSteps = 40
        public var timeout: TimeInterval = 300
        public init() {}
    }
    public enum Outcome: Sendable, Equatable { case done(String), pausedForUser(String), stopped, couldNot(String) }
    public enum Event: Sendable { case step(String), paused(String), finished(Outcome), plan([String]), stepDone(Int, String) }

    private let brain: any AgenticBrain
    private let knowledge: any KnowledgeStore
    private let policy: Policy
    private let effort: Effort
    private let log = Log("hands")
    private var session = AXSession()
    private var task: Task<Outcome, Never>?
    private var repeatGuard = HandsGuard.RepeatGuard()
    private func repeats(_ tool: String, _ args: Data) -> Bool { repeatGuard.record(tool: tool, args: String(decoding: args, as: UTF8.self)) }

    public init(brain: any AgenticBrain, knowledge: any KnowledgeStore, policy: Policy = Policy(), effort: Effort = .medium) {
        self.brain = brain; self.knowledge = knowledge; self.policy = policy; self.effort = effort
    }

    public static var hasAccessibility: Bool { AXIsProcessTrusted() }

    public func stop() { task?.cancel() }

    public func perform(_ goal: String, onEvent: @escaping @Sendable (Event) -> Void) async -> Outcome {
        guard Self.hasAccessibility else { return .couldNot("Accessibility permission is off") }
        let t = Task { await self.loop(goal, onEvent: onEvent) }
        task = t
        let o = await t.value
        task = nil
        onEvent(.finished(o))
        return o
    }

    private func loop(_ goal: String, onEvent: @escaping @Sendable (Event) -> Void) async -> Outcome {
        log.info("goal: \(goal.prefix(80)) · brain \(brain.descriptor.id) · accessibility \(Self.hasAccessibility) · screen \(CGPreflightScreenCaptureAccess())")
        let notes = (try? await knowledge.search(goal, limit: 4)) ?? []
        let context = notes.isEmpty ? "(no matching notes)" : notes.map { "## \($0.relativePath)\n\($0.body.prefix(1200))" }.joined(separator: "\n\n")
        let box = OutcomeBox()
        repeatGuard = HandsGuard.RepeatGuard()
        let tools = makeTools(box: box, goal: goal).map { tool in
            // A step repeated three times in a row is a loop, not progress.
            Tool(name: tool.name, description: tool.description, parametersSchema: tool.parametersSchema) { d in
                if await self.repeats(tool.name, d) { return ToolOutput("STOP: you have done exactly this three times and the screen hasn't changed. Try a different element, or call could_not with what's blocking you.") }
                return try await tool.run(d)
            }
        }
        let system = """
        You are Hands, the part of Brownie that acts on the user's Mac, one careful step at a time. You see the frontmost app as a numbered accessibility tree and act with tools.

        FIRST, always: call `plan` with 2–6 short steps in the user's own words ("Open Chrome", "Go to amazon.com", "Search for iPhone", "Open the first result", "Add it to the cart — then stop for you"). The user watches this list. When a step is complete, call `step_done` with its number and a few words on what you saw. Never skip the plan.

        HOW TO ACT. Prefer the skills: `open_url` for any web page (it opens the browser, goes there and waits for the page), `open_chat` for a WhatsApp or Messages conversation (it opens and verifies the right chat), `type_message` to put words in a chat's message box. Otherwise: `screen` to see, `find` to locate an element by its words instead of reading the whole tree, `press` numbered elements, `set_value` for text fields, `type` at the focus. After acting, confirm with `find` or `wait_for` — `wait_for` waits until something appears; do not `wait` blindly. Every result tells you what actually happened (which element, whether the text landed, the window's title now): read it, and if it didn't land, do it differently rather than again.

        The one rule you can never break: you do not send, pay, submit, delete, purchase, post or transfer. When the next step is one of those, stop, call `need_user` with what is ready, and let the user press it. If the request itself is to send something, get everything in place and stop the same way.

        Stay inside the apps the task names. Change app only with `open_app` — never ⌘Tab, Spotlight or ⌘Q. If something the task needs isn't there (an app, a chat, a page), call `could_not` and say what was missing; do not look for another way round it. Never open Terminal, System Settings or anything that changes the Mac itself. Never enter passwords, card numbers or codes; call `need_user`.
        Finish with `done` (one line on what is now true on the screen) or `could_not` (what blocked you).

        What Brownie knows that may help (from the user's private notes):
        \(context)
        """
        do {
            let r = try await brain.run(AgentTask(system: system, input: goal, effort: effort, maxTurns: policy.maxSteps, timeout: policy.timeout), tools: tools) { e in
                switch e {
                case .toolCall(let name, let summary):
                    self.log.info("→ \(name) \(summary.prefix(60))")
                    let args = (try? JSONSerialization.jsonObject(with: Data(summary.utf8))) as? [String: Any] ?? [:]
                    if name == "plan", let steps = HandsJourney.validate((args["steps"] as? [String]) ?? []) { onEvent(.plan(steps)) }
                    else if name == "step_done" { onEvent(.stepDone(args["n"] as? Int ?? Int(args["n"] as? String ?? "") ?? 0, args["note"] as? String ?? "")) }
                    else { Task { let line = await self.narrate(name, summary); onEvent(.step(line)) } }
                case .toolResult(let name, let summary): self.log.info("← \(name): \(summary.prefix(60))")
                case .message(let m):
                    // The brain's own narration ("I'll open Gmail next") is the best context there is.
                    self.log.info("says: \(m.prefix(100))")
                    let line = m.trimmingCharacters(in: .whitespacesAndNewlines); if !line.isEmpty { onEvent(.step(String(line.prefix(140)))) }
                default: break
                }
            }
            log.info("loop ended after \(r.turns) turns")
        } catch is CancellationError { let o = await box.outcome; log.info("loop ended by a tool: \(String(describing: o))"); return o ?? .stopped }
        catch BrainError.cancelled { return await box.outcome ?? .stopped }
        catch { log.warn("loop failed: \(error)"); return await box.outcome ?? .couldNot("\(error)") }
        return await box.outcome ?? .couldNot("finished without saying so")
    }

    private func makeTools(box: OutcomeBox, goal: String) -> [Tool] {
        func arg(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }
        return [
            Tool(name: "plan", description: "Your plan for this task: 2–6 short steps in the user's words. Call this first, once.", parametersSchema: #"{"type":"object","properties":{"steps":{"type":"array","items":{"type":"string"}}},"required":["steps"]}"#) { d in
                let steps = HandsJourney.validate((arg(d)["steps"] as? [String]) ?? [])
                return steps == nil ? "A plan is 2 to 6 distinct steps — try again." : "Plan noted: " + steps!.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " ")
            },
            Tool(name: "step_done", description: "A step of the plan is complete. n is its number; note is a few words on what you saw.", parametersSchema: #"{"type":"object","properties":{"n":{"type":"integer"},"note":{"type":"string"}},"required":["n"]}"#) { d in
                "step \(arg(d)["n"] as? Int ?? 0) marked done"
            },
            Tool(name: "screen", description: "The frontmost app's UI as a numbered tree (capped; use find for something specific).", parametersSchema: #"{"type":"object","properties":{}}"#) { _ in
                await self.snapshotText()
            },
            Tool(name: "find", description: "Elements whose label or value contains these words, with their numbers. Cheaper and surer than reading the whole tree.", parametersSchema: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#) { d in
                let q = arg(d)["text"] as? String ?? ""
                guard let snap = await self.snap() else { return "(no frontmost window)" }
                let hits = snap.matching(q)
                return hits.isEmpty ? "nothing on screen says “\(q)” (window: \(snap.window))" : hits.prefix(12).map { "[\($0.id)] \($0.role) “\($0.title)”" + ($0.value.isEmpty ? "" : " = \($0.value.prefix(60))") }.joined(separator: "\n")
            },
            Tool(name: "wait_for", description: "Wait until something with these words is on screen (up to 10 s). Use this instead of wait.", parametersSchema: #"{"type":"object","properties":{"text":{"type":"string"},"seconds":{"type":"number"}},"required":["text"]}"#) { d in
                let a = arg(d); let q = a["text"] as? String ?? ""; let limit = min(10, a["seconds"] as? Double ?? 6)
                let started = Date()
                while Date().timeIntervalSince(started) < limit {
                    if let snap = await self.snap(250), snap.contains(q) { return "“\(q)” is on screen after \(Int(Date().timeIntervalSince(started)))s (window: \(snap.window))" }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                let w = await self.windowTitle()
                return "“\(q)” did not appear within \(Int(limit))s — window is “\(w)”. Look with screen or find before trying something else."
            },
            Tool(name: "open_url", description: "Go to a web page: opens the browser, enters the address, waits for the page. Use for anything on the web.", parametersSchema: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}"#) { d in
                await self.openURL(BrowserSkill.normalise(arg(d)["url"] as? String ?? ""))
            },
            Tool(name: "open_chat", description: "Open a conversation in WhatsApp or Messages by the person's name and check the right chat is showing.", parametersSchema: #"{"type":"object","properties":{"app":{"type":"string","enum":["WhatsApp","Messages"]},"name":{"type":"string"}},"required":["app","name"]}"#) { d in
                let a = arg(d); return await self.openChat(app: a["app"] as? String ?? "WhatsApp", name: a["name"] as? String ?? "")
            },
            Tool(name: "type_message", description: "Put text in the open chat's message box, without sending. Reads it back to confirm.", parametersSchema: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#) { d in
                await self.typeMessage(arg(d)["text"] as? String ?? "")
            },
            Tool(name: "look", description: "A screenshot of the frontmost window (needs Screen Recording). Use when the tree isn't enough, e.g. in Electron or web apps.", parametersSchema: #"{"type":"object","properties":{}}"#) { _ in
                guard let jpeg = await MainActor.run(body: { ScreenCapture.frontmostWindowJPEG() }) else { return ToolOutput("Screen Recording isn't granted — work from the tree (screen).") }
                return ToolOutput("Screenshot attached.", imageJPEG: jpeg)
            },
            Tool(name: "list_apps", description: "Running apps.", parametersSchema: #"{"type":"object","properties":{}}"#) { _ in
                await MainActor.run { NSWorkspace.shared.runningApplications.compactMap { $0.activationPolicy == .regular ? $0.localizedName : nil }.joined(separator: ", ") }
            },
            Tool(name: "open_app", description: "Open or activate an app by name (the only way to switch apps).", parametersSchema: #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#) { d in
                let name = arg(d)["name"] as? String ?? ""
                if HandsGuard.isOffLimits(app: name, goal: goal) { return "STOP: \(name) is off limits for this task — stay in the apps the task names, or call could_not." }
                let ok = await MainActor.run { AppLauncher.open(name) }
                try? await Task.sleep(nanoseconds: 800_000_000)
                return ok ? "opened \(name)" : "could not find an app called \(name) — if it isn't on this Mac, call could_not rather than looking for other ways"
            },
            Tool(name: "press", description: "Press/activate a numbered element (buttons, menu items, links, rows).", parametersSchema: #"{"type":"object","properties":{"id":{"type":"integer"}},"required":["id"]}"#) { d in
                let id = arg(d)["id"] as? Int ?? 0
                return await self.press(id, box: box)
            },
            Tool(name: "set_value", description: "Put text into a numbered text field or area (replaces its content).", parametersSchema: #"{"type":"object","properties":{"id":{"type":"integer"},"text":{"type":"string"}},"required":["id","text"]}"#) { d in
                let a = arg(d); return await self.setValue(a["id"] as? Int ?? 0, a["text"] as? String ?? "")
            },
            Tool(name: "type", description: "Type text at the current focus.", parametersSchema: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#) { d in
                let t = arg(d)["text"] as? String ?? ""
                guard await self.canType() else { return "the app in front has no window ready for typing — press the field you mean (find it first), or use set_value" }
                await MainActor.run { VirtualInput.type(t) }
                try? await Task.sleep(nanoseconds: 300_000_000)
                let f = await self.focused()
                guard let f else { return "typed \(t.count) characters, but nothing has keyboard focus — the text went nowhere. Press the field first, or use set_value." }
                return TypingCheck.landed(expected: t, value: f.value) ? "typed into \(f.role) “\(f.title)” — it now reads “\(f.value.prefix(60))”" : "typed, but \(f.role) “\(f.title)” reads “\(f.value.prefix(40))” — the text did not land. Use set_value on it, or press it and try once more."
            },
            Tool(name: "key", description: "Press a key combo, e.g. cmd+n, return, tab, escape.", parametersSchema: #"{"type":"object","properties":{"combo":{"type":"string"}},"required":["combo"]}"#) { d in
                let c = arg(d)["combo"] as? String ?? ""
                if HandsGuard.isContextSwitch(c) { return "STOP: \(c) switches or closes apps; Hands doesn't use it. Use open_app to change app, or press the element you need." }
                if ["return", "enter"].contains(c.lowercased()), await self.focusLooksIrreversible() { await box.set(.pausedForUser("Ready — press Return when you want to send")); await self.endLoop(); return "STOP: Return would send; left to the user" }
                await MainActor.run { VirtualInput.key(c) }; return "pressed \(c)"
            },
            Tool(name: "click", description: "Click a screen point (last resort; moves the pointer).", parametersSchema: #"{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"}},"required":["x","y"]}"#) { d in
                let a = arg(d); await MainActor.run { VirtualInput.click(CGPoint(x: a["x"] as? Double ?? 0, y: a["y"] as? Double ?? 0)) }; return "clicked"
            },
            Tool(name: "wait", description: "Wait up to 3 s. Only when wait_for has nothing to wait for.", parametersSchema: #"{"type":"object","properties":{"seconds":{"type":"number"}},"required":[]}"#) { d in
                let s = min(3, arg(d)["seconds"] as? Double ?? 1); try? await Task.sleep(nanoseconds: UInt64(s * 1e9))
                let w = await self.windowTitle()
                return "waited \(Int(s))s · window is “\(w)” (prefer wait_for next time)"
            },
            Tool(name: "need_user", description: "Stop before an irreversible step and tell the user what is ready.", parametersSchema: #"{"type":"object","properties":{"what":{"type":"string"}},"required":["what"]}"#) { d in
                await box.set(.pausedForUser(arg(d)["what"] as? String ?? "Ready for you")); await self.endLoop(); return "paused for the user"
            },
            Tool(name: "done", description: "The task is complete.", parametersSchema: #"{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"]}"#) { d in
                await box.set(.done(arg(d)["summary"] as? String ?? "done")); await self.endLoop(); return "done"
            },
            Tool(name: "could_not", description: "The task cannot be completed.", parametersSchema: #"{"type":"object","properties":{"reason":{"type":"string"}},"required":["reason"]}"#) { d in
                await box.set(.couldNot(arg(d)["reason"] as? String ?? "unknown")); await self.endLoop(); return "recorded"
            },
        ]
    }

    private func snap(_ max: Int = 400) -> UISnapshot? { session.snapshot(maxElements: max) }
    private func windowTitle() -> String { session.snapshot(maxElements: 10)?.window ?? "?" }
    private func focused() -> UISnapshot.Element? { session.focusedTextElement() }
    private func canType() -> Bool { session.hasKeyWindow() }
    private func narrate(_ tool: String, _ args: String) -> String { HandsNarrator.line(tool: tool, args: args, label: { session.titleOf($0) }) }
    private func snapshotText() -> String { session.snapshot()?.text ?? "(no frontmost window)" }
    private func endLoop() { task?.cancel() }

    private func press(_ id: Int, box: OutcomeBox) async -> String {
        let title = session.titleOf(id).lowercased()
        if policy.alwaysAskBefore.contains(where: { title.contains($0) }) {
            await box.set(.pausedForUser("Ready — the “\(session.titleOf(id))” button is yours to press"))
            endLoop()
            return "STOP: “\(session.titleOf(id))” is irreversible; Hands never presses it. Call need_user now."
        }
        let label = session.titleOf(id), role = session.snapshotRole(id)
        guard session.perform("Press", on: id) else { return "could not press [\(id)] \(role) “\(label)” — it may not be pressable; try click on its frame" }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let w = session.snapshot(maxElements: 10)?.window ?? "?"
        return "pressed [\(id)] \(role) “\(label)” · window now “\(w)”"
    }

    // MARK: skills

    /// The browser skill: the page, not the keystrokes. Waits for the title to change so the next step sees the real page.
    private func openURL(_ url: String) async -> String {
        let front = await MainActor.run { NSWorkspace.shared.frontmostApplication?.localizedName ?? "" }
        let browser = BrowserSkill.isBrowser(front) ? front : "Google Chrome"
        guard let target = URL(string: url), let appURL = AppLauncher.locate(browser) ?? AppLauncher.locate("Safari") else { return "no browser found — could_not" }
        let before = windowTitle()
        // The browser opens the address itself — no keystrokes, nothing to land in the wrong window.
        let opened: Bool = await withCheckedContinuation { c in
            NSWorkspace.shared.open([target], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { app, error in c.resume(returning: error == nil && app != nil) }
        }
        guard opened else { return "the browser refused to open \(url)" }
        let started = Date()
        while Date().timeIntervalSince(started) < 12 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let frontNow = await MainActor.run { NSWorkspace.shared.frontmostApplication?.localizedName ?? "" }
            guard BrowserSkill.isBrowser(frontNow) else { continue }
            let title = windowTitle()
            if BrowserSkill.loaded(title: title, before: before) { return "\(frontNow) is showing “\(title)”" }
        }
        return "opened \(url) in \(browser) but after 12 s the window is still “\(windowTitle())” — check with find or screen"
    }

    /// The chat skill: the URL scheme with the number from Contacts, then the header checked. Never types.
    private func openChat(app: String, name: String) async -> String {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return "which chat? give a name" }
        let isWA = app.lowercased().contains("whatsapp")
        let phone = ContactLookup.phone(for: clean)
        if isWA, let phone, let u = URL(string: "whatsapp://send?phone=\(phone)") { await MainActor.run { NSWorkspace.shared.open(u) } }
        else if !isWA, let phone, let u = URL(string: "imessage://\(phone)") { await MainActor.run { NSWorkspace.shared.open(u) } }
        else { _ = await MainActor.run { AppLauncher.open(isWA ? "WhatsApp" : "Messages") } }
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let snap = snap(), ChatWindowCheck.headerNames(snap, person: clean) { return "\(isWA ? "WhatsApp" : "Messages") is showing the chat with \(clean)" }
        }
        if phone == nil { return "\(isWA ? "WhatsApp" : "Messages") is open but Contacts has no number for “\(clean)”, so the chat wasn't opened for you. Use find “\(clean)” in the chat list and press it, then check the header with find." }
        return "opened the link for \(clean) (+\(phone!)) but the header doesn't show that name yet — check with find “\(clean)” before typing anything"
    }

    /// The message skill: finds the composer, types, reads it back. Sending stays with the user.
    private func typeMessage(_ text: String) async -> String {
        guard let snap = snap(), let box = ChatWindowCheck.composer(in: snap) else { return "no message box on screen — open the chat first (open_chat), then try again" }
        if await RobustTyper.type(text, into: box.id, session: session, log: log) { return "the message is in the box (\(box.role) “\(box.title)”), not sent — call need_user when the task is done" }
        return "couldn't get the text into the message box — the field reads “\(session.value(of: box.id).prefix(40))”"
    }

    private func setValue(_ id: Int, _ text: String) -> String {
        session.setValue(text, on: id) ? "set value on \(id)" : "could not set value on \(id) (press it, then use type)"
    }

    private func focusLooksIrreversible() -> Bool {
        guard let snap = session.snapshot(maxElements: 120) else { return false }
        return snap.elements.contains { e in e.role == "Button" && policy.alwaysAskBefore.contains { e.title.lowercased().contains($0) } } && snap.app.lowercased().contains("messages")
    }
}

actor OutcomeBox { var outcome: Hands.Outcome?; func set(_ o: Hands.Outcome) { outcome = o } }


/// Frontmost-window capture, downscaled for the brain. Returns nil without Screen Recording.
@MainActor
enum ScreenCapture {
    static func frontmostWindowJPEG(maxSide: CGFloat = 1400) -> Data? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        guard let win = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && (($0[kCGWindowLayer as String] as? Int) ?? 0) == 0 }),
              let id = win[kCGWindowNumber as String] as? CGWindowID,
              let img = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]) else { return nil }
        let scale = min(1, maxSide / CGFloat(max(img.width, img.height)))
        let size = NSSize(width: CGFloat(img.width) * scale, height: CGFloat(img.height) * scale)
        let out = NSImage(size: size)
        out.lockFocus(); NSImage(cgImage: img, size: size).draw(in: NSRect(origin: .zero, size: size)); out.unlockFocus()
        guard let t = out.tiffRepresentation, let r = NSBitmapImageRep(data: t) else { return nil }
        return r.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}
