import Foundation
import SwiftUI
import Combine
import Domain
import Platform
import Privacy
import LocalSources
import CloudSources
import TelegramSource
import Inference
import Brain
import Knowledge
import Ingest
import Proactive
import Pipeline
import Agent
import Scheduling
import Support
import Contacts
import Speech
import AVFoundation
import ApplicationServices

/// The composition root and the app's observable state. The only place concrete types meet.
@MainActor
final class AppModel: ObservableObject {
    // ── wiring ─────────────────────────────────────────────────────────────────────
    let store: SQLiteRunStore
    let knowledge: FileKnowledgeStore
    let policy = DefaultSensitivityPolicy()
    let log = Log("app")
    private(set) var brain: (any Brain)?
    private(set) var reader: Reader?
    private var coordinator: RunCoordinator?
    private(set) var scheduler: OvernightScheduler?
    private(set) var hands: Hands?
    let download: ModelDownload

    // ── state the views read ───────────────────────────────────────────────────────
    enum Screen: Hashable { case forYou, ask, loops, recipes, sendLog, notes, graph, excluded, settings }
    enum Overlay: Hashable { case none, card(String), firing(String), processing, letter, weekly, brief(String), teach, recipeRun(String), editRecipe(String) }
    @Published var screen: Screen = .forYou
    /// A note the Knowledge screen should open on arrival (set by Graph → Open note, card evidence, etc.).
    @Published var pendingNote: String?
    func openNote(_ relativePath: String) { pendingNote = relativePath; overlay = .none; screen = .notes }
    @Published var overlay: Overlay = .none
    @Published var settingsTab = 0
    enum SettingsTab: Int { case sources = 0, knowledge, brain, hands, privacy, overnight, about }
    func openSettings(_ t: SettingsTab) { overlay = .none; screen = .settings; settingsTab = t.rawValue }
    @Published var appearance: String = "system"

    @Published var cards: [Card] = []
    @Published var lastRun: RunRecord?
    @Published var runs: [RunRecord] = []
    @Published var progress = RunProgress()
    @Published var thoughts: [String] = []
    @Published var isRunning = false
    @Published var runOutcome: RunOutcome?
    @Published var fireEvents: [FireEvent] = []
    @Published var letter: String?
    @Published var letterOpened = false
    @Published var folders: [KnowledgeFolder] = []
    @Published var drops: [DropRecord] = []
    @Published var modelState: ModelDownload.State = .idle
    @Published var modelPath: URL?
    @Published var readerChoice: String = "E4B"      // E4B | E2B
    @Published var brainConfig = BrainConfig(engine: .openai, model: BrainEngine.openai.defaultModel)
    @Published var brainStatus: String = "Not checked"
    @Published var lastUsage: Usage?
    @Published var enabledSources: Set<SourceID> = ["files"]
    @Published var enabledBuckets: [SourceID: Set<BucketID>] = [:]
    @Published var discovered: [SourceID: [BucketInfo]] = [:]
    @Published var availability: [SourceID: Availability] = [:]
    @Published var fileRoots: [URL] = FilesSource.defaultRoots
    @Published var permissions: [Permission: Bool] = [:]
    @Published var overnight = OvernightScheduler.Config()
    @Published var helperInstalled = false
    @Published var loginItem = false
    @Published var cardsPerMorning = 5
    @Published var notify = true
    @Published var instructions = ""
    @Published var handsHotkey = "rightCommand"
    @Published var handsSpeed = "balanced"
    @Published var onboardingDone = false
    @Published var walkthroughDone: Set<String> = []
    @Published var handsState: HandsPanelState = .idle
    @Published var announcement: String?
    @Published var lastSkipped: String?

    enum HandsPanelState: Equatable { case idle, listening(String), running([String]), paused(String), finished(String) }

    let allSources: [any Source]
    @Published var mcpManifests: [MCPManifest] = []

    // ── v2: loops, what left, briefs, the Sunday letter, taught recipes ─────────────
    @Published var loops: [Loop] = []
    @Published var sendLog: [SendRecord] = []
    @Published var weekly: String?
    @Published var weeklyWeek: String?
    @Published var weeklySeen = true
    @Published var briefs: [Brief] = []
    @Published var briefsEnabled = true
    @Published var recipes: [TaughtRecipe] = []
    @Published var teach = TeachState()
    @Published var recipeRun = RecipeRunState()
    @Published var showSendLine = true
    @Published var screenForbidden: Set<String> = []
    @Published var nudging: String?
    @Published var icloudMirror = false
    @Published var mcpEnabled = false
    @Published var mcpAsks: [MCPAsk] = []
    @Published var asks: [Asker.Answer] = []
    @Published var asking = false
    @Published var panicAsked = false
    let sendLogger: SendLogger
    let recorder = Recorder()
    var briefTimer: Timer?
    var recipeTimer: Timer?
    var recipeTask: Task<Void, Never>?

    init() {
        store = try! SQLiteRunStore(path: Paths.store.path)
        let st = store
        sendLogger = SendLogger(sink: { p, model, bytes, detail, payload in try? await st.logSend(purpose: p, model: model, bytes: bytes, detail: detail, cameBack: "…", payload: payload, at: Date()) },
                                result: { id, back in try? await st.setSendResult(id, cameBack: back) })
        knowledge = try! FileKnowledgeStore(root: Paths.knowledgeBase, indexPath: Paths.applicationSupport.appendingPathComponent("knowledge-index.sqlite").path)
        allSources = [FilesSource(roots: FilesSource.defaultRoots), NotesSource(), iMessageSource(), WhatsAppSource(), CalendarSource(), GmailSource(), TelegramSource()]
        download = ModelDownload(info: ModelCatalog.info(for: UserDefaults.standard.string(forKey: "reader.model")))
        Task { await bootstrap() }
    }

    // MARK: bootstrap

    func bootstrap() async {
        try? await store.prune()
        await loadSettings()
        await refreshPermissions()
        await reload()
        rebuildBrain()
        rebuildReader()
        Task { await refreshSources() }   // discovery can be slow (Telegram, 300+ chats); the UI must not wait for it
        let mp = modelPath
        _ = await download.observe { [weak self] s in Task { @MainActor in self?.modelState = s; if case .done(let u) = s { self?.modelPath = u; self?.rebuildReader() } } }
        if mp == nil, case .idle = modelState { /* onboarding prompts the download */ }
        helperInstalled = WakeHelper.Client().isInstalled
        loginItem = OvernightScheduler.isLoginItem
        startScheduler()
        startBriefs(); startRecipeSchedule()
        if TelegramSource.isConfigured { watchTelegram() }
        if CommandLine.arguments.contains("--request-permissions") { await requestAllPermissions() }
    }

    /// Asks macOS for every grant Brownie uses, in order. Prompts that macOS can show are shown;
    /// the two it can't (Full Disk Access, the root helper) open their pane / admin dialog.
    func requestAllPermissions() async {
        // 1. Calendar, Contacts, Speech, Microphone — real prompts
        _ = await CalendarSource.requestAccess()
        _ = try? await CNContactStore().requestAccess(for: .contacts)
        await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { _ in c.resume() } }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        // 2. Accessibility — the system prompt with an "Open System Settings" button
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        // 3. Screen Recording — system prompt
        _ = CGRequestScreenCaptureAccess()
        // 4. Full Disk Access — no prompt exists; the floating guide follows the user into the pane
        if !PermissionProbe.status(.fullDiskAccess) { PermissionGuide.shared.show(for: .fullDiskAccess) { [weak self] in Task { await self?.refreshPermissions(); await self?.refreshSources() } } }
        // 5. The wake helper — one admin prompt
        if !helperInstalled { installHelper() }
        setLoginItem(true)
        await refreshPermissions(); await refreshSources()
    }

    func loadSettings() async {
        func v(_ k: String) async -> String? { try? await store.value(k) }
        if let s = await v(SettingKey.enabledSources), let d = s.data(using: .utf8), let ids = try? JSONDecoder().decode([String].self, from: d) { enabledSources = Set(ids.map { SourceID($0) }) }
        for s in allSources where s.descriptor.supportsPerBucketOptIn {
            if let j = await v(SettingKey.enabledBuckets(s.id)), let d = j.data(using: .utf8), let ids = try? JSONDecoder().decode([String].self, from: d) { enabledBuckets[s.id] = Set(ids.map { BucketID($0) }) }
        }
        if let r = await v(SettingKey.fileRoots), let d = r.data(using: .utf8), let ps = try? JSONDecoder().decode([String].self, from: d) { fileRoots = ps.map { URL(fileURLWithPath: $0) } }
        brainConfig = BrainConfig(engine: BrainEngine(rawValue: await v(SettingKey.brainEngine) ?? "openai") ?? .openai,
                                  model: await v(SettingKey.brainModel) ?? BrainEngine.openai.defaultModel,
                                  customBaseURL: await v(SettingKey.customBaseURL) ?? "http://127.0.0.1:1234/v1")
        if brainConfig.model.isEmpty { brainConfig.model = brainConfig.engine.defaultModel }
        cardsPerMorning = Int(await v(SettingKey.cardsPerMorning) ?? "5") ?? 5
        notify = (await v(SettingKey.notifyOnReady) ?? "true") == "true"
        instructions = await v(SettingKey.standingInstructions) ?? ""
        handsHotkey = await v(SettingKey.handsHotkey) ?? "rightCommand"
        handsSpeed = await v(SettingKey.handsSpeed) ?? "balanced"
        let (h, m) = OvernightScheduler.Config.parse(await v(SettingKey.overnightTime))
        overnight = OvernightScheduler.Config(enabled: (await v(SettingKey.overnightEnabled) ?? "true") == "true", hour: h, minute: m, catchUp: (await v(SettingKey.catchUp) ?? "true") == "true", daytime: await v(SettingKey.daytime) ?? "h1")
        appearance = await v(SettingKey.appearance) ?? "system"
        onboardingDone = (await v(SettingKey.onboardingDone) ?? "false") == "true"
        letter = await v(SettingKey.letter); letterOpened = (await v(SettingKey.letterOpened) ?? "false") == "true"
        if let u = await v("brain.lastUsage"), let d = u.data(using: .utf8) { lastUsage = try? JSONDecoder().decode(Usage.self, from: d) }
        var done = Set<String>()
        for k in ["foryou", "card", "knowledge", "graph", "excluded", "sources", "hands"] where (await v(SettingKey.walkthrough(k))) == "true" { done.insert(k) }
        walkthroughDone = done
        readerChoice = await v(SettingKey.localModel) ?? (ModelCatalog.physicalMemoryGB < 12 ? "E2B" : "E4B")
        modelPath = ModelCatalog.locate(ModelCatalog.info(for: readerChoice))
        if let j = await v("sources.mcp"), let d = j.data(using: .utf8), let ms = try? JSONDecoder().decode([MCPManifest].self, from: d) { mcpManifests = ms }
        showSendLine = (await v(SettingKey.showSendLine) ?? "true") == "true"
        icloudMirror = (await v(SettingKey.icloudMirror) ?? "false") == "true"
        mcpEnabled = (await v(SettingKey.mcpEnabled) ?? "false") == "true"
        if let j = await v(SettingKey.mcpLog), let d = j.data(using: .utf8) { mcpAsks = (try? JSONDecoder().decode([MCPAsk].self, from: d)) ?? [] }
        briefsEnabled = (await v(SettingKey.briefsEnabled) ?? "true") == "true"
        if let j = await v(SettingKey.screenForbidden), let d = j.data(using: .utf8), let a = try? JSONDecoder().decode([String].self, from: d) { screenForbidden = Set(a) }
    }

    func set(_ key: String, _ value: String?) { Task { try? await store.setValue(key, value) } }

    // MARK: sources

    var workSources: [any Source] { mcpManifests.map { MCPSource(manifest: $0) } }

    var sourcesForRun: [any Source] {
        (allSources + workSources).compactMap { s in
            guard enabledSources.contains(s.id) else { return nil }
            if s.id == "files" { return FilesSource(roots: fileRoots) }
            return s
        }
    }

    func addMCP(_ m: MCPManifest, token: String) {
        if !token.isEmpty { Keychain.set(m.tokenKey, token) }
        mcpManifests.removeAll { $0.id == m.id }; mcpManifests.append(m)
        set("sources.mcp", json(mcpManifests))
        enabledSources.insert(SourceID("mcp:\(m.id)")); set(SettingKey.enabledSources, json(enabledSources.map(\.rawValue)))
        Task { await refreshSources() }
    }
    func removeMCP(_ id: String) {
        mcpManifests.removeAll { $0.id == id }; set("sources.mcp", json(mcpManifests))
        enabledSources.remove(SourceID("mcp:\(id)")); set(SettingKey.enabledSources, json(enabledSources.map(\.rawValue)))
        Keychain.set("mcp.\(id).token", nil)
    }

    func refreshSources() async {
        for s in allSources + workSources {
            let a = await s.availability(); availability[s.id] = a
            if s.descriptor.supportsPerBucketOptIn, a == .available, s.id != "files" {
                do {
                    // A source that never answers (a wedged Telegram client) must not hold the others hostage.
                    let b = try await withThrowingTaskGroup(of: [BucketInfo].self) { g -> [BucketInfo] in
                        g.addTask { try await s.discoverBuckets() }
                        g.addTask { try await Task.sleep(nanoseconds: 25_000_000_000); throw SourceError.cannotRead("discovery timed out") }
                        let r = try await g.next()!; g.cancelAll(); return r
                    }
                    discovered[s.id] = b; log.info("\(s.id): \(b.count) chats discovered")
                } catch { discovered[s.id] = []; log.warn("\(s.id): discovery failed: \(error)") }
            } else if s.descriptor.supportsPerBucketOptIn { log.info("\(s.id): \(a)") }
        }
        discovered["files"] = fileRoots.map { BucketInfo(id: BucketID("files:" + $0.standardizedFileURL.path), name: $0.lastPathComponent, detail: $0.path, isGroup: false, count: 0) }
    }

    func toggleSource(_ id: SourceID) {
        if enabledSources.contains(id) { enabledSources.remove(id) } else {
            enabledSources.insert(id)
            if id == "calendar", !CalendarSource.isAuthorized { Task { _ = await CalendarSource.requestAccess(); await refreshPermissions(); await refreshSources() } }
        }
        set(SettingKey.enabledSources, json(enabledSources.map(\.rawValue)))
        markWalkthrough("sources")
    }

    func toggleBucket(_ source: SourceID, _ b: BucketID) {
        var set = enabledBuckets[source] ?? []
        if set.contains(b) { set.remove(b) } else { set.insert(b) }
        enabledBuckets[source] = set
        self.set(SettingKey.enabledBuckets(source), json(set.map(\.rawValue)))
    }

    func signInGoogle() {
        Task {
            do { try await GoogleAuth.shared.signIn(); enabledSources.insert("gmail"); set(SettingKey.enabledSources, json(enabledSources.map(\.rawValue))); await refreshSources() }
            catch { announcement = "Google sign-in didn't complete: \(error)" }
        }
    }
    @Published var telegramAuth: TDClient.AuthState = .waitingForParameters
    func watchTelegram() {
        guard let c = TelegramSource.shared else { return }
        Task { await c.start(); await c.onAuth { [weak self] st in Task { @MainActor in self?.telegramAuth = st; if st == .ready { await self?.refreshSources() } } } }
    }
    func telegramPhone(_ phone: String) async -> String? { do { try await TelegramSource.shared?.setPhone(phone); return nil } catch { return "\(error)" } }
    func telegramCode(_ code: String) async -> String? { do { try await TelegramSource.shared?.setCode(code); return nil } catch { return "\(error)" } }
    func telegramPassword(_ pw: String) async -> String? { do { try await TelegramSource.shared?.setPassword(pw); return nil } catch { return "\(error)" } }
    func telegramSignOut() { Task { try? await TelegramSource.shared?.logOut(); await refreshSources() } }

    func signOutGoogle() { Task { await GoogleAuth.shared.signOut(); await refreshSources() } }

    func addFileRoot(_ url: URL) {
        guard !fileRoots.contains(url) else { return }
        fileRoots.append(url); set(SettingKey.fileRoots, json(fileRoots.map(\.path)))
        Task { await refreshSources() }
    }
    func removeFileRoot(_ url: URL) { fileRoots.removeAll { $0 == url }; set(SettingKey.fileRoots, json(fileRoots.map(\.path))); Task { await refreshSources() } }

    func refreshPermissions() async {
        for p in [Permission.fullDiskAccess, .accessibility, .screenRecording, .calendar, .contacts] { permissions[p] = PermissionProbe.status(p) }
    }

    // MARK: brain + reader

    func rebuildBrain() {
        if brainConfig.engine == .local {
            brain = reader.map { LocalBrain(reader: $0) }    // nothing leaves, so nothing to log
            brainStatus = brain == nil ? "The reader isn't downloaded yet" : "This Mac only · nothing leaves"
        } else {
            // The key read can put up a Keychain dialog; never block the UI on it.
            let cfg = brainConfig, logger = sendLogger
            brainStatus = "Checking the Keychain…"
            Task.detached(priority: .userInitiated) {
                let made = BrainFactory.make(cfg)
                let hasKey = BrainFactory.hasKey(cfg.engine)
                if hasKey, let k = cfg.engine.keyName { Keychain.reown(k) }
                await MainActor.run { [weak self] in
                    guard let self, self.brainConfig == cfg else { return }
                    self.brain = made.map { SendLogger.wrap($0, model: cfg.model, logger: logger) }
                    self.brainStatus = self.brain == nil ? "No brain — notes only" : (hasKey ? "Key present · not checked" : "No key for \(cfg.engine.displayName)")
                    self.finishBrain()
                }
            }
            return
        }
        finishBrain()
    }
    private func finishBrain() {
        if let b = brain as? AgenticBrain { hands = Hands(brain: b, knowledge: knowledge, effort: handsSpeed == "fast" ? .low : (handsSpeed == "careful" ? .high : .medium)) } else { hands = nil }
        rebuildCoordinator()
    }

    func saveBrain() {
        set(SettingKey.brainEngine, brainConfig.engine.rawValue); set(SettingKey.brainModel, brainConfig.model); set(SettingKey.customBaseURL, brainConfig.customBaseURL)
        rebuildBrain()
    }

    func validateBrain() async {
        guard let brain else { brainStatus = "No brain configured"; return }
        brainStatus = "Checking…"
        do { try await brain.validate(); brainStatus = "Signed in · \(brain.descriptor.name) · \(brainConfig.model)" }
        catch BrainError.unauthorized { brainStatus = "Key rejected" }
        catch BrainError.notConfigured { brainStatus = "No key" }
        catch { brainStatus = "Couldn't reach \(brain.descriptor.name): \(error)" }
    }

    func chooseReader(_ choice: String) {
        readerChoice = choice; set(SettingKey.localModel, choice); UserDefaults.standard.set(choice, forKey: "reader.model")
        modelPath = ModelCatalog.locate(ModelCatalog.info(for: choice)); rebuildReader()
        announcement = modelPath == nil ? "Relaunch Brownie to download \(ModelCatalog.info(for: choice).name)." : nil
    }

    func rebuildReader() {
        reader = modelPath.map { Reader(modelPath: $0, jsonSchema: Triage.jsonSchema) }
        if brainConfig.engine == .local { rebuildBrain() } else { rebuildCoordinator() }
    }

    private func rebuildCoordinator() {
        let logger = sendLogger
        coordinator = RunCoordinator(.init(store: store, knowledge: knowledge, sources: sourcesForRun, reader: reader, brain: brain, policy: policy,
                                            calendarText: { CalendarSource.judgeContext() }, stage: { p, d in logger.setPurpose(p, detail: d) }))
    }
    var runCoordinator: RunCoordinator? { rebuildCoordinator(); return coordinator }

    // MARK: runs

    func analyzeNow(trigger: RunTrigger = .manual) {
        guard !isRunning else { overlay = .processing; return }
        guard modelPath != nil else { announcement = "The reader isn't downloaded yet — Settings → Brain → On this Mac."; return }
        rebuildCoordinator()
        guard let coordinator else { return }
        isRunning = true; overlay = .processing; thoughts = []; progress = RunProgress()
        Task {
            let outcome = await coordinator.run(trigger: trigger) { [weak self] e in
                Task { @MainActor in
                    guard let self else { return }
                    switch e {
                    case .progress(let p): self.progress = p
                    case .thought(let t): self.thoughts.append(t); if self.thoughts.count > 3 { self.thoughts.removeFirst() }
                    case .finished: break
                    }
                }
            }
            await MainActor.run {
                self.isRunning = false; self.runOutcome = outcome
                if self.overlay == .processing { self.overlay = .none }
            }
            await scheduler?.noteRun(at: Date())
            await reload()
            Notifier.runFinished(outcome, stats: progress.stats)
        }
    }

    func stopRun() { Task { await coordinator?.cancel() } }

    @Published var pastCards: [Card] = []
    @Published var snoozedCards: [Card] = []
    @Published var bulkUnread: Int = 0

    func reload() async {
        let now = Date()
        var all = ((try? await RunCoordinator.loadCards(store: store)) ?? []).map { $0.housekept(now: now) }
        all.removeAll { c in (c.state == .expired || c.state == .dismissed || c.state == .fired) && now.timeIntervalSince(c.resolvedAt ?? c.createdAt) > 30 * 86400 }
        try? await RunCoordinator.saveCards(all, store: store)
        cards = all.filter { $0.state == .ready }.sorted { $0.urgency > $1.urgency }
        snoozedCards = all.filter { $0.state == .snoozed }.sorted { ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture) }
        bulkUnread = fileRoots.reduce(0) { $0 + FilesSource.counts($1).bulk }
        pastCards = all.filter { $0.state != .ready && $0.state != .snoozed }.sorted { ($0.resolvedAt ?? $0.createdAt) > ($1.resolvedAt ?? $1.createdAt) }
        lastRun = try? await store.lastRun()
        runs = (try? await store.recentRuns(limit: 7)) ?? []
        folders = (try? await knowledge.folders()) ?? []
        drops = (try? await store.drops(since: Date().addingTimeInterval(-7 * 86400))) ?? []
        letter = try? await store.value(SettingKey.letter)
        lastSkipped = try? await store.value("run.lastSkipped")
        await reloadV2()
    }

    // MARK: cards

    func card(_ id: String) -> Card? { cards.first { $0.id == id } }

    func dismiss(_ id: String) { setCardState(id, .dismissed); overlay = .none }

    func updateDraft(_ id: String, _ text: String) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[i] = cards[i].withDraft(text)
        let updated = cards[i]
        Task {
            var all = (try? await RunCoordinator.loadCards(store: store)) ?? []
            if let j = all.firstIndex(where: { $0.id == id }) { all[j] = updated }
            try? await RunCoordinator.saveCards(all, store: store)
        }
    }

    func fire(_ id: String) {
        guard let card = card(id) else { return }
        markWalkthrough("card")
        overlay = .firing(id); fireEvents = []
        if case .computerUse = card.recipe {
            if !Hands.hasAccessibility { fireEvents = [.step("Hands needs Accessibility — System Settings → Privacy & Security → Accessibility → add Brownie", done: false), .finished(.couldNot)]; PermissionProbe.openSettings(for: .accessibility); return }
            if hands == nil { fireEvents = [.step("Hands needs a brain with tools — Settings → Brain", done: false), .finished(.couldNot)]; return }
        }
        let executor = RecipeExecutor(knowledgeRoot: knowledge.rootURL) { [weak self] goal, onEvent in
            guard let self, let hands = await self.hands else { onEvent(.step("Hands needs a brain with tools", done: false)); return .couldNot }
            onEvent(.step("Hands is starting: \(goal)", done: true))
            let o = await hands.perform(goal) { e in if case .step(let s) = e { onEvent(.step(s, done: true)) } }
            switch o {
            case .done(let s): onEvent(.step(s, done: true)); return .done
            case .pausedForUser(let w): onEvent(.pausedForUser(w)); return .pausedAtUserStep
            case .stopped: return .stopped
            case .couldNot(let r): onEvent(.step("Hands couldn't: \(r)", done: false)); return .couldNot
            }
        }
        Task {
            let outcome = (try? await executor.fire(card) { e in Task { @MainActor in self.fireEvents.append(e) } }) ?? .couldNot
            await MainActor.run { self.fireEvents.append(.finished(outcome)); if outcome != .couldNot { self.setCardState(id, .fired) } }
            if outcome == .pausedAtUserStep { Notifier.paused("Ready for you", body: "The message is in place. Press Send when you're ready.") }
        }
    }

    func unsnooze(_ id: String) {
        Task {
            var all = (try? await RunCoordinator.loadCards(store: store)) ?? []
            if let i = all.firstIndex(where: { $0.id == id }) { all[i].state = .ready; all[i].snoozedUntil = nil }
            try? await RunCoordinator.saveCards(all, store: store); await reload()
        }
    }

    func snooze(_ id: String, days: Int) {
        Task {
            var all = (try? await RunCoordinator.loadCards(store: store)) ?? []
            if let i = all.firstIndex(where: { $0.id == id }) { all[i].state = .snoozed; all[i].snoozedUntil = Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: Date()))?.addingTimeInterval(7 * 3600) }
            try? await RunCoordinator.saveCards(all, store: store)
            await reload(); overlay = .none
        }
    }

    private func setCardState(_ id: String, _ s: CardState) {
        Task {
            var all = (try? await RunCoordinator.loadCards(store: store)) ?? []
            if let i = all.firstIndex(where: { $0.id == id }) { all[i].state = s; all[i].resolvedAt = Date() }
            try? await RunCoordinator.saveCards(all, store: store)
            // A fired card about a loop: remember it, so the loop comes back if nothing changes.
            if s == .fired, let loopID = all.first(where: { $0.id == id })?.loopID {
                var ls = await LoopLedger.load(store)
                if let j = ls.firstIndex(where: { $0.id == loopID }) { ls[j].firedCardIDs.append(id); await LoopLedger.save(ls, store) }
            }
            await reload()
        }
    }

    func openLetter() { letterOpened = true; set(SettingKey.letterOpened, "true") }

    // MARK: overnight

    func startScheduler() {
        let s = OvernightScheduler(store: store) { [weak self] trigger in
            guard let self else { return .cancelled }
            return await withCheckedContinuation { cont in
                Task { @MainActor in
                    self.rebuildCoordinator()
                    guard let c = self.coordinator else { cont.resume(returning: .cancelled); return }
                    self.isRunning = true
                    let o = await c.run(trigger: trigger) { _ in }
                    self.isRunning = false; await self.reload()
                    // Daytime reads are quiet unless something new deserves a card.
                    if trigger != .daytime { Notifier.runFinished(o, stats: self.progress.stats) }
                    else if case .ran(let n) = o, n > 0 { Notifier.post("\(n) new thing\(n == 1 ? "" : "s") while you were away", body: "Refreshed on your Mac. Nothing has been sent.", id: "cards.daytime", category: "cards") }
                    cont.resume(returning: o)
                }
            }
        }
        scheduler = s
        let last = lastRun?.startedAt
        Task { if let last { await s.noteRun(at: last) }; await s.start(overnight); await s.catchUpIfNeeded(lastRun: lastRun) }
    }

    func saveOvernight() {
        set(SettingKey.overnightEnabled, overnight.enabled ? "true" : "false")
        set(SettingKey.overnightTime, String(format: "%02d:%02d", overnight.hour, overnight.minute))
        set(SettingKey.catchUp, overnight.catchUp ? "true" : "false")
        set(SettingKey.daytime, overnight.daytime)
        Task { await scheduler?.start(overnight) }
    }

    func installHelper() {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        do { try WakeHelper.Client().install(executable: exe); helperInstalled = true } catch { announcement = "Couldn't install the wake helper: \(error)" }
    }

    func setLoginItem(_ on: Bool) { OvernightScheduler.setLoginItem(on); loginItem = on }

    // MARK: walkthroughs

    func markWalkthrough(_ key: String) {
        guard !walkthroughDone.contains(key) else { return }
        walkthroughDone.insert(key); set(SettingKey.walkthrough(key), "true")
    }
    func replayWalkthroughs() { for k in walkthroughDone { set(SettingKey.walkthrough(k), nil) }; walkthroughDone = []; screen = .forYou }

    // MARK: reset / uninstall

    func factoryReset() {
        Task {
            try? await store.factoryReset()
            try? FileManager.default.removeItem(at: knowledge.rootURL)
            await MainActor.run { letter = nil; letterOpened = false; walkthroughDone = []; cards = [] }
            await reload()
        }
    }

    func uninstall() {
        try? WakeHelper.Client().uninstall()
        OvernightScheduler.setLoginItem(false)
        try? FileManager.default.removeItem(at: knowledge.rootURL)
        try? FileManager.default.removeItem(at: Paths.applicationSupport)
        Keychain.wipeAll()
        NSApp.terminate(nil)
    }

    // MARK: helpers

    func json<T: Encodable>(_ v: T) -> String { (try? String(data: JSONEncoder().encode(v), encoding: .utf8)) ?? "[]" }

    var brainName: String { brain?.descriptor.name ?? (brainStatus.hasPrefix("Checking") ? "checking the Keychain…" : "No brain") }
    var sidebarStatus: (String, String) {
        guard let r = lastRun else { return ("No run yet", "Press Analyze now to read for the first time") }
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return ("Last run \(f.string(from: r.startedAt))", "\(r.stats.read) items read · \(r.stats.kept) kept")
    }
}
