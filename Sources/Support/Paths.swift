import Foundation

/// Every on-disk location Brownie owns, in one place.
public enum Paths {
    public static let appName = "Brownie"

    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent(appName, isDirectory: true))
    }
    public static var models: URL { ensure(applicationSupport.appendingPathComponent("Models", isDirectory: true)) }
    public static var modelCache: URL { ensure(applicationSupport.appendingPathComponent("ModelCache", isDirectory: true)) }
    public static var store: URL { applicationSupport.appendingPathComponent("brownie.sqlite") }
    public static var knowledgeBase: URL { ensure(home.appendingPathComponent("\(appName) Knowledge Base", isDirectory: true)) }
    /// Transcripts of audio already read, so a recording is transcribed once. Text only; the audio is never copied.
    public static var transcripts: URL { ensure(applicationSupport.appendingPathComponent("Transcripts", isDirectory: true)) }
    public static var scratch: URL { ensure(applicationSupport.appendingPathComponent("Scratch", isDirectory: true)) }
    public static var logs: URL { FileLog.shared.directoryURL }

    @discardableResult
    public static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
