import Testing
import Foundation
@testable import Domain

/// The rail's short lists: recent notes (eight, newest first, no repeats), pins, and the ⌘K ranking.
@Suite struct NoteListsTests {
    @Test func recentMovesToFrontDedupesAndCapsAtEight() {
        var r = RecentNotes()
        for i in 1...10 { r.open("n\(i)") }
        #expect(r.paths == ["n10", "n9", "n8", "n7", "n6", "n5", "n4", "n3"], "the cap is eight, newest first")
        r.open("n5")
        #expect(r.paths == ["n5", "n10", "n9", "n8", "n7", "n6", "n4", "n3"], "reopening moves to the front without a duplicate")
        r.remove("n9")
        #expect(r.paths.count == 7 && !r.paths.contains("n9"))
        #expect(r.pruned(existing: ["n5", "n3"]).paths == ["n5", "n3"], "a note that is gone drops out")
        #expect(RecentNotes(paths: ["a", "b", "a", "c", "d", "e", "f", "g", "h", "i"]).paths == ["a", "b", "c", "d", "e", "f", "g", "h"], "what UserDefaults hands back is cleaned the same way")
    }

    @Test func pinsToggleInOrder() {
        var p = PinnedNotes()
        p.toggle("a"); p.toggle("b"); p.toggle("a")
        #expect(p.paths == ["b"] && !p.contains("a") && p.contains("b"))
        p.toggle("a")
        #expect(p.paths == ["b", "a"])
        #expect(p.pruned(existing: ["a"]).paths == ["a"])
    }

    /// The gardener moves People/Meena.md to People/Archive/Meena.md at 3 AM; Obsidian renames Nayra; a pin follows the
    /// first and drops the second, and nothing that is still there is touched.
    @Test func listsFollowAnArchiveMoveAndDropOnlyWhatIsNowhere() {
        let existing: Set<String> = ["People/Archive/Meena.md", "People/Devan.md", "Work/Launch.md"]
        func moved(_ p: String) -> String? {
            let archived = p.replacingOccurrences(of: "People/", with: "People/Archive/"), active = p.replacingOccurrences(of: "/Archive/", with: "/")
            return [archived, active].first { $0 != p && existing.contains($0) }
        }
        let pins = PinnedNotes(paths: ["People/Meena.md", "People/Nayra.md", "People/Devan.md"]).settled(existing: existing, moved: moved)
        #expect(pins.paths == ["People/Archive/Meena.md", "People/Devan.md"], "the archived note is followed, the renamed one dropped, the order kept")
        let recent = RecentNotes(paths: ["People/Nayra.md", "People/Meena.md", "Work/Launch.md", "People/Archive/Meena.md"]).settled(existing: existing, moved: moved)
        #expect(recent.paths == ["People/Archive/Meena.md", "Work/Launch.md"], "the old and the new spelling of one note fold into one entry, where the first stood")
        #expect(PinnedNotes(paths: ["People/Archive/Devan.md"]).settled(existing: existing, moved: moved).paths == ["People/Devan.md"], "a note brought back from the archive is followed the other way")
        #expect(NoteLists.settle([], existing: existing, moved: moved).isEmpty)
    }

    @Test func placeWordsNameTheFolderNeverThePath() {
        #expect(NoteLists.placeWords("People/Meena Iyer.md") == "in People")
        #expect(NoteLists.placeWords("People/Archive/Meena Iyer.md") == "in the People archive")
        #expect(NoteLists.placeWords("Work/2025/Launch.md") == "in Work › 2025")
        #expect(NoteLists.placeWords("Loose note.md") == "at the top of the vault")
    }

    @Test func movedLineSaysWhereAndHowQuiet() {
        #expect(NoteLists.movedLine(title: "Meena", intoArchive: true, quietDays: 190) == "Meena is in the archive now — quiet for 6 months.")
        #expect(NoteLists.movedLine(title: "Meena", intoArchive: true, quietDays: 45) == "Meena is in the archive now — quiet for a month.")
        #expect(NoteLists.movedLine(title: "Meena", intoArchive: true, quietDays: 12) == "Meena is in the archive now — quiet for 12 days.")
        #expect(NoteLists.movedLine(title: "Meena", intoArchive: true, quietDays: nil) == "Meena is in the archive now.")
        #expect(NoteLists.movedLine(title: "Meena", intoArchive: false, quietDays: 3) == "Meena is back from the archive.")
    }

    @Test func quickOpenRanksRecentFirstThenFuzzy() {
        let e = [QuickOpen.Entry(path: "People/Meena Iyer.md", title: "Meena Iyer"), .init(path: "People/Nayra.md", title: "Nayra"), .init(path: "Work/Mumbai launch.md", title: "Mumbai launch"), .init(path: "People/Devan Mehra.md", title: "Devan Mehra")]
        #expect(QuickOpen.rank("", entries: e, recent: ["People/Nayra.md", "Work/Mumbai launch.md"]).map(\.title) == ["Nayra", "Mumbai launch", "Devan Mehra", "Meena Iyer"], "no query: recent first, then by title")
        #expect(QuickOpen.rank("me", entries: e, recent: []).map(\.title) == ["Meena Iyer", "Devan Mehra"], "a prefix beats a word start; no “e” in Mumbai launch")
        #expect(QuickOpen.rank("ml", entries: e, recent: []).map(\.title) == ["Mumbai launch"], "initials")
        #expect(QuickOpen.rank("zz", entries: e, recent: []).isEmpty)
        #expect(QuickOpen.rank("m", entries: e, recent: ["Work/Mumbai launch.md"]).map(\.title).first == "Mumbai launch", "a recent note edges ahead on a tie-ish query")
        #expect(QuickOpen.score("nay", in: "Nayra") != nil && QuickOpen.score("nyx", in: "Nayra") == nil, "every letter must be there, in order")
    }
}
