import Foundation

/// One sitting in the Notes screen's raw editor: which note, the prose it opened on, and what has been typed since.
/// The two questions the editor must answer live here, pure: is there anything to lose, and did the file change
/// underneath while it was open — the phone's edit at the quarter-hour sync, the night's rewrite, someone at home.
public struct EditSession: Sendable, Equatable {
    /// Where the note is; the gardener may move it to Archive/ while the editor is open, and the sitting follows.
    public var path: String
    /// The prose the editor opened on: the body as the editor shows it, without the status block.
    public let opened: String
    public var draft: String
    public init(path: String, opened: String) { self.path = path; self.opened = opened; self.draft = opened }

    /// Whether there is anything to lose: the draft differs from what was opened, the blank ends aside (the editor adds a trailing newline on its own).
    public var dirty: Bool { Self.trim(draft) != Self.trim(opened) }

    /// What Save may do, given the prose on disk now (nil when the file is gone).
    public enum Check: Equatable {
        /// The file still says what the editor opened on: the draft can be written.
        case clean
        /// Someone changed the file while the editor was open: ask before writing over it.
        case changedOnDisk(theirs: String)
        /// The file is gone — deleted, renamed, moved: the draft can only be saved as a copy.
        case gone
    }
    public func check(onDisk: String?) -> Check {
        guard let onDisk else { return .gone }
        return Self.trim(onDisk) == Self.trim(opened) ? .clean : .changedOnDisk(theirs: onDisk)
    }

    /// Keep both: the note as it is on disk stays the note; the edit follows under its own heading, the shape the phone sync gives a conflict.
    public static func merge(theirs: String, mine: String, at: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "d MMM HH:mm"
        return theirs.trimmingCharacters(in: .newlines) + "\n\n## Your edit (\(f.string(from: at)) — this note changed while you were editing it; pick what you want to keep)\n\n" + mine.trimmingCharacters(in: .newlines) + "\n"
    }

    /// The title a copy of the draft gets when the note it came from is gone: its heading, else the file's name.
    public static func title(of draft: String, path: String) -> String {
        if let h = draft.split(separator: "\n").first(where: { $0.hasPrefix("# ") }) { return String(h.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        let file = path.split(separator: "/").last.map(String.init) ?? path
        return file.hasSuffix(".md") ? String(file.dropLast(3)) : file
    }

    static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}
