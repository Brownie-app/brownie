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
        public var maxSteps = 50
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
    private var stallGuard = HandsGuard.StallGuard()
    private var summary = HandsRunSummary()
    private func repeats(_ tool: String, _ args: Data) -> Bool { repeatGuard.record(tool: tool, args: String(decoding: args, as: UTF8.self)) }
    private func stalled(_ tool: String, _ args: Data, _ result: String) -> String? { stallGuard.record(tool: tool, action: narrate(tool, String(decoding: args, as: UTF8.self)), result: result) }
    private func count(_ tool: String) { summary.record(tool) }

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
        repeatGuard = HandsGuard.RepeatGuard(); stallGuard = HandsGuard.StallGuard(); summary = HandsRunSummary()
        session.screenMap = nil
        let tools = makeTools(box: box, goal: goal).map { tool in
            // Two rails around every tool: a step repeated three times in a row is a loop, and five actions the screen
            // ignored mean it has stopped answering. The full result goes to the log, so cause and effect read in one line.
            Tool(name: tool.name, description: tool.description, parametersSchema: tool.parametersSchema) { d in
                await self.count(tool.name)
                if await self.repeats(tool.name, d) { return ToolOutput("STOP: you have done exactly this three times and the screen hasn't changed. Try a different element, or call could_not with what's blocking you.") }
                let out = try await tool.run(d)
                self.log.info("← \(tool.name): \(out.text.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(220))")
                if let why = await self.stalled(tool.name, d, out.text) {
                    await box.set(.couldNot(why))
                    return ToolOutput("STOP: \(why). The run is over.", endsRun: true)
                }
                return out
            }
        }
        let system = """
        You are Hands, the part of Brownie that acts on the user's Mac, one careful step at a time. You see the frontmost app as a numbered accessibility tree and act with tools.

        FIRST, always: call `plan` with 2–6 short steps in the user's own words ("Open Chrome", "Go to amazon.com", "Search for iPhone", "Open the first result", "Add it to the cart — then stop for you"). The user watches this list. When a step is complete, call `step_done` with its number and a few words on what you saw. Never skip the plan.

        HOW TO ACT. Reach for the tools that do a whole step in one call, in this order:
        1. `open_url` for any web page, `search_web` for a search on a site (amazon, google, youtube, flipkart, wikipedia, github, linkedin, x, reddit, maps — or any other site), `open_chat` for a WhatsApp or Messages conversation, `type_message` for a chat's message box. These open, act and wait for the page themselves.
        2. `press_text` to press anything by its words, and `type_into` to put text in a field by its label. One call finds the element, acts on it and checks what happened — you never need `find` before them.
        3. `find` and then `press` by number only when press_text cannot tell two candidates apart (it lists them; press the number you mean). `set_value` for a numbered field.
        4. `look` and then `click` only after press_text has failed twice on the same thing. `look` returns a screenshot of the window; `click` takes coordinates in that screenshot, not on the screen.
        On a web page a product or a result is a Link, and "the first result" means the first Link whose words match after the search box: press_text with the result's own words and role "link". If nothing matches, `scroll` down and try again — scroll then press_text is two calls, not more. Never `type` without a field in focus; `type_into` names the field. `key` is for Return, Escape and shortcuts, never for moving around a page.
        Every result says what actually happened: which element, whether the text landed, what changed on screen. Read it. When a result says nothing changed, do something different — other words, another role, a scroll, a look — never the same call again. Confirm a page with `wait_for` (it waits until words appear); do not `wait` blindly.

        The one rule you can never break: you do not send, pay, submit, delete, purchase, post or transfer. When the next step is one of those, stop, call `need_user` with what is ready, and let the user press it. If the request itself is to send something, get everything in place and stop the same way.

        Stay inside the apps the task names. Change app only with `open_app` — never ⌘Tab, Spotlight or ⌘Q. If something the task needs isn't there (an app, a chat, a page), call `could_not` and say what was missing; do not look for another way round it. Never open Terminal, System Settings or anything that changes the Mac itself. Never enter passwords, card numbers or codes; call `need_user`.
        Finish with `done` (one line on what is now true on the screen) or `could_not` (what blocked you).

        What Brownie knows that may help (from the user's private notes):
        \(context)
        """
        var turns: Int?
        let outcome: Outcome
        do {
            let r = try await brain.run(AgentTask(system: system, input: goal, effort: effort, maxTurns: policy.maxSteps, timeout: policy.timeout), tools: tools) { e in
                switch e {
                case .toolCall(let name, let summary):
                    self.log.info("→ \(name) \(summary.prefix(80))")
                    let args = (try? JSONSerialization.jsonObject(with: Data(summary.utf8))) as? [String: Any] ?? [:]
                    if name == "plan", let steps = HandsJourney.validate((args["steps"] as? [String]) ?? []) { onEvent(.plan(steps)) }
                    else if name == "step_done" { onEvent(.stepDone(args["n"] as? Int ?? Int(args["n"] as? String ?? "") ?? 0, args["note"] as? String ?? "")) }
                    else { Task { let line = await self.narrate(name, summary); onEvent(.step(line)) } }
                case .message(let m):
                    // The brain's own narration ("I'll open Gmail next") is the best context there is.
                    self.log.info("says: \(m.prefix(100))")
                    let line = m.trimmingCharacters(in: .whitespacesAndNewlines); if !line.isEmpty { onEvent(.step(String(line.prefix(140)))) }
                default: break
                }
            }
            turns = r.turns
            outcome = await box.outcome ?? .couldNot("finished without saying so")
        } catch is CancellationError { outcome = await box.outcome ?? .stopped }
        catch BrainError.cancelled { outcome = await box.outcome ?? .stopped }
        catch { log.warn("loop failed: \(error)"); outcome = await box.outcome ?? .couldNot("\(error)") }
        log.info(summary.line(turns: turns, outcome: String(String(describing: outcome).prefix(120))))
        return outcome
    }

    private func makeTools(box: OutcomeBox, goal: String) -> [Tool] {
        func arg(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }
        func int(_ v: Any?, _ fallback: Int) -> Int {
            if let i = v as? Int { return i }
            if let d = v as? Double, d.isFinite { return Int(d) }
            return Int(v as? String ?? "") ?? fallback
        }
        func num(_ v: Any?) -> Double { (v as? Double) ?? Double(int(v, 0)) }
        return [
            Tool(name: "plan", description: "Your plan for this task: 2–6 short steps in the user's words. Call this first, once.", parametersSchema: #"{"type":"object","properties":{"steps":{"type":"array","items":{"type":"string"}}},"required":["steps"]}"#) { d in
                let steps = HandsJourney.validate((arg(d)["steps"] as? [String]) ?? [])
                return steps == nil ? "A plan is 2 to 6 distinct steps — try again." : "Plan noted: " + steps!.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " ")
            },
            Tool(name: "step_done", description: "A step of the plan is complete. n is its number; note is a few words on what you saw.", parametersSchema: #"{"type":"object","properties":{"n":{"type":"integer"},"note":{"type":"string"}},"required":["n"]}"#) { d in
                "step \(int(arg(d)["n"], 0)) marked done"
            },
            Tool(name: "open_url", description: "Go to a web page: opens the browser, enters the address, waits for the page. Use for anything on the web.", parametersSchema: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}"#) { d in
                await self.openURL(BrowserSkill.normalise(arg(d)["url"] as? String ?? ""))
            },
            Tool(name: "search_web", description: "Search a site in one step: opens the site's own results page for the query (amazon, amazon.in, google, youtube, flipkart, wikipedia, github, linkedin, x, reddit, maps, or any other site) and waits for it.", parametersSchema: #"{"type":"object","properties":{"site":{"type":"string"},"query":{"type":"string"}},"required":["site","query"]}"#) { d in
                let a = arg(d); return await self.openURL(BrowserSkill.searchURL(site: a["site"] as? String ?? "google", query: a["query"] as? String ?? ""))
            },
            Tool(name: "open_chat", description: "Open a conversation in WhatsApp or Messages by the person's name and check the right chat is showing.", parametersSchema: #"{"type":"object","properties":{"app":{"type":"string","enum":["WhatsApp","Messages"]},"name":{"type":"string"}},"required":["app","name"]}"#) { d in
                let a = arg(d); return await self.openChat(app: a["app"] as? String ?? "WhatsApp", name: a["name"] as? String ?? "")
            },
            Tool(name: "type_message", description: "Put text in the open chat's message box, without sending. Reads it back to confirm.", parametersSchema: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#) { d in
                await self.typeMessage(arg(d)["text"] as? String ?? "")
            },
            Tool(name: "press_text", description: "Press the thing that says these words — finds it, presses or clicks it, and reports what changed. role narrows to link, button or field; nth picks the 2nd, 3rd… match when several say the same.", parametersSchema: #"{"type":"object","properties":{"text":{"type":"string"},"nth":{"type":"integer"},"role":{"type":"string","enum":["link","button","field","any"]}},"required":["text"]}"#) { d in
                let a = arg(d)
                return await self.pressText(a["text"] as? String ?? "", nth: int(a["nth"], 1), role: PressPick.Role(rawValue: (a["role"] as? String ?? "any").lowercased()) ?? .any, box: box)
            },
            Tool(name: "type_into", description: "Put text in a field by its label or placeholder (e.g. “Search Amazon”): finds it, focuses it, enters the text and reads it back. replace (default true) clears what was there.", parametersSchema: #"{"type":"object","properties":{"field":{"type":"string"},"text":{"type":"string"},"replace":{"type":"boolean"}},"required":["field","text"]}"#) { d in
                let a = arg(d); return await self.typeInto(field: a["field"] as? String ?? "", text: a["text"] as? String ?? "", replace: a["replace"] as? Bool ?? true)
            },
            Tool(name: "find", description: "Elements whose label or value contains these words, with their numbers — for when press_text lists two candidates and you need to pick.", parametersSchema: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#) { d in
                let q = arg(d)["text"] as? String ?? ""
                let hits = await self.search(q)
                let w = await self.windowTitle()
                // links and buttons first: those are what gets pressed
                let ranked = hits.sorted { a, b in Self.rank(a.role) < Self.rank(b.role) }
                return ranked.isEmpty ? "nothing in this window says “\(q)” (window: \(w)) — try other words, or scroll down and look again" : PressPick.list(ranked)
            },
            Tool(name: "press", description: "Press a numbered element from find (buttons, menu items, links, rows). Reports what changed.", parametersSchema: #"{"type":"object","properties":{"id":{"type":"integer"}},"required":["id"]}"#) { d in
                await self.press(int(arg(d)["id"], 0), box: box)
            },
            Tool(name: "set_value", description: "Put text into a numbered text field or area (replaces its content).", parametersSchema: #"{"type":"object","properties":{"id":{"type":"integer"},"text":{"type":"string"}},"required":["id","text"]}"#) { d in
                let a = arg(d); return await self.setValue(int(a["id"], 0), a["text"] as? String ?? "")
            },
            Tool(name: "scroll", description: "Scroll the window a page at a time (Page Down/Up), amount 1–5, and report what is on screen now. Use before searching again when something is below the fold.", parametersSchema: #"{"type":"object","properties":{"direction":{"type":"string","enum":["down","up"]},"amount":{"type":"integer"}},"required":["direction"]}"#) { d in
                let a = arg(d); return await self.scroll(up: (a["direction"] as? String ?? "down").lowercased() == "up", amount: int(a["amount"], 1))
            },
            Tool(name: "wait_for", description: "Wait until something with these words is on screen (up to 10 s). Use this instead of wait.", parametersSchema: #"{"type":"object","properties":{"text":{"type":"string"},"seconds":{"type":"number"}},"required":["text"]}"#) { d in
                let a = arg(d); let q = a["text"] as? String ?? ""; let limit = min(10, a["seconds"] as? Double ?? 6)
                let started = Date()
                while Date().timeIntervalSince(started) < limit {
                    // the title first — one call — and only then a short search of the page
                    let w = await self.windowTitle()
                    let inTitle = w.lowercased().contains(q.lowercased())
                    let hit = inTitle ? [] : await self.search(q, limit: 1, budget: 1)
                    if inTitle || !hit.isEmpty { return "“\(q)” is on screen after \(Int(Date().timeIntervalSince(started)))s (window: \(w))" }
                    try? await Task.sleep(nanoseconds: 700_000_000)
                }
                let w = await self.windowTitle()
                return "“\(q)” did not appear within \(Int(limit))s — window is “\(w)”. Look with find or screen before trying something else."
            },
            Tool(name: "screen", description: "The frontmost app's UI as a numbered tree (capped; use press_text or find for something specific).", parametersSchema: #"{"type":"object","properties":{}}"#) { _ in
                await self.snapshotText()
            },
            Tool(name: "look", description: "A screenshot of the frontmost window (needs Screen Recording), for when the tree isn't enough. click then takes coordinates in this image.", parametersSchema: #"{"type":"object","properties":{}}"#) { _ in
                guard let shot = await MainActor.run(body: { ScreenCapture.frontmostWindow() }) else { return ToolOutput("Screen Recording isn't granted — work from the tree (screen, find, press_text).") }
                await self.remember(shot.map)
                let w = await self.windowTitle()
                return ToolOutput(shot.map.note + " Window: “\(w)”.", imageJPEG: shot.jpeg)
            },
            Tool(name: "click", description: "Click a point in the last screenshot from look (image coordinates). Last resort; reports where it clicked and what changed.", parametersSchema: #"{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"}},"required":["x","y"]}"#) { d in
                let a = arg(d); return await self.click(CGPoint(x: num(a["x"]), y: num(a["y"])))
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
            Tool(name: "type", description: "Type text at the current focus (only when a field already has focus; prefer type_into).", parametersSchema: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#) { d in
                let t = arg(d)["text"] as? String ?? ""
                guard await self.canType() else { return "the app in front has no window ready for typing — use type_into with the field's label" }
                await MainActor.run { VirtualInput.type(t) }
                try? await Task.sleep(nanoseconds: 300_000_000)
                let f = await self.focused()
                guard let f else { return "typed \(t.count) characters, but nothing has keyboard focus — the text went nowhere. Use type_into with the field's label." }
                return TypingCheck.landed(expected: t, value: f.value) ? "typed into \(f.role) “\(f.title)” — it now reads “\(f.value.prefix(60))”" : "typed, but \(f.role) “\(f.title)” reads “\(f.value.prefix(40))” — the text did not land. Use type_into with the field's label."
            },
            Tool(name: "key", description: "Press a key combo, e.g. cmd+n, return, tab, escape. For paging use scroll.", parametersSchema: #"{"type":"object","properties":{"combo":{"type":"string"}},"required":["combo"]}"#) { d in
                let c = arg(d)["combo"] as? String ?? ""
                if HandsGuard.isContextSwitch(c) { return ToolOutput("STOP: \(c) switches or closes apps; Hands doesn't use it. Use open_app to change app, or press the element you need.") }
                guard VirtualInput.parse(c) != nil else { return ToolOutput("“\(c)” is not a key Hands can press — use return, tab, escape, space, delete, the arrows, pagedown/pageup, or cmd/shift/alt/ctrl with a letter; use scroll for paging") }
                if ["return", "enter"].contains(c.lowercased()), await self.focusLooksIrreversible() { await box.set(.pausedForUser("Ready — press Return when you want to send")); return ToolOutput("STOP: Return would send; left to the user", endsRun: true) }
                let before = await self.signature()
                await MainActor.run { VirtualInput.key(c) }
                try? await Task.sleep(nanoseconds: 500_000_000)
                let after = await self.signature()
                let diff = after.changes(since: before)
                return ToolOutput("pressed \(c)" + (diff.isEmpty ? " · \(after.line)" : " → " + diff.joined(separator: "; ")))
            },
            Tool(name: "wait", description: "Wait up to 3 s. Only when wait_for has nothing to wait for.", parametersSchema: #"{"type":"object","properties":{"seconds":{"type":"number"}},"required":[]}"#) { d in
                let s = min(3, arg(d)["seconds"] as? Double ?? 1); try? await Task.sleep(nanoseconds: UInt64(s * 1e9))
                let w = await self.windowTitle()
                return "waited \(Int(s))s · window is “\(w)” (prefer wait_for next time)"
            },
            Tool(name: "need_user", description: "Stop before an irreversible step and tell the user what is ready.", parametersSchema: #"{"type":"object","properties":{"what":{"type":"string"}},"required":["what"]}"#) { d in
                await box.set(.pausedForUser(arg(d)["what"] as? String ?? "Ready for you")); return ToolOutput("paused for the user", endsRun: true)
            },
            Tool(name: "done", description: "The task is complete.", parametersSchema: #"{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"]}"#) { d in
                await box.set(.done(arg(d)["summary"] as? String ?? "done")); return ToolOutput("done", endsRun: true)
            },
            Tool(name: "could_not", description: "The task cannot be completed.", parametersSchema: #"{"type":"object","properties":{"reason":{"type":"string"}},"required":["reason"]}"#) { d in
                await box.set(.couldNot(arg(d)["reason"] as? String ?? "unknown")); return ToolOutput("recorded", endsRun: true)
            },
        ]
    }

    private func snap(_ max: Int = 400) -> UISnapshot? { session.snapshot(maxElements: max) }
    private func windowTitle() -> String { let t = session.windowTitle(); return t.isEmpty ? "?" : t }
    private func focused() -> UISnapshot.Element? { session.focusedTextElement() }
    private func canType() -> Bool { session.hasKeyWindow() }
    private func search(_ q: String, limit: Int = 12, budget: TimeInterval = 4) -> [UISnapshot.Element] { session.search(q, limit: limit, budget: budget) }
    private func signature(at p: CGPoint? = nil) -> ScreenSignature { session.signature(at: p) }
    private func remember(_ map: ScreenMap) { session.screenMap = map }
    static func rank(_ role: String) -> Int { switch role { case "Link", "Button": return 0; case "TextField", "TextArea", "SearchField", "ComboBox", "PopUpButton", "MenuItem", "Row", "Cell": return 1; case "Heading", "StaticText": return 2; default: return 3 } }
    private func narrate(_ tool: String, _ args: String) -> String { HandsNarrator.line(tool: tool, args: args, label: { session.titleOf($0) }) }
    private func snapshotText() -> String { session.snapshot()?.text ?? "(no frontmost window)" }
    private func irreversible(_ title: String) -> Bool { let t = title.lowercased(); return policy.alwaysAskBefore.contains { t.contains($0) } }

    // MARK: pressing — resolve once, act, verify

    private func press(_ id: Int, box: OutcomeBox) async -> ToolOutput {
        guard let r = session.resolve(id) else { return ToolOutput("there is no [\(id)] — find it first, or use press_text with its words") }
        if irreversible(r.desc.title) {
            await box.set(.pausedForUser("Ready — the “\(r.desc.title)” button is yours to press"))
            return ToolOutput("STOP: “\(r.desc.title)” is irreversible; Hands never presses it. Call need_user now.", endsRun: true)
        }
        return ToolOutput(await act(on: r, label: "[\(id)]"))
    }

    /// The one press path: AXPress on the resolved element when it has one, else a real click on the middle of the frame
    /// it was numbered with; then a cheap before/after signature says what happened. Reports use the description as
    /// numbered, never live reads — a dead reference would only answer "?".
    private func act(on r: AXSession.Resolved, label: String) async -> String {
        let desc = r.desc
        let probe: CGPoint? = desc.frame.width > 0 ? CGPoint(x: desc.frame.midX, y: desc.frame.midY) : nil
        let before = session.signature(at: probe)
        let axPress: Bool? = r.el.flatMap { desc.actions.contains("Press") ? session.press($0) : nil }
        let plan = PressPlan.decide(axPress: axPress, frame: desc.frame, window: session.windowBounds())
        switch plan {
        case .cannot(let why): return "could not press \(label) \(desc.role) “\(desc.title.prefix(70))” — \(why)"
        case .click(let p): await MainActor.run { VirtualInput.click(p) }
        case .pressed: break
        }
        try? await Task.sleep(nanoseconds: 600_000_000)
        let after = session.signature(at: probe)
        return PressOutcome.report(label: label, role: desc.role, title: desc.title, how: plan == .pressed ? .pressed : .clicked, before: before, after: after)
    }

    /// find + press + check in one call. Ranks the matches, takes the nth, and when nothing fits says what is there instead.
    private func pressText(_ text: String, nth: Int, role: PressPick.Role, box: OutcomeBox) async -> ToolOutput {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ToolOutput("press_text needs the words to press") }
        let hits = session.search(q, limit: 12)
        guard let pick = PressPick.choose(hits: hits, text: q, nth: nth, role: role) else {
            let w = windowTitle()
            let any = PressPick.rank(hits: hits, text: q, role: .any)
            if !any.isEmpty {
                let why = nth > 1 ? "there is no \(nth)\(HandsNarrator.ordinal(nth)) match for “\(q)”" : "nothing says “\(q)” as a \(role.rawValue)"
                return ToolOutput("\(why) — what does match (window “\(w)”):\n" + PressPick.list(any.prefix(5)) + "\npress one by its number, or press_text with its exact words, or scroll down and try again")
            }
            // the words may be split across elements: the longest one alone shows what is near
            let word = q.split(separator: " ").map(String.init).max(by: { $0.count < $1.count }) ?? q
            let near = word.count > 2 && word != q ? PressPick.rank(hits: session.search(word, limit: 8, budget: 2), text: word, role: .any) : []
            return ToolOutput("nothing on this window says “\(q)” (window “\(w)”)" + (near.isEmpty ? " — scroll down and try again, or use other words" : ". Things that say “\(word)”:\n" + PressPick.list(near.prefix(5)) + "\npress one by its number, or scroll down and try again"))
        }
        if irreversible(pick.title) {
            await box.set(.pausedForUser("Ready — the “\(pick.title)” button is yours to press"))
            return ToolOutput("STOP: “\(pick.title)” is irreversible; Hands never presses it. Call need_user now.", endsRun: true)
        }
        guard let r = session.resolve(pick.id) else { return ToolOutput("lost [\(pick.id)] right after finding it — try again") }
        let others = PressPick.rank(hits: hits, text: q, role: role).count - 1
        return ToolOutput(await act(on: r, label: "[\(pick.id)]") + (others > 0 ? " (\(others) more said “\(q)”; nth picks another)" : ""))
    }

    /// find the field + focus + enter + read back, in one call. Set the AX value where the field allows it (instant, and
    /// what native apps expect); fall back to keystrokes when it does not land.
    private func typeInto(field: String, text: String, replace: Bool) async -> String {
        let label = field.trimmingCharacters(in: .whitespacesAndNewlines)
        var pick = FieldPick.choose(hits: session.search(label, limit: 12), label: label)
        if pick == nil {
            // every text box on screen: the label may be near the field rather than on it, or there may be only one
            let all = ["textfield", "searchfield", "textarea", "combobox"].flatMap { session.search($0, limit: 6, budget: 1) }
            pick = FieldPick.choose(hits: all, label: label, relaxed: true)
            if pick == nil { return all.isEmpty ? "no text field on this window — is the page loaded? try wait_for or scroll" : "no field called “\(label)” — the fields on screen:\n" + PressPick.list(all.prefix(5)) + "\nuse type_into with one of these labels, or set_value with its number" }
        }
        guard let pick, let r = session.resolve(pick.id) else { return "lost the field right after finding it — try again" }
        let name = pick.title.isEmpty ? "\(pick.role) [\(pick.id)]" : "\(pick.title.prefix(50))"
        let mid = CGPoint(x: pick.frame.midX, y: pick.frame.midY)
        // focus: AXPress when it has one, else a click on its middle, then AXFocused for good measure
        let pressed = r.el.map { pick.actions.contains("Press") && session.press($0) } ?? false
        if !pressed, pick.frame.width > 0 { await MainActor.run { VirtualInput.click(mid) } }
        if let el = r.el { _ = session.focus(el) }
        try? await Task.sleep(nanoseconds: 250_000_000)
        // the AX value where the field allows it, else (or when that did not land) real keystrokes
        if let el = r.el, session.canSetValue(el), session.set(text, on: el) { try? await Task.sleep(nanoseconds: 300_000_000) }
        if !TypingCheck.landed(expected: text, value: readBack(r)) {
            if replace { await MainActor.run { VirtualInput.key("cmd+a") }; usleep(80_000) }
            await MainActor.run { VirtualInput.type(text) }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        let now = readBack(r)
        let focusNow = session.focusedTextElement()
        if TypingCheck.landed(expected: text, value: now) { return "typed “\(text.prefix(60))” into the \(name) field — it now reads “\(now.prefix(60))”" }
        if let f = focusNow, TypingCheck.landed(expected: text, value: f.value) { return "typed “\(text.prefix(60))” — it landed in \(f.role) “\(f.title.prefix(40))”, which now reads “\(f.value.prefix(60))”" }
        return "typed into the \(name) field but it reads “\(now.prefix(40))”" + (focusNow.map { " and focus is on \($0.role) “\($0.title.prefix(30))”" } ?? "") + " — the text did not land; press_text the field first, or try another label"
    }
    /// The field's value: the focused element when it is the same box (Chrome may have rebuilt it), else the resolved one.
    private func readBack(_ r: AXSession.Resolved) -> String {
        if let f = session.focusedTextElement(), FieldPick.roles.contains(f.role), f.title == r.desc.title || r.desc.title.isEmpty { return f.value }
        return r.el.map { session.value(of: $0) } ?? ""
    }

    /// A click from the last screenshot, mapped through where that screenshot sat; without one the numbers are screen points.
    private func click(_ raw: CGPoint) async -> String {
        let map = session.screenMap
        let p = map?.toScreen(raw) ?? raw
        if let map, !map.covers(raw) { return "(\(Int(raw.x)), \(Int(raw.y))) is outside the \(Int(map.imageSize.width))×\(Int(map.imageSize.height)) screenshot — call look again and use coordinates in that image" }
        let before = session.signature(at: p)
        await MainActor.run { VirtualInput.click(p) }
        try? await Task.sleep(nanoseconds: 600_000_000)
        let after = session.signature(at: p)
        let diff = after.changes(since: before)
        let whereTo = map == nil ? "clicked (\(Int(p.x)), \(Int(p.y))) as screen points — there was no screenshot to map from; call look first next time" : "clicked image (\(Int(raw.x)), \(Int(raw.y))) → screen (\(Int(p.x)), \(Int(p.y)))"
        return whereTo + (diff.isEmpty ? " but \(HandsGuard.stallMarker) — it may not be the thing to click; look again or use press_text" : " — the page changed (\(diff.joined(separator: "; ")))")
    }

    /// Page Down/Up on the frontmost window, then what is there now — so "scroll and find again" is one turn.
    private func scroll(up: Bool, amount: Int) async -> String {
        let n = max(1, min(5, amount))
        let bounds = session.windowBounds()
        let probe = bounds.map { CGPoint(x: $0.midX, y: $0.midY) }
        let before = session.signature(at: probe)
        for _ in 0..<n { await MainActor.run { VirtualInput.key(up ? "pageup" : "pagedown") }; try? await Task.sleep(nanoseconds: 150_000_000) }
        try? await Task.sleep(nanoseconds: 500_000_000)
        let after = session.signature(at: probe)
        let diff = after.changes(since: before)
        return "scrolled \(up ? "up" : "down")\(n > 1 ? " ×\(n)" : "")" + (diff.isEmpty ? " but \(HandsGuard.stallMarker) at the middle of the window — the page may be at its \(up ? "top" : "end"), or a field has the keys; press_text what you need" : " · \(after.line) · now press_text what you need")
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
        if phone == nil { return "\(isWA ? "WhatsApp" : "Messages") is open but Contacts has no number for “\(clean)”, so the chat wasn't opened for you. Use press_text “\(clean)” in the chat list, then check the header with find." }
        return "opened the link for \(clean) (+\(phone!)) but the header doesn't show that name yet — check with find “\(clean)” before typing anything"
    }

    /// The message skill: finds the composer, types, reads it back. Sending stays with the user.
    private func typeMessage(_ text: String) async -> String {
        guard let snap = snap(), let box = ChatWindowCheck.composer(in: snap) else { return "no message box on screen — open the chat first (open_chat), then try again" }
        if await RobustTyper.type(text, into: box.id, session: session, log: log) { return "the message is in the box (\(box.role) “\(box.title)”), not sent — call need_user when the task is done" }
        return "couldn't get the text into the message box — the field reads “\(session.value(of: box.id).prefix(40))”"
    }

    private func setValue(_ id: Int, _ text: String) -> String {
        session.setValue(text, on: id) ? "set value on \(id)" : "could not set value on \(id) — use type_into with the field's label"
    }

    private func focusLooksIrreversible() -> Bool {
        guard let snap = session.snapshot(maxElements: 120) else { return false }
        return snap.elements.contains { e in e.role == "Button" && policy.alwaysAskBefore.contains { e.title.lowercased().contains($0) } } && snap.app.lowercased().contains("messages")
    }
}

actor OutcomeBox { var outcome: Hands.Outcome?; func set(_ o: Hands.Outcome) { outcome = o } }


/// Frontmost-window capture, downscaled for the brain, with where it sat on screen so a click in the picture can be
/// mapped back. Returns nil without Screen Recording.
@MainActor
enum ScreenCapture {
    struct Shot: Sendable { let jpeg: Data; let map: ScreenMap }
    static func frontmostWindow(maxSide: CGFloat = 1400) -> Shot? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        guard let win = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && (($0[kCGWindowLayer as String] as? Int) ?? 0) == 0 }),
              let id = win[kCGWindowNumber as String] as? CGWindowID,
              let boundsDict = win[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: boundsDict),
              let img = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]) else { return nil }
        let scale = min(1, maxSide / CGFloat(max(img.width, img.height)))
        let size = NSSize(width: (CGFloat(img.width) * scale).rounded(), height: (CGFloat(img.height) * scale).rounded())
        let out = NSImage(size: size)
        out.lockFocus(); NSImage(cgImage: img, size: size).draw(in: NSRect(origin: .zero, size: size)); out.unlockFocus()
        guard let t = out.tiffRepresentation, let r = NSBitmapImageRep(data: t), let jpeg = r.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return nil }
        return Shot(jpeg: jpeg, map: ScreenMap(windowBounds: bounds, imageSize: size))
    }
}
