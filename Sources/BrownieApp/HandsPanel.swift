import SwiftUI
import AppKit
import Speech
import AVFoundation
import Domain
import Agent

/// Hold-to-talk hotkey (right ⌘ / right ⌥), on-device speech, and the floating overlay under the
/// notch. Runs only while the user is present; never in the overnight pipeline.
@MainActor
final class HandsController: ObservableObject {
    private let m: AppModel
    private var monitor: Any?
    private var localMonitor: Any?
    private var holding = false
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-IN")) ?? SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audio = AVAudioEngine()
    private var panel: NSPanel?
    @Published var transcript = ""
    @Published var commandText = ""
    @Published var showCommandBar = false

    init(model: AppModel) { self.m = model }

    private var keyMonitor: Any?
    @Published var recentGoals: [String] = UserDefaults.standard.stringArray(forKey: "hands.recentGoals") ?? []

    func start() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        let mask: NSEvent.EventTypeMask = .flagsChanged
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in Task { @MainActor in self?.flags(e) } }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in Task { @MainActor in self?.flags(e) }; return e }
        // ⌘⇧Space anywhere → command bar (global key monitors need Accessibility)
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 49, e.modifierFlags.contains([.command, .shift]) else { return }
            Task { @MainActor in NSApp.activate(ignoringOtherApps: true); self?.showCommandBar = true }
        }
        // A running recipe shows in the same floating panel as Hands, with the same Stop.
        NotificationCenter.default.addObserver(forName: .brownieRecipeRunning, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.showPanel() } }
        NotificationCenter.default.addObserver(forName: .brownieRecipeDone, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.hidePanel(after: 6) } }
    }

    private func remember(_ goal: String) {
        recentGoals.removeAll { $0 == goal }; recentGoals.insert(goal, at: 0); recentGoals = Array(recentGoals.prefix(5))
        UserDefaults.standard.set(recentGoals, forKey: "hands.recentGoals")
    }

    private func flags(_ e: NSEvent) {
        guard m.handsHotkey != "off" else { return }
        // Right ⌘ keycode 54, right ⌥ 61
        let code = m.handsHotkey == "rightOption" ? 61 : 54
        guard Int(e.keyCode) == code else { return }
        let down = m.handsHotkey == "rightOption" ? e.modifierFlags.contains(.option) : e.modifierFlags.contains(.command)
        if down, !holding { holding = true; beginListening() }
        else if !down, holding { holding = false; endListening() }
    }

    private func beginListening() {
        transcript = ""; m.handsState = .listening("")
        showPanel()
        guard SFSpeechRecognizer.authorizationStatus() == .authorized, let recognizer, recognizer.isAvailable else { transcript = "(speech not available — use the command bar)"; return }
        let req = SFSpeechAudioBufferRecognitionRequest(); req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }   // never the server
        request = req
        let input = audio.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in req.append(buf) }
        audio.prepare(); try? audio.start()
        recognitionTask = recognizer.recognitionTask(with: req) { [weak self] r, _ in
            guard let self, let r else { return }
            Task { @MainActor in self.transcript = r.bestTranscription.formattedString; self.m.handsState = .listening(self.transcript) }
        }
    }

    private func endListening() {
        audio.stop(); audio.inputNode.removeTap(onBus: 0); request?.endAudio(); recognitionTask?.cancel()
        let goal = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if goal.isEmpty { m.handsState = .idle; hidePanel(after: 1.5); return }
        run(goal)
    }

    func run(_ goal: String) {
        if let r = m.recipe(named: goal) { m.overlay = .none; m.screen = .recipes; NSApp.activate(ignoringOtherApps: true); m.runRecipe(r.id); return }
        showPanel()
        remember(goal)
        m.markWalkthrough("hands")
        guard let hands = m.hands else { m.handsState = .finished("Hands needs a brain with tools — set one in Settings → Brain"); hidePanel(after: 4); return }
        guard Hands.hasAccessibility else { m.handsState = .finished("Hands needs Accessibility — Settings → Privacy"); hidePanel(after: 4); return }
        m.handsState = .running(["Starting: \(goal)"])
        Task {
            let o = await hands.perform(goal) { [weak self] e in
                Task { @MainActor in
                    guard let self else { return }
                    if case .step(let s) = e, case .running(var steps) = self.m.handsState { steps.append(s); if steps.count > 6 { steps.removeFirst() }; self.m.handsState = .running(steps) }
                }
            }
            await MainActor.run {
                switch o {
                case .done(let s): m.handsState = .finished("Done — \(s)"); hidePanel(after: 4)
                case .pausedForUser(let w): m.handsState = .paused(w); Notifier.paused("Hands paused", body: w); hidePanel(after: 8)
                case .stopped: m.handsState = .finished("Stopped"); hidePanel(after: 2)
                case .couldNot(let r): m.handsState = .finished("Couldn't — \(r)"); hidePanel(after: 6)
                }
            }
        }
    }

    func stop() { m.stopRecipe(); Task { await m.hands?.stop() } }

    // MARK: panel

    private func showPanel() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 160), styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
            p.isFloatingPanel = true; p.level = .statusBar; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: HandsOverlay(controller: self).environmentObject(m))
            panel = p
        }
        if let screen = NSScreen.main, let p = panel {
            p.setFrameOrigin(NSPoint(x: screen.frame.midX - 280, y: screen.frame.maxY - 160))
            p.orderFrontRegardless()
        }
    }

    private func hidePanel(after s: TimeInterval) {
        Task { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)); if case .running = m.handsState { return }; if case .listening = m.handsState { return }; panel?.orderOut(nil); m.handsState = .idle }
    }
}

struct HandsOverlay: View {
    @EnvironmentObject var m: AppModel
    @ObservedObject var controller: HandsController
    let accent = Color(hex: 0xD8983A)
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch m.handsState {
            case .idle: Text("hold right ⌘ to talk").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            case .listening(let t):
                HStack(spacing: 12) { Image(systemName: "waveform").foregroundStyle(accent); Text(t.isEmpty ? "Listening…" : "“\(t)”").font(.system(size: 15, weight: .medium)) }
                Text("Transcribed on this Mac · let go to start").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            case .running(let steps):
                HStack { Text(m.runningRecipeName.map { "Running “\($0)”" } ?? "Hands is working").font(.system(size: 15, weight: .semibold)); Spacer(); Button("Stop") { controller.stop() }.buttonStyle(.plain).padding(.horizontal, 10).frame(height: 26).background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0xD94F45))) }
                ForEach(Array(steps.enumerated()), id: \.offset) { _, s in HStack(spacing: 8) { Circle().fill(accent).frame(width: 6, height: 6); Text(s).font(.system(size: 12)).lineLimit(1) } }
                Text("Hands never presses Send, Pay or Delete. Those stay yours.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            case .paused(let w): HStack(spacing: 10) { Circle().fill(accent).frame(width: 10, height: 10); Text(w).font(.system(size: 14, weight: .medium)) }
            case .finished(let s): Text(s).font(.system(size: 14, weight: .medium))
            }
        }
        .foregroundStyle(.white).padding(EdgeInsets(top: 42, leading: 22, bottom: 16, trailing: 22)).frame(width: 560, alignment: .leading)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22).fill(.black))
    }
}

struct CommandBar: View {
    @EnvironmentObject var m: AppModel
    @ObservedObject var controller: HandsController
    @Environment(\.theme) var t
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sun.max").foregroundStyle(t.accent)
                TextField("Tell Hands what to do…", text: $controller.commandText).textFieldStyle(.plain).font(.system(size: 14)).onSubmit { go() }
                BButton(title: "Do it", kind: .primary) { go() }
            }
            let suggestions = Array((controller.recentGoals + m.cards.prefix(3).map { $0.actionLabel + ": " + $0.title }).prefix(5))
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { ForEach(suggestions, id: \.self) { g in Button(g) { controller.commandText = g }.buttonStyle(.plain).font(.system(size: 12)).lineLimit(1).padding(.horizontal, 10).frame(height: 24).background(Capsule().fill(t.chip)) } } }
            }
            Text("⌘⇧Space · knows your notes · asks before anything irreversible").font(.system(size: 11)).foregroundStyle(t.ink2)
        }.padding(16).frame(width: 620)
    }
    func go() { let g = controller.commandText.trimmingCharacters(in: .whitespaces); guard !g.isEmpty else { return }; controller.showCommandBar = false; controller.run(g) }
}
