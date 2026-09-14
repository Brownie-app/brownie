import Foundation
import SwiftUI
import AppKit
import EventKit
import Domain
import Proactive
import Pipeline
import Agent
import LocalSources
import Platform
import CloudSources
import Scheduling
import Support
import Knowledge
import Inference

/// Teach Hands: the three-step flow's state.
struct TeachState: Equatable {
    enum Step: Equatable { case show, watching, tune, saved }
    var step: Step = .show
    var steps: [TaughtRecipe.Step] = []
    var pending = ""
    var parameters: [TaughtRecipe.Parameter] = []
    var name = ""
    var weekly = false
    var weekday = 2, hour = 9, minute = 0
    var stoppedBecause: String?
    var savedID: String?
}

/// A recipe in flight: the questions to answer first, then the steps as they happen.
struct RecipeRunState: Equatable {
    var recipeID: String?
    var asking: [TaughtRecipe.Parameter] = []
    var answers: [String: String] = [:]
    var steps: [String] = []
    var outcome: String?
    var running = false
}

extension AppModel {
    // MARK: reload

    func reloadV2() async {
        loops = await LoopLedger.load(store)
        await reloadMCPAsks()
        if let j = try? await store.value(SettingKey.askHistory), let d = j.data(using: .utf8) { asks = (try? JSONDecoder().decode([Asker.Answer].self, from: d)) ?? [] }
        sendLog = (try? await store.sendLog(since: Date().addingTimeInterval(-30 * 86400))) ?? []
        weeklyWeek = try? await store.value(SettingKey.weeklyLatest)
        if let w = weeklyWeek { weekly = try? await store.value(SettingKey.weekly(w)); weeklySeen = (try? await store.value("proactive.weekly.seen")) == w }
        if let j = try? await store.value(SettingKey.recipesTaught), let d = j.data(using: .utf8) {
            // Titles recorded before the cleaner existed carry WhatsApp's direction marks; scrub on load.
            recipes = ((try? JSONDecoder().decode([TaughtRecipe].self, from: d)) ?? []).map { r in
                var r = r; r.name = Recorder.clean(r.name)
                r.steps = r.steps.map { .init(kind: $0.kind, app: Recorder.clean($0.app), target: Recorder.clean($0.target), role: $0.role, text: $0.text) }
                r.parameters = r.parameters.map { .init(id: $0.id, name: $0.name, original: Recorder.clean($0.original), fill: $0.fill) }
                return r
            }
        }
        if let j = try? await store.value(SettingKey.briefs), let d = j.data(using: .utf8) { briefs = ((try? JSONDecoder().decode([Brief].self, from: d)) ?? []).filter { Date().timeIntervalSince($0.startsAt) < 3 * 86400 } }
    }

    // MARK: loops

    var openLoopCount: Int { loops.filter { $0.status == .open }.count }

    func closeLoop(_ id: String, how: String) {
        guard let i = loops.firstIndex(where: { $0.id == id }) else { return }
        loops[i].status = .closed; loops[i].closedAt = Date(); loops[i].closedHow = how
        let ls = loops; Task { await LoopLedger.save(ls, store) }
    }
    func setNudgeDays(_ d: Int) { nudgeDays = d; set(SettingKey.nudgeDays, String(d)) }
    func dismissLoop(_ id: String) {
        guard let i = loops.firstIndex(where: { $0.id == id }) else { return }
        loops[i].status = .dismissed; loops[i].closedAt = Date(); loops[i].closedHow = "not a promise"
        let ls = loops; Task { await LoopLedger.save(ls, store) }
    }
    /// A card for this loop, if one is waiting; otherwise the brain drafts one now.
    func nudge(_ loop: Loop) {
        markWalkthrough("loops")
        if let c = cards.first(where: { $0.loopID == loop.id }) { overlay = .card(c.id); return }
        guard let brain else { announcement = "Drafting a nudge needs a brain — Settings → Brain."; return }
        nudging = loop.id
        sendLogger.setPurpose("Draft a nudge", detail: "one loop and the note about \(loop.person)")
        Task {
            do {
                let (card, _) = try await LoopNudger(brain: brain, knowledge: knowledge).card(for: loop)
                var all = (try? await RunCoordinator.loadCards(store: store)) ?? []
                all.append(card); try? await RunCoordinator.saveCards(all, store: store)
                await reload()
                nudging = nil; overlay = .card(card.id)
            } catch { nudging = nil; announcement = "Couldn't draft it: \(error)" }
        }
    }

    // MARK: what left

    /// Last night's line under the cards: requests, bytes, and the honest zero.
    var lastNightSend: (requests: Int, bytes: Int)? {
        guard let r = lastRun, !sendLog.isEmpty else { return nil }
        let rows = sendLog.filter { $0.at >= r.startedAt.addingTimeInterval(-60) && $0.at <= (r.endedAt ?? Date()).addingTimeInterval(60) }
        return (rows.count, rows.reduce(0) { $0 + $1.bytes })
    }

    // MARK: the Sunday letter

    func openWeekly() { overlay = .weekly; weeklySeen = true; if let w = weeklyWeek { set("proactive.weekly.seen", w) } }
    func writeWeeklyNow() {
        guard brain != nil else { announcement = "The letter needs a brain — Settings → Brain."; return }
        guard let c = runCoordinator else { return }
        announcement = "Writing your week…"
        Task {
            do { try await c.writeWeeklyNow(); await reloadV2(); announcement = nil; openWeekly() }
            catch { announcement = "Couldn't write it: \(error)" }
        }
    }

    // MARK: pre-meeting briefs

    func startBriefs() {
        briefTimer?.invalidate()
        briefTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in await self?.checkBriefs() } }
        Task { await checkBriefs() }
    }

    /// Every minute: any event starting in 8–12 minutes, with people in it, gets a brief once.
    func checkBriefs() async {
        guard briefsEnabled, CalendarSource.isAuthorized, let brain, !isRunning else { return }
        let now = Date()
        let events = CalendarSource.store.events(matching: CalendarSource.store.predicateForEvents(withStart: now.addingTimeInterval(7 * 60), end: now.addingTimeInterval(13 * 60), calendars: nil))
        for e in events where !e.isAllDay {
            guard let id = e.eventIdentifier, !briefs.contains(where: { $0.id == id }) else { continue }
            var names = (e.attendees ?? []).compactMap { (a: EKParticipant) -> String? in
                if a.isCurrentUser { return nil }
                if let n = a.name, !n.isEmpty, !n.contains("@") { return n }
                return a.url.absoluteString.replacingOccurrences(of: "mailto:", with: "").split(separator: "@").first.map(String.init)
            }
            if names.isEmpty, let t = e.title { names = Self.namesIn(t) }
            guard !names.isEmpty else { continue }
            sendLogger.setPurpose("Pre-meeting brief", detail: "“\(e.title ?? "meeting")” · notes about \(names.joined(separator: ", ")) · open loops with them")
            do {
                let (brief, _) = try await BriefWriter(brain: brain, knowledge: knowledge).write(eventID: id, title: e.title ?? "Meeting", startsAt: e.startDate, eventLine: CalendarSource.render(e, detailed: true), attendees: names, loops: loops, cards: cards + pastCards)
                briefs.append(brief); saveBriefs()
                Notifier.brief(brief)
                log.info("brief ready for \(e.title ?? "?")")
            } catch { log.warn("brief failed: \(error)") }
        }
    }
    /// "1:1 with Rohan", "Pricing review — Meera, Rohan": capitalised words that aren't the first.
    static func namesIn(_ title: String) -> [String] {
        let stop: Set<String> = ["Meeting", "Call", "Sync", "Review", "Standup", "Weekly", "Daily", "Monthly", "Catch", "Lunch", "Dinner", "Coffee", "Planning", "Interview", "Demo", "Check", "In", "With", "And", "The", "Team", "All", "Hands"]
        return title.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count > 2 && $0.first!.isUppercase && !stop.contains($0) }.prefix(4).map { $0 }
    }
    func saveBriefs() { set(SettingKey.briefs, json(briefs)) }
    func openBrief(_ id: String) { overlay = .brief(id) }

    // MARK: teach Hands

    func startTeaching() {
        guard Hands.hasAccessibility else { announcement = "Teaching Hands needs Accessibility — System Settings → Privacy & Security."; PermissionProbe.openSettings(for: .accessibility); return }
        markWalkthrough("recipes")
        teach = TeachState(); overlay = .teach
    }
    func teachRecord() {
        teach.step = .watching
        recorder.onChange = { [weak self] in Task { @MainActor in guard let self else { return }; self.teach.steps = self.recorder.steps; self.teach.pending = self.recorder.pendingText; if !self.recorder.isRecording, self.teach.step == .watching { self.teachStop() } } }
        recorder.start()
        NSApp.hide(nil)   // get out of the way: the user does the thing in the other app
    }
    func teachStop() {
        if recorder.isRecording { recorder.stop() }
        NSApp.activate(ignoringOtherApps: true)
        teach.steps = recorder.steps; teach.stoppedBecause = recorder.stoppedBecause
        teach.parameters = Recorder.suggestParameters(teach.steps)
        teach.name = Recorder.suggestName(teach.steps, parameters: teach.parameters)
        teach.step = teach.steps.isEmpty ? .show : .tune
        if teach.steps.isEmpty { announcement = "Nothing was recorded. Do the thing in the other app while Brownie watches, then press Stop." }
    }
    func teachSave() {
        let r = TaughtRecipe(name: teach.name.isEmpty ? "Untitled recipe" : teach.name, steps: teach.steps, parameters: teach.parameters,
                             schedule: teach.weekly ? .weekly(weekday: teach.weekday, hour: teach.hour, minute: teach.minute) : .onDemand, createdAt: Date())
        recipes.append(r); saveRecipes(); teach.savedID = r.id; teach.step = .saved
    }
    func saveRecipes() { set(SettingKey.recipesTaught, json(recipes)); startTriggers() }

    /// One watcher per trigger recipe. A matching file runs the recipe with `file` filled in — and, like every run, waits for you at the last step.
    func startTriggers() {
        let wanted = recipes.filter { $0.schedule.isTrigger }
        for id in watchers.keys where !wanted.contains(where: { $0.id == id }) { watchers[id]?.stop(); watchers[id] = nil }
        for r in wanted {
            guard case .folder(let path, let pattern) = r.schedule else { continue }
            if watchers[r.id] != nil { continue }
            let w = FolderWatcher()
            let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            w.start(folder, pattern: pattern) { [weak self] seen in
                Task { @MainActor in
                    guard let self, !self.recipeRun.running else { return }
                    Notifier.post("“\((seen.path as NSString).lastPathComponent)” arrived", body: "Running “\(r.name)”. Hands stops before the last step.", id: "trigger.\(r.id)")
                    NSApp.activate(ignoringOtherApps: true)
                    self.runRecipe(r.id, answers: ["file": seen.path])
                }
            }
            watchers[r.id] = w
        }
    }
    func updateRecipe(_ r: TaughtRecipe) { if let i = recipes.firstIndex(where: { $0.id == r.id }) { recipes[i] = r; saveRecipes() } }
    /// Re-record just one step: the next thing the user does in the other app replaces it.
    func rerecordStep(_ recipeID: String, at index: Int) {
        guard var r = recipes.first(where: { $0.id == recipeID }), r.steps.indices.contains(index) else { return }
        recorder.onChange = { [weak self] in Task { @MainActor in
            guard let self, let new = self.recorder.steps.last(where: { $0.kind != .launch }) else { return }
            self.recorder.stop(); NSApp.activate(ignoringOtherApps: true)
            if r.steps.indices.contains(index) { r.steps[index] = new; self.updateRecipe(r) }
        } }
        recorder.start(); NSApp.hide(nil)
        announcement = "Do the one step again in the other app — Brownie replaces step \(index + 1) with what you do next."
    }
    func deleteRecipe(_ id: String) { recipes.removeAll { $0.id == id }; saveRecipes() }

    /// Runs a recipe: ask for the parameters marked "ask", write the ones marked "from notes", then replay.
    func runRecipe(_ id: String, answers: [String: String] = [:]) {
        guard let r = recipes.first(where: { $0.id == id }) else { return }
        guard Hands.hasAccessibility else { announcement = "Hands needs Accessibility to run recipes."; return }
        let toAsk = r.parameters.filter { $0.fill == .ask && answers[$0.name] == nil && $0.name != "file" }
        recipeRun = RecipeRunState(recipeID: id, asking: toAsk, answers: answers)
        overlay = .recipeRun(id)
        guard toAsk.isEmpty else { return }
        recipeRun.running = true
        handsState = .running(["Starting “\(r.name)”"])
        NotificationCenter.default.post(name: .brownieRecipeRunning, object: r.name)
        recipeTask = Task {
            var values = answers
            for p in r.parameters where p.fill == .fromNotes {
                guard let brain else { recipeRun.steps.append("“\(p.name)” needs a brain to write it from your notes — Settings → Brain"); recipeRun.running = false; return }
                recipeRun.steps.append("Writing “\(p.name)” from your notes…")
                sendLogger.setPurpose("Fill a recipe from your notes", detail: "recipe “\(r.name)”, the part called \(p.name)")
                let ctx = ((try? await knowledge.search(r.name + " " + p.original, limit: 4)) ?? []).map { "## \($0.relativePath)\n\($0.body.prefix(1500))" }.joined(separator: "\n\n")
                let req = BrainRequest(system: "You write one short message in the user's own voice, nothing else — no quotes, no preamble.", input: "The user taught Hands a recipe called “\(r.name)”. The first time, the part called “\(p.name)” was:\n\(p.original)\n\nWrite this week's version from the user's notes below, same shape and length, updating only what the notes support. If the notes don't say, keep the original wording.\n\nNOTES:\n\(ctx)", effort: .low, maxOutputTokens: 1500, timeout: 120)
                if let out = try? await brain.complete(req), !out.text.isEmpty { values[p.name] = out.text.trimmingCharacters(in: .whitespacesAndNewlines) } else { values[p.name] = p.original }
            }
            for p in r.parameters where p.fill == .fixed { values[p.name] = p.original }
            let fallback: RecipeRunner.ScreenFallback? = hands.map { h in { goal, onStep in
                let o = await h.perform(goal) { e in if case .step(let s) = e { onStep(s) } }
                switch o { case .done(let s): return .done(s); case .pausedForUser(let w): return .pausedForUser(w); case .stopped: return .couldNot("stopped"); case .couldNot(let r): return .couldNot(r) }
            } }
            let runner = RecipeRunner(screenFallback: fallback, screenForbidden: screenForbidden)
            NSApp.hide(nil)
            let outcome = await runner.run(r, values: values) { s in Task { @MainActor in
                self.recipeRun.steps.append(s)
                if case .running(var xs) = self.handsState { xs.append(s); if xs.count > 6 { xs.removeFirst() }; self.handsState = .running(xs) }
            } }
            NSApp.activate(ignoringOtherApps: true)
            recipeRun.running = false; recipeTask = nil
            switch outcome {
            case .pausedForUser(let w): recipeRun.outcome = w; handsState = .paused(w); Notifier.paused("Ready for you", body: w)
            case .done(let s): recipeRun.outcome = "Done — \(s)"; handsState = .finished("Done — \(s)")
            case .couldNot(let why): recipeRun.outcome = why == "stopped" ? "Stopped" : "Couldn't — \(why)"; handsState = .finished(why == "stopped" ? "Stopped" : "Couldn't — \(why)")
            }
            NotificationCenter.default.post(name: .brownieRecipeDone, object: nil)
            if let i = recipes.firstIndex(where: { $0.id == id }) { recipes[i].runs += 1; recipes[i].lastRunAt = Date(); saveRecipes() }
        }
    }

    /// Stop a running recipe now — and Hands, if it had taken over the screen.
    func stopRecipe() {
        guard recipeRun.running else { return }
        recipeTask?.cancel()
        Task { await hands?.stop() }
        recipeRun.steps.append("Stopped by you")
    }
    var runningRecipeName: String? { recipeRun.running ? recipes.first { $0.id == recipeRun.recipeID }?.name : nil }

    func startRecipeSchedule() {
        recipeTimer?.invalidate()
        recipeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkRecipeSchedule() } }
    }
    /// A weekly recipe fires in its minute, once, and waits for the user at the last step.
    func checkRecipeSchedule() {
        let now = Date(), cal = Calendar.current
        for r in recipes {
            guard case .weekly(let d, let h, let m) = r.schedule, cal.component(.weekday, from: now) == d, cal.component(.hour, from: now) == h, cal.component(.minute, from: now) == m else { continue }
            if let last = r.lastRunAt, now.timeIntervalSince(last) < 3600 { continue }
            guard !recipeRun.running, overlay != .teach else { continue }
            NSApp.activate(ignoringOtherApps: true)
            runRecipe(r.id)
        }
    }

    /// `brownie://run?recipe=<name>` and `brownie://ask?text=…` — what Shortcuts and Siri call.
    func handle(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let q = { (k: String) in c.queryItems?.first { $0.name == k }?.value ?? "" }
        switch c.host {
        case "run":
            let name = q("recipe").lowercased()
            if let r = recipes.first(where: { $0.name.lowercased() == name }) ?? recipes.first(where: { $0.name.lowercased().contains(name) }) { NSApp.activate(ignoringOtherApps: true); runRecipe(r.id) }
            else { announcement = "No recipe called “\(q("recipe"))”." }
        case "ask": NotificationCenter.default.post(name: .brownieAsk, object: q("text"))
        case "loops": overlay = .none; screen = .loops; NSApp.activate(ignoringOtherApps: true)
        default: break
        }
    }
    /// A recipe by name from the command bar; nil when the text isn't one.
    func recipe(named text: String) -> TaughtRecipe? {
        let t = text.lowercased().replacingOccurrences(of: "run ", with: "")
        return recipes.first { $0.name.lowercased() == t } ?? recipes.first { t.count > 3 && $0.name.lowercased().contains(t) }
    }

    // MARK: ask

    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return }
        asking = true
        Task {
            // The brain may still be waiting on the Keychain right after launch.
            var waited = 0
            while brain == nil, brainStatus.hasPrefix("Checking"), waited < 60 { try? await Task.sleep(nanoseconds: 500_000_000); waited += 1 }
            guard let brain else { announcement = "Ask needs a brain — Settings → Brain."; asking = false; return }
            sendLogger.setPurpose("Ask Brownie", detail: "your question, the notes the brain chose to read, open loops and waiting cards")
            do {
                let (a, _) = try await Asker(brain: brain, knowledge: knowledge).ask(q, loops: loops.filter { $0.status == .open }, cards: cards)
                asks.append(a); if asks.count > 30 { asks.removeFirst() }
                set(SettingKey.askHistory, json(asks))
                await reloadV2()
            } catch { announcement = "Couldn't answer: \(error)" }
            asking = false
        }
    }
    func clearAsks() { asks = []; set(SettingKey.askHistory, nil) }

    /// A citation chip → the original: the note, the chat, the loop, the card.
    func open(_ c: Asker.Citation) {
        switch c.kind {
        case "note": if let p = c.ref.isEmpty ? nil : (c.ref.hasSuffix(".md") ? c.ref : notePath(named: c.ref)) { openNote(p) } else if let p = notePath(named: c.label.replacingOccurrences(of: "People/", with: "")) { openNote(p) } else { announcement = "That note isn't there any more." }
        case "loop": overlay = .none; screen = .loops
        case "card": if cards.contains(where: { $0.id == c.ref }) { overlay = .card(c.ref) } else { overlay = .none; screen = .forYou }
        case "whatsapp":
            let name = c.ref.isEmpty ? c.label : c.ref
            if let phone = ContactLookup.phone(for: name), let u = URL(string: "whatsapp://send?phone=\(phone)") { NSWorkspace.shared.open(u) } else { NSWorkspace.shared.launchApplication("WhatsApp"); announcement = "Opened WhatsApp — Contacts has no number for \(name), so pick the chat." }
        case "imessage": NSWorkspace.shared.launchApplication("Messages")
        case "mail": NSWorkspace.shared.launchApplication("Mail")
        default: if let p = notePath(named: c.ref) { openNote(p) }
        }
    }
    func run(_ a: Asker.Action) {
        switch a.kind {
        case "loops": overlay = .none; screen = .loops
        case "card": if cards.contains(where: { $0.id == a.ref }) { overlay = .card(a.ref) }
        default: if let p = a.ref.hasSuffix(".md") ? a.ref : notePath(named: a.ref) { openNote(p) }
        }
    }

    // MARK: vault

    func setICloudMode(_ mode: String) {
        icloudMode = mode; set(SettingKey.icloudMode, mode); set(SettingKey.icloudMirror, mode == "off" ? "false" : "true")
        if mode != "off" { syncNow() }
    }
    /// Two-way sync every 15 minutes while the app is open, so a note edited on the phone comes back the same afternoon.
    func startSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in Task { @MainActor in if self?.icloudMode == "twoway" { self?.syncNow(quiet: true) } } }
    }
    func syncNow(quiet: Bool = false) {
        guard icloudMode != "off", let dest = Vault.icloudFolder else { return }
        let root = knowledge.rootURL, mode = icloudMode
        Task.detached { [weak self] in
            do {
                if mode == "twoway" {
                    let r = try Vault.sync(root, to: dest)
                    await MainActor.run { self?.lastSync = r; self?.set(SettingKey.lastSync, self?.json(r) ?? ""); if !quiet { self?.announcement = "Synced with iCloud Drive: \(r.line)." }; Task { await self?.reload() } }
                } else {
                    let n = try Vault.mirror(root, to: dest)
                    await MainActor.run { if !quiet { self?.announcement = "Mirrored to iCloud Drive/Brownie (\(n) notes copied)." } }
                }
            } catch { await MainActor.run { if !quiet { self?.announcement = "Couldn't sync: \(error.localizedDescription)" } } }
        }
    }
    func setICloudMirror(_ on: Bool) {
        icloudMirror = on; set(SettingKey.icloudMirror, on ? "true" : "false")
        if on { let root = knowledge.rootURL; Task.detached { do { let n = try Vault.mirror(root); await MainActor.run { self.announcement = "Mirrored to iCloud Drive/Brownie (\(n) notes copied)." } } catch { await MainActor.run { self.announcement = "Couldn't mirror: \(error.localizedDescription)" } } } }
    }
    /// A `[[Name]]` link → the note it points at, by file name; nil when no such note exists yet.
    func notePath(named name: String) -> String? {
        let n = name.lowercased()
        for f in folders { if let hit = f.notes.first(where: { $0.title.lowercased() == n || $0.relativePath.lowercased().hasSuffix("/" + n + ".md") || $0.relativePath.lowercased() == n + ".md" }) { return hit.relativePath } }
        return nil
    }

    // MARK: other AIs (MCP)

    func setMCP(_ on: Bool) { mcpEnabled = on; set(SettingKey.mcpEnabled, on ? "true" : "false") }
    var mcpExecutable: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }
    func mcpInstalled(_ client: String) -> Bool { MCPServer.configFile(for: client).map(MCPServer.isInstalled) ?? false }
    /// Writes Brownie into the app's own MCP config (merged; nothing else touched). The app must be restarted to see it.
    func installMCP(_ client: String) {
        guard let f = MCPServer.configFile(for: client) else { return }
        do { try MCPServer.install(into: f, executable: mcpExecutable, client: client); if !mcpEnabled { setMCP(true) }; announcement = "Added to \(client). Restart \(client) and Brownie appears in its tools." }
        catch { announcement = "Couldn't write \(f.lastPathComponent): \(error.localizedDescription)" }
    }
    func reloadMCPAsks() async { if let j = try? await store.value(SettingKey.mcpLog), let d = j.data(using: .utf8) { mcpAsks = (try? JSONDecoder().decode([MCPAsk].self, from: d)) ?? [] } }

    // MARK: diagnostics

    /// Logs (never content) plus a summary of this Mac, zipped to the Desktop for a bug report.
    func exportDiagnostics() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
        let stamp = f.string(from: Date())
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("brownie-diagnostics-\(stamp)")
        let out = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Brownie-diagnostics-\(stamp).zip")
        do {
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.createDirectory(at: work.appendingPathComponent("logs"), withIntermediateDirectories: true)
            for u in (try? FileManager.default.contentsOfDirectory(at: Paths.logs, includingPropertiesForKeys: nil)) ?? [] where u.pathExtension == "log" {
                try? FileManager.default.copyItem(at: u, to: work.appendingPathComponent("logs/\(u.lastPathComponent)"))
            }
            let v = ProcessInfo.processInfo.operatingSystemVersion
            var summary = """
            Brownie \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") · macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) · \(ModelCatalog.physicalMemoryGB) GB · \(String(format: "%.0f", freeGB)) GB free
            Reader: \(readerChoice) \(modelPath == nil ? "(not downloaded)" : "(present)")
            Brain: \(brainConfig.engine.rawValue) · \(brainConfig.model) · \(brainStatus)   (no key included)
            Sources on: \(enabledSources.map(\.rawValue).sorted().joined(separator: ", "))
            Permissions: \(permissions.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " "))
            Overnight: \(overnight.enabled ? "on" : "off") \(String(format: "%02d:%02d", overnight.hour, overnight.minute)) · daytime \(overnight.daytime) · helper \(helperInstalled) · login item \(loginItem)
            Last run: \(lastRun.map { "\($0.trigger.rawValue) \($0.startedAt) → \(String(describing: $0.outcome)) · \($0.stats)" } ?? "none")
            Last skipped: \(lastSkipped ?? "—")   Last error: \(lastError ?? "—")
            Cards: \(cards.count) ready · \(pastCards.count) past · loops \(openLoopCount) open · recipes \(recipes.count) · MCP \(mcpEnabled ? "on" : "off")

            """
            summary += "Runs:\n" + runs.map { "  \($0.startedAt) \($0.trigger.rawValue) \(String(describing: $0.outcome)) read=\($0.stats.read) kept=\($0.stats.kept)" }.joined(separator: "\n")
            try summary.write(to: work.appendingPathComponent("summary.txt"), atomically: true, encoding: String.Encoding.utf8)
            try? FileManager.default.removeItem(at: out)
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", work.path, out.path]
            try p.run(); p.waitUntilExit()
            NSWorkspace.shared.activateFileViewerSelecting([out])
            announcement = "Diagnostics saved to your Desktop: \(out.lastPathComponent). Logs and a summary only — no messages, notes or keys."
        } catch { announcement = "Couldn't export diagnostics: \(error.localizedDescription)" }
    }

    // MARK: privacy

    func setShowSendLine(_ on: Bool) { showSendLine = on; set(SettingKey.showSendLine, on ? "true" : "false") }
    func setBriefs(_ on: Bool) { briefsEnabled = on; set(SettingKey.briefsEnabled, on ? "true" : "false") }
    func setScreen(_ app: String, allowed: Bool) {
        if allowed { screenForbidden.remove(app) } else { screenForbidden.insert(app) }
        set(SettingKey.screenForbidden, json(Array(screenForbidden)))
    }

    /// Panic wipe: everything Brownie knows, now. The model files stay unless you also uninstall.
    func eraseEverything() {
        Task {
            try? await store.factoryReset()
            try? await store.setValue(SettingKey.loops, nil)
            try? FileManager.default.removeItem(at: knowledge.rootURL)
            try? FileManager.default.removeItem(at: Paths.applicationSupport.appendingPathComponent("knowledge-index.sqlite"))
            try? FileManager.default.removeItem(at: Paths.applicationSupport.appendingPathComponent("Telegram"))
            await GoogleAuth.shared.signOut()
            Keychain.wipeAll()
            try? WakeHelper.Client().uninstall()
            OvernightScheduler.setLoginItem(false)
            await MainActor.run {
                letter = nil; letterOpened = false; walkthroughDone = []; cards = []; loops = []; sendLog = []; weekly = nil; briefs = []; recipes = []
                helperInstalled = false; loginItem = false; overlay = .none; screen = .forYou
                announcement = "Everything Brownie knew is gone. The reader model is still here; Settings → About → Uninstall removes it too."
            }
            rebuildBrain()
            await reload()
        }
    }
}

extension Notification.Name {
    static let brownieAsk = Notification.Name("brownie.ask")
    static let brownieRecipeRunning = Notification.Name("brownie.recipe.running")
    static let brownieRecipeDone = Notification.Name("brownie.recipe.done")
}
