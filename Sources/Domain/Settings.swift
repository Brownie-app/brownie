import Foundation

/// Keys for the key/value part of the store. One place, so nothing is a magic string twice.
public enum SettingKey {
    public static let enabledSources = "sources.enabled"           // JSON [SourceID]
    public static func enabledBuckets(_ s: SourceID) -> String { "sources.\(s.rawValue).buckets" } // JSON [BucketID]
    public static let fileRoots = "sources.files.roots"           // JSON [String]
    public static let recordingsFolder = "sources.recordings.folder"   // path; default ~/Recordings
    public static let firstRead = "sources.firstRead"             // JSON FirstRead — what a first read of each source covers
    public static let brainEngine = "brain.engine"                // openai | anthropic | openrouter | custom | none
    public static let brainModel = "brain.model"
    public static let brainEffort = "brain.effort"
    public static let customBaseURL = "brain.custom.baseURL"
    public static let customModel = "brain.custom.model"
    public static let cardsPerMorning = "proactive.cardsPerMorning"
    public static let notifyOnReady = "proactive.notify"
    public static let standingInstructions = "proactive.instructions"
    public static let household = "household.config"              // JSON Household
    public static let householdLastSync = "household.lastSync"    // JSON SyncReport
    public static let householdBucketNames = "household.bucketNames"  // JSON [bucket raw value: chat name], kept by the app
    public static let asks = "proactive.asks"                     // JSON [Ask], local only
    public static let feedback = "proactive.feedback"             // JSON [CardFeedback], newest last
    public static let signature = "hands.signature"              // "true" → drafts end with the Brownie sign-off
    public static let handsHotkey = "hands.hotkey"                // rightCommand | rightOption | off
    public static let handsSpeed = "hands.speed"                  // fast | balanced | careful
    public static let overnightEnabled = "overnight.enabled"
    public static let overnightTime = "overnight.time"            // "03:00"
    public static let catchUp = "overnight.catchUp"
    public static let daytime = "overnight.daytime"
    public static let icloudMirror = "knowledge.icloudMirror"    // legacy: "true" meant mirror
    public static let icloudMode = "knowledge.icloudMode"        // off | mirror | twoway
    public static let lastSync = "knowledge.lastSync"            // JSON SyncReport
    public static let coverage = "sources.coverage"              // JSON [SourceCoverage]: how far back each source has been read
    public static let mcpEnabled = "knowledge.mcp"               // answer other apps over MCP
    public static let mcpLog = "knowledge.mcpLog"
    public static let askHistory = "proactive.ask"
    public static let staleDays = "proactive.staleDays"            // notes older than this many days no longer carry a card alone (default 7)
    public static let nudgeDays = "proactive.nudgeDays"            // 1 | 2 | 0 — a card this many days before a loop's due date; 0 = only when asked                // JSON [Asker.Answer], newest last, capped                // JSON [MCPAsk], newest first, capped              // h1 | h3 | off — reads during the day while idle and on power
    public static let appearance = "app.appearance"               // system | light | dark
    public static let menuBarIcon = "app.menuBarIcon"
    public static let onboardingDone = "app.onboardingDone"
    public static let letter = "proactive.letter"                 // the welcome letter text
    public static let letterOpened = "proactive.letterOpened"
    public static let cards = "proactive.cards"                   // JSON [Card]
    public static let candidates = "proactive.candidates"         // JSON [ActionItem]
    public static let kbResume = "knowledge.resume"
    public static let localModel = "reader.model"                 // E4B | E2B
    public static let diagnosticsCrash = "diag.crash"
    public static let diagnosticsUsage = "diag.usage"
    public static let loops = "proactive.loops"                   // JSON [Loop]
    public static let recipesTaught = "hands.recipes"             // JSON [TaughtRecipe]
    public static let briefs = "proactive.briefs"                 // JSON [Brief]
    public static let briefsEnabled = "proactive.briefs.enabled"
    public static func weekly(_ isoWeek: String) -> String { "proactive.weekly.\(isoWeek)" }
    public static let weeklyLatest = "proactive.weekly.latest"    // the iso week of the newest letter
    public static let showSendLine = "privacy.showSendLine"
    public static let replaceNames = "privacy.replaceNames"
    public static let screenForbidden = "hands.screenForbidden"   // JSON [String] app names Hands may not drive by screen
    public static func walkthrough(_ key: String) -> String { "walkthrough.\(key)" }
}
