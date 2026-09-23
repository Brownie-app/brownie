import Testing
import Foundation
@testable import Domain

/// The raw editor's sitting: when there is something to lose, and what Save may do once the file has changed underneath.
@Suite struct EditSessionTests {
    @Test func dirtyMeansTypedSomethingNotATrailingNewline() {
        var s = EditSession(path: "People/Nayra.md", opened: "# Nayra\n\nRuns the Mumbai launch.\n")
        #expect(!s.dirty, "nothing typed yet")
        s.draft = "# Nayra\n\nRuns the Mumbai launch.\n\n"
        #expect(!s.dirty, "the editor's own trailing newline is not an edit")
        s.draft = "# Nayra\n\nRuns the Mumbai launch. Prefers mornings.\n"
        #expect(s.dirty)
    }

    @Test func saveIsCleanOnlyWhileTheFileStillSaysWhatWasOpened() {
        var s = EditSession(path: "People/Nayra.md", opened: "# Nayra\n\nRuns the launch.\n")
        s.draft = "# Nayra\n\nRuns the launch. Prefers mornings.\n"
        #expect(s.check(onDisk: "# Nayra\n\nRuns the launch.\n") == .clean)
        #expect(s.check(onDisk: "# Nayra\n\nRuns the launch.\n\n") == .clean, "a blank line at the end is not a change on disk either")
        let phone = "# Nayra\n\nRuns the launch. Moved to Pune.\n"
        #expect(s.check(onDisk: phone) == .changedOnDisk(theirs: phone), "the phone's paragraph landed while the editor was open")
        #expect(s.check(onDisk: nil) == .gone, "the file went — deleted, renamed, archived")
    }

    @Test func keepBothPutsTheirsFirstAndTheEditUnderItsOwnHeading() {
        let at = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: TimeZone(identifier: "Asia/Kolkata"), year: 2026, month: 9, day: 17, hour: 7, minute: 30))!
        let merged = EditSession.merge(theirs: "# Nayra\n\nMoved to Pune.\n\n", mine: "# Nayra\n\nPrefers mornings.\n", at: at)
        let lines = merged.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "# Nayra" && merged.hasPrefix("# Nayra\n\nMoved to Pune.\n\n## Your edit ("), "what is on disk stays the note; the edit follows")
        #expect(lines.contains { $0.hasPrefix("## Your edit (") && $0.contains("this note changed while you were editing it") })
        #expect(merged.hasSuffix("Prefers mornings.\n") && !merged.contains("\n\n\n\n"), "one blank line between the parts, the edit's own blank ends trimmed")
    }

    @Test func aCopyIsTitledByItsHeadingElseItsFileName() {
        #expect(EditSession.title(of: "# Nayra Shah\n\ntext", path: "People/Nayra.md") == "Nayra Shah")
        #expect(EditSession.title(of: "just prose, no heading", path: "People/Nayra.md") == "Nayra")
        #expect(EditSession.title(of: "", path: "Loose.md") == "Loose")
    }
}
