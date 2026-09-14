import Foundation

/// Keys for the key/value part of the store. One place, so nothing is a magic string twice.
public enum SettingKey {
    public static let enabledSources = "sources.enabled"           // JSON [SourceID]
    public static func enabledBuckets(_ s: SourceID) -> String { "sources.\(s.rawValue).buckets" } // JSON [BucketID]
    public static let fileRoots = "sources.files.roots"           // JSON [String]
    public static let brainEngine = "brain.engine"                // openai | anthropic | openrouter | custom | none
    public static let brainModel = "brain.model"
    public static let brainEffort = "brain.effort"
    public static let customBaseURL = "brain.custom.baseURL"
    public static let customModel = "brain.custom.model"
    public static let cardsPerMorning = "proactive.cardsPerMorning"
    public static let notifyOnReady = "proactive.notify"
    public static let standingInstructions = "proactive.instructions"
    public static let handsHotkey = "hands.hotkey"                // rightCommand | rightOption | off
    public static let handsSpeed = "hands.speed"                  // fast | balanced | careful
    public static let overnightEnabled = "overnight.enabled"
    public static let overnightTime = "overnight.time"            // "03:00"
    public static let catchUp = "overnight.catchUp"
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
    public static func walkthrough(_ key: String) -> String { "walkthrough.\(key)" }
}
