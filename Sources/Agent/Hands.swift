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
    public enum Event: Sendable { case step(String), paused(String), finished(Outcome) }

    private let brain: any AgenticBrain
    private let knowledge: any KnowledgeStore
    private let policy: Policy
    private let effort: Effort
    private let log = Log("hands")
    private var session = AXSession()
    private var task: Task<Outcome, Never>?

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
        let tools = makeTools(box: box)
        let system = """
        You are Hands, the part of Brownie that acts on the user's Mac. You see the frontmost app as a numbered accessibility tree and act with tools. Work step by step: call `screen` first, act, call `screen` again to confirm what changed. Prefer `press`/`set_value` on numbered elements over raw clicks and typing. Open apps with `open_app`. When the tree is thin (web pages, Electron apps), call `look` for a screenshot and use `click` with coordinates from it.

        The one rule you can never break: you do not send, pay, submit, delete, purchase, post or transfer. When the next step is one of those, stop, call `need_user` with what is ready, and let the user press it. If the user's request itself is to send something, get everything in place and then stop the same way.

        Never enter passwords, card numbers or codes. If a task needs them, call `need_user`.
        Call `done` with a one-line summary when the task is complete, or `could_not` with the reason if it can't be done.

        What Brownie knows that may help (from the user's private notes):
        \(context)
        """
        do {
            let r = try await brain.run(AgentTask(system: system, input: goal, effort: effort, maxTurns: policy.maxSteps, timeout: policy.timeout), tools: tools) { e in
                switch e {
                case .toolCall(let name, let summary): self.log.info("→ \(name) \(summary.prefix(60))"); onEvent(.step("\(name) \(summary)"))
                case .toolResult(let name, let summary): self.log.info("← \(name): \(summary.prefix(60))")
                case .message(let m): self.log.info("says: \(m.prefix(100))")
                default: break
                }
            }
            log.info("loop ended after \(r.turns) turns")
        } catch is CancellationError { let o = await box.outcome; log.info("loop ended by a tool: \(String(describing: o))"); return o ?? .stopped }
        catch BrainError.cancelled { return await box.outcome ?? .stopped }
        catch { log.warn("loop failed: \(error)"); return await box.outcome ?? .couldNot("\(error)") }
        return await box.outcome ?? .couldNot("finished without saying so")
    }

    private func makeTools(box: OutcomeBox) -> [Tool] {
        func arg(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }
        return [
            Tool(name: "screen", description: "The frontmost app's UI as a numbered tree.", parametersSchema: #"{"type":"object","properties":{}}"#) { _ in
                await self.snapshotText()
            },
            Tool(name: "look", description: "A screenshot of the frontmost window (needs Screen Recording). Use when the tree isn't enough, e.g. in Electron or web apps.", parametersSchema: #"{"type":"object","properties":{}}"#) { _ in
                guard let jpeg = await MainActor.run(body: { ScreenCapture.frontmostWindowJPEG() }) else { return ToolOutput("Screen Recording isn't granted — work from the tree (screen).") }
                return ToolOutput("Screenshot attached.", imageJPEG: jpeg)
            },
            Tool(name: "list_apps", description: "Running apps.", parametersSchema: #"{"type":"object","properties":{}}"#) { _ in
                await MainActor.run { NSWorkspace.shared.runningApplications.compactMap { $0.activationPolicy == .regular ? $0.localizedName : nil }.joined(separator: ", ") }
            },
            Tool(name: "open_app", description: "Open or activate an app by name.", parametersSchema: #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#) { d in
                let name = arg(d)["name"] as? String ?? ""
                let ok = await MainActor.run { () -> Bool in
                    if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.lowercased() == name.lowercased() }) { return app.activate() }
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) ?? NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: "/Applications/\(name).app")) {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init()); return true
                    }
                    return false
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
                return ok ? "opened \(name)" : "could not find \(name)"
            },
            Tool(name: "press", description: "Press/activate a numbered element (buttons, menu items, links, rows).", parametersSchema: #"{"type":"object","properties":{"id":{"type":"integer"}},"required":["id"]}"#) { d in
                let id = arg(d)["id"] as? Int ?? 0
                return await self.press(id, box: box)
            },
            Tool(name: "set_value", description: "Put text into a numbered text field or area (replaces its content).", parametersSchema: #"{"type":"object","properties":{"id":{"type":"integer"},"text":{"type":"string"}},"required":["id","text"]}"#) { d in
                let a = arg(d); return await self.setValue(a["id"] as? Int ?? 0, a["text"] as? String ?? "")
            },
            Tool(name: "type", description: "Type text at the current focus.", parametersSchema: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#) { d in
                let t = arg(d)["text"] as? String ?? ""; await MainActor.run { VirtualInput.type(t) }; return "typed \(t.count) characters"
            },
            Tool(name: "key", description: "Press a key combo, e.g. cmd+n, return, tab, escape.", parametersSchema: #"{"type":"object","properties":{"combo":{"type":"string"}},"required":["combo"]}"#) { d in
                let c = arg(d)["combo"] as? String ?? ""
                if ["return", "enter"].contains(c.lowercased()), await self.focusLooksIrreversible() { await box.set(.pausedForUser("Ready — press Return when you want to send")); await self.endLoop(); return "STOP: Return would send; left to the user" }
                await MainActor.run { VirtualInput.key(c) }; return "pressed \(c)"
            },
            Tool(name: "click", description: "Click a screen point (last resort; moves the pointer).", parametersSchema: #"{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"}},"required":["x","y"]}"#) { d in
                let a = arg(d); await MainActor.run { VirtualInput.click(CGPoint(x: a["x"] as? Double ?? 0, y: a["y"] as? Double ?? 0)) }; return "clicked"
            },
            Tool(name: "wait", description: "Wait a moment for the UI to settle.", parametersSchema: #"{"type":"object","properties":{"seconds":{"type":"number"}},"required":[]}"#) { d in
                let s = min(5, arg(d)["seconds"] as? Double ?? 1); try? await Task.sleep(nanoseconds: UInt64(s * 1e9)); return "waited"
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

    private func snapshotText() -> String { session.snapshot()?.text ?? "(no frontmost window)" }
    private func endLoop() { task?.cancel() }

    private func press(_ id: Int, box: OutcomeBox) async -> String {
        let title = session.titleOf(id).lowercased()
        if policy.alwaysAskBefore.contains(where: { title.contains($0) }) {
            await box.set(.pausedForUser("Ready — the “\(session.titleOf(id))” button is yours to press"))
            endLoop()
            return "STOP: “\(session.titleOf(id))” is irreversible; Hands never presses it. Call need_user now."
        }
        return session.perform("Press", on: id) ? "pressed \(id)" : "could not press \(id) (try click on its frame)"
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
