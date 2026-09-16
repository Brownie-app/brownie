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
import TelegramSource
import CloudSources
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
        FirstRead.current = await FirstRead.load(from: store)
        loops = await LoopLedger.load(store)
        await reloadMCPAsks()
        if let j = try? await store.value(SettingKey.askHistory), let d = j.data(using: .utf8) { asks = (try? JSONDecoder().decode([Asker.Answer].self, from: d)) ?? [] }
        sendLog = (try? await store.sendLog(since: Date().addingTimeInterval(-30 * 86400))) ?? []
        weeklyWeek = try? await store.value(SettingKey.weeklyLatest)
        vaultHealth = VaultHealth.latest(from: try? await store.value(SettingKey.vaultHealth))
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
        loops[i].status = .closed; loops[i].closedAt = Date(); loops[i].closedHow = how; loops[i].closedBy = "user"
        let ls = loops; Task { await LoopLedger.save(ls, store) }
    }
    func setStaleDays(_ d: Int) { staleDays = d; set(SettingKey.staleDays, String(d)); Task { await reload() } }

    // MARK: first read

    /// "Read further back": widen one source's first-read window by a step, remember it, and forget the source's
    /// cursors so the next run treats its buckets as first reads with the wider window. Already-read items inside
    /// the old window are read once more on that run; the note builder folds duplicates into the notes it has, and
    /// the source's coverage line starts over with them so they are not counted twice.
    func readFurtherBack(_ source: SourceID) {
        var p = FirstRead.current; p.readFurtherBack(source); FirstRead.current = p
        objectWillChange.send()
        let name = allSources.first { $0.id == source }?.descriptor.name ?? source.rawValue
        announcement = "\(name) will read back \(p.days(for: source)) days on the next run."
        Task {
            do {
                try await p.save(to: store); try await store.resetCursors(for: source)
                let kept = SourceCoverage.forgetting(source, in: SourceCoverage.decode(try await store.value(SettingKey.coverage)))
                try await store.setValue(SettingKey.coverage, kept.isEmpty ? nil : SourceCoverage.encode(kept))
            } catch { announcement = "Couldn't widen \(name)'s window: \(error)" }
        }
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
        case "oauth":
            // The Slack callback, bounced off the website: brownie://oauth/slack?code=…&state=…
            if c.path == "/slack" { var p: [String: String] = [:]; for i in c.queryItems ?? [] { p[i.name] = i.value ?? "" }; Task { await SlackAuth.shared.receive(p) }; NSApp.activate(ignoringOtherApps: true) }
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
                askStatus = "Reading your notes…"
                let (a, _) = try await Asker(brain: brain, knowledge: knowledge).ask(q, loops: loops.filter { $0.status == .open }, cards: cards, onProgress: { line in Task { @MainActor [weak self] in self?.askStatus = line } })
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
        case "whatsapp", "imessage", "telegram", "slack", "teams":
            let name = c.ref.isEmpty ? c.label : c.ref
            openEvidence(source: "\(c.kind) · \(EvidenceRef.cleanName(name.split(separator: "·").first.map(String.init) ?? name))", when: c.label, text: asks.last?.answer ?? "")
        case "mail": NSWorkspace.shared.launchApplication("Mail")
        case "recording", "voicememo": openEvidence(source: "Recording · \(c.ref.isEmpty ? c.label : c.ref)", when: c.label, text: "")
        default: if let p = notePath(named: c.ref) { openNote(p) }
        }
    }
    /// A citation into something said out loud: the recording opens in its player; a Voice Memo opens the app.
    func openRecording(named name: String) {
        let stem = name.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.lowercased().hasPrefix("recording") && !$0.lowercased().hasPrefix("voice") } ?? name
        let wanted = (stem as NSString).deletingPathExtension.lowercased()
        for folder in [recordingsFolder, VoiceMemosSource.folder] {
            if let f = AudioFolder.recordings(in: folder, settled: 0).first(where: { $0.url.deletingPathExtension().lastPathComponent.lowercased() == wanted }) {
                if folder == VoiceMemosSource.folder { NSWorkspace.shared.launchApplication("Voice Memos") } else { NSWorkspace.shared.open(f.url) }
                return
            }
        }
        NSWorkspace.shared.launchApplication("Voice Memos"); announcement = "Couldn't find “\(stem)” — opened Voice Memos."
    }
    func run(_ a: Asker.Action) {
        switch a.kind {
        case "loops": overlay = .none; screen = .loops
        case "card": if cards.contains(where: { $0.id == a.ref }) { overlay = .card(a.ref) }
        default: if let p = a.ref.hasSuffix(".md") ? a.ref : notePath(named: a.ref) { openNote(p) }
        }
    }

    /// Stop whatever Hands is doing — a card being fired, a goal from the bar, a recipe. Nothing irreversible has happened, so stopping is always safe.
    func stopHands() {
        stopRecipe()
        Task { await hands?.stop() }
        if !fireEvents.contains(where: { if case .finished = $0 { return true }; return false }) { fireEvents.append(.step("Stopping…", done: false)) }
    }

    // MARK: evidence

    /// Clicking an evidence line or a citation chip: the original, read on demand and never stored.
    func openEvidence(source: String, when: String, text: String) {
        let ref = EvidenceRef.parse(source: source)
        switch ref {
        case .note(let path): if let p = path.hasSuffix(".md") ? path : notePath(named: path) { openNote(p) } else { announcement = "That note isn't there any more." }
        case .loops: overlay = .none; screen = .loops
        case .recording(let name, let seconds): evidenceShown = EvidenceShown(ref: ref, source: source, when: when, text: text, state: .clip(name: name, seconds: seconds ?? 0, url: recordingURL(named: name)))
        case .mail: NSWorkspace.shared.launchApplication("Mail")
        case .file(let label): announcement = "That came from \(label) — the summary is what Brownie kept; the file itself is where it was."
        case .unknown: announcement = "Brownie can't open “\(source)” — it's the summary's own label."
        case .chat(let app, _):
            guard let reader = chatReader(for: app) else { announcement = "\(app.capitalized) isn't set up on this Mac."; return }
            evidenceShown = EvidenceShown(ref: ref, source: source, when: when, text: text, state: .loading)
            Task.detached { [weak self] in
                do {
                    let w = try await EvidenceResolver.resolve(ref, when: when, text: text, reader: reader)
                    await MainActor.run { guard let self, self.evidenceShown?.source == source else { return }; self.evidenceShown?.state = w.map { .window($0) } ?? .missing("Couldn't find a chat called “\(EvidenceRef.cleanName(Self.chatName(ref)))” in \(app.capitalized).") }
                } catch { await MainActor.run { self?.evidenceShown?.state = .missing("Couldn't read \(app.capitalized): \(error)") } }
            }
        }
    }
    static func chatName(_ r: EvidenceRef) -> String { if case .chat(_, let n) = r { return n }; return "" }
    func chatReader(for app: String) -> (any ChatReader)? {
        switch app {
        case "whatsapp": return WhatsAppSource()
        case "imessage": return iMessageSource()
        case "telegram": return TelegramSource.isConfigured ? TelegramSource() : nil
        case "slack": return SlackAuth.isSignedIn ? SlackSource() : nil
        case "teams": return MicrosoftAuth.isSignedIn ? TeamsSource() : nil
        default: return nil
        }
    }
    func recordingURL(named name: String) -> URL? {
        let wanted = (name as NSString).deletingPathExtension.lowercased()
        for folder in [recordingsFolder, VoiceMemosSource.folder] {
            if let f = AudioFolder.recordings(in: folder, settled: 0).first(where: { $0.url.deletingPathExtension().lastPathComponent.lowercased() == wanted }) { return f.url }
        }
        return nil
    }
    /// "Open in WhatsApp" from the evidence sheet: the app's own chat, as before.
    func openChatApp(_ app: String, name: String) {
        switch app {
        case "whatsapp": if let phone = ContactLookup.phone(for: name), let u = URL(string: "whatsapp://send?phone=\(phone)") { NSWorkspace.shared.open(u) } else { NSWorkspace.shared.launchApplication("WhatsApp") }
        case "imessage": NSWorkspace.shared.launchApplication("Messages")
        case "telegram": NSWorkspace.shared.launchApplication("Telegram")
        case "slack": NSWorkspace.shared.launchApplication("Slack")
        case "teams": NSWorkspace.shared.launchApplication("Microsoft Teams")
        default: break
        }
    }

    // MARK: household

    /// Start sharing with one person now; the model holds a list, so more can join later.
    func startHousehold(with name: String, phone: String, folder: URL?) {
        let dest = folder ?? HouseholdVault.defaultFolder ?? knowledge.rootURL.deletingLastPathComponent().appendingPathComponent(HouseholdVault.defaultFolderName)
        let meName = (try? FileManager.default.attributesOfItem(atPath: NSHomeDirectory()))?[.ownerAccountName] as? String ?? NSFullUserName()
        let h = Household(members: [HouseholdMember(name: NSFullUserName().isEmpty ? meName : NSFullUserName(), isMe: true), HouseholdMember(name: name.trimmingCharacters(in: .whitespaces), isMe: false, phone: phone.isEmpty ? nil : HouseholdEligibility.digits(phone))], folderPath: dest.path, since: Date())
        try? FileManager.default.createDirectory(at: dest.appendingPathComponent("Household"), withIntermediateDirectories: true)
        household = h; set(SettingKey.household, json(h))
        Task { await refreshEligibleChats(); householdSyncNow(quiet: true) }
    }
    func leaveHousehold() { household = nil; eligibleChats = []; householdLastSync = nil; set(SettingKey.household, nil); set(SettingKey.householdLastSync, nil); set(SettingKey.householdBucketNames, nil) }
    func setHouseholdMemberPhone(_ id: String, _ phone: String) {
        guard var h = household, let i = h.members.firstIndex(where: { $0.id == id }) else { return }
        h.members[i].phone = phone.isEmpty ? nil : HouseholdEligibility.digits(phone); household = h; set(SettingKey.household, json(h))
        Task { await refreshEligibleChats() }
    }
    func toggleSharedChat(_ b: BucketInfo) {
        guard var h = household else { return }
        if let i = h.sharedBuckets.firstIndex(of: b.id.rawValue) { h.sharedBuckets.remove(at: i) } else { h.sharedBuckets.append(b.id.rawValue) }
        household = h; set(SettingKey.household, json(h))
        // the pipeline needs the chat's name to find its Groups/ note
        var names = (try? JSONDecoder().decode([String: String].self, from: Data((UserDefaults.standard.string(forKey: "household.bucketNames") ?? "{}").utf8))) ?? [:]
        names[b.id.rawValue] = b.name
        let j = json(names); UserDefaults.standard.set(j, forKey: "household.bucketNames"); set(SettingKey.householdBucketNames, j)
    }
    /// Which group chats every other member is in — asks each source for its members.
    func refreshEligibleChats() async {
        guard let h = household, !h.others.isEmpty else { eligibleChats = []; return }
        checkingEligible = true; defer { checkingEligible = false }
        var out: [BucketInfo] = []
        for (s, members) in [("whatsapp", { (b: BucketID) async throws -> [String] in try await WhatsAppSource().members(of: b) }), ("imessage", { (b: BucketID) async throws -> [String] in try await iMessageSource().members(of: b) })] {
            guard availability[SourceID(s)] == .available, let chats = discovered[SourceID(s)] else { continue }
            for c in chats where c.isGroup {
                if let m = try? await members(c.id), HouseholdEligibility.isEligible(chatMembers: m, others: h.others) { out.append(c) }
            }
        }
        eligibleChats = out.sorted { (h.isShared($0.id) ? 0 : 1, -$0.count) < (h.isShared($1.id) ? 0 : 1, -$1.count) }
    }
    func householdSyncNow(quiet: Bool = false) {
        guard let h = household else { return }
        let root = knowledge.rootURL, store = self.store
        Task.detached { [weak self] in
            do {
                let r = try await RunCoordinator.syncHousehold(h, root: root, store: store, now: Date())
                await MainActor.run { self?.householdLastSync = r; self?.set(SettingKey.householdLastSync, self?.json(r) ?? ""); if !quiet { self?.announcement = "Household synced: \(r.line)." }; Task { await self?.reload() } }
            } catch { await MainActor.run { if !quiet { self?.announcement = "Couldn't sync the household: \(error.localizedDescription)" } } }
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
        syncTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in Task { @MainActor in if self?.icloudMode == "twoway" { self?.syncNow(quiet: true) }; if self?.household != nil { self?.householdSyncNow(quiet: true) } } }
    }
    func syncNow(quiet: Bool = false) {
        guard icloudMode != "off", let dest = Vault.icloudFolder else { return }
        let root = knowledge.rootURL, mode = icloudMode
        let today = TodayNote.render(cards: cards + snoozedCards, date: Date())
        let store = self.store
        Task.detached { [weak self] in
            do {
                if mode == "twoway" {
                    // Today.md goes out with the notes; what the phone ticked comes back.
                    try? today.write(to: root.appendingPathComponent(TodayNote.path), atomically: true, encoding: .utf8)
                    let r = try Vault.sync(root, to: dest)
                    var ticked = 0
                    if let md = try? String(contentsOf: root.appendingPathComponent(TodayNote.path), encoding: .utf8) {
                        var all = (try? await RunCoordinator.loadCards(store: store)) ?? []
                        let done = TodayNote.apply(TodayNote.parse(md), to: &all, now: Date())
                        if !done.isEmpty { try? await RunCoordinator.saveCards(all, store: store); ticked = done.count }
                    }
                    let n = ticked
                    await MainActor.run { self?.lastSync = r; self?.set(SettingKey.lastSync, self?.json(r) ?? ""); if !quiet { self?.announcement = "Synced with iCloud Drive: \(r.line)." + (n > 0 ? " \(n) card\(n == 1 ? "" : "s") ticked on your phone — marked done." : "") } else if n > 0 { self?.announcement = "\(n) card\(n == 1 ? "" : "s") ticked on your phone — marked done." }; Task { await self?.reload() } }
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

// MARK: - People: one identity each

extension AppModel {
    /// The night's suspect pairs, read back against the registry as it is now: a pair the user merged or split
    /// since is gone. Without a saved list (no run yet), the registry's own view is shown.
    func reloadPeople() async {
        let registry = PersonRegistry(vault: knowledge.rootURL); await registry.load()
        let live = await registry.suspects()
        guard let j = try? await store.value(SettingKey.duplicatePeople), let d = j.data(using: .utf8), let stored = try? JSONDecoder().decode([[String]].self, from: d) else { duplicatePeople = live; return }
        duplicatePeople = stored.compactMap { ids in live.first { Set(ids) == Set([$0.0.id, $0.1.id]) } }
    }

    /// Merge two registry people: the kept one takes every alias and handle; the dropped note's body goes under a
    /// "Merged from" heading in the kept note, every `[[link]]` to it now points at the kept note, loops and asks
    /// spelled the dropped way carry the kept name, and the dropped file is deleted.
    func mergePeople(keep: String, drop: String) {
        Task {
            let registry = PersonRegistry(vault: knowledge.rootURL); await registry.load()
            guard let k = await registry.person(keep), let d = await registry.person(drop), keep != drop else { await reloadPeople(); return }
            let dropKeys = Set(d.keys)
            await registry.merge(keep: keep, drop: drop)
            if let dp = d.notePath, let dn = try? await knowledge.note(at: dp) {
                if let kp = k.notePath, let kn = try? await knowledge.note(at: kp) {
                    // The dropped note's status block is not carried over: the next run renders the merged person's items into the kept note's own block.
                    let body = PersonNotes.appendMerged(into: kn.body, droppedBody: dn.body, droppedName: d.name, date: Date(),
                                                        stripping: [(StatusBlock.open, StatusBlock.close), (StatusBlock.legacyOpen, StatusBlock.legacyClose)])
                    try? await knowledge.save(Note(relativePath: kp, title: kn.title, body: body, sources: Array(Set(kn.sources + dn.sources)).sorted(), updatedAt: Date(), userEdited: true))
                    await rewriteLinks(from: [Self.fileName(dp), dn.title], to: Self.fileName(kp))
                    try? await knowledge.delete(relativePath: dp)
                    log.info("merged \(dp) into \(kp)")
                }
                // No kept note: the dropped note is now theirs, and the registry already points at it.
            }
            var ls = await LoopLedger.load(store); var changed = false
            for i in ls.indices where dropKeys.contains(PersonKey.normalise(ls[i].person)) && !PersonKey.sameKey(ls[i].person, k.name) { ls[i] = ls[i].renamed(to: k.name); changed = true }
            if changed { await LoopLedger.save(ls, store) }
            var asks = RunCoordinator.loadAsks(try? await store.value(SettingKey.asks)); changed = false
            for i in asks.indices where dropKeys.contains(PersonKey.normalise(asks[i].person)) && !PersonKey.sameKey(asks[i].person, k.name) { asks[i] = asks[i].renamed(to: k.name); changed = true }
            if changed { try? await store.setValue(SettingKey.asks, json(asks)) }
            do { try await registry.save() } catch { announcement = "The people registry couldn't be saved: \(error)" }
            await reload()
        }
    }

    func keepPeopleSeparate(_ a: String, _ b: String) {
        Task {
            let registry = PersonRegistry(vault: knowledge.rootURL); await registry.load()
            await registry.keepSeparate(a, b)
            do { try await registry.save() } catch { announcement = "The people registry couldn't be saved: \(error)" }
            await reloadPeople()
        }
    }

    /// `[[Old]]` → `[[New]]` in every note, written straight to the files with the front-matter's hash moved along, so no note counts as the user's edit.
    private func rewriteLinks(from olds: [String], to new: String) async {
        for f in (try? await knowledge.folders()) ?? [] {
            for n in f.notes {
                let url = knowledge.rootURL.appendingPathComponent(n.relativePath)
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let rewritten = NoteMeta.restamp(raw, path: n.relativePath) { body in
                    var text = body, touched = false
                    for old in Set(olds) where old != new { if let t = PersonNotes.rewriteLinks(in: text, from: old, to: new) { text = t; touched = true } }
                    return touched ? text : nil
                }
                if let rewritten { try? rewritten.write(to: url, atomically: true, encoding: .utf8) }
            }
        }
    }
    static func fileName(_ relativePath: String) -> String { ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension }
}

extension Notification.Name {
    static let brownieAsk = Notification.Name("brownie.ask")
    static let brownieRecipeRunning = Notification.Name("brownie.recipe.running")
    static let brownieRecipeDone = Notification.Name("brownie.recipe.done")
}
