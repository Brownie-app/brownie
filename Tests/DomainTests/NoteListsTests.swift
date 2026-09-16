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

    @Test func quickOpenRanksRecentFirstThenFuzzy() {
        let e = [QuickOpen.Entry(path: "People/Meera Iyer.md", title: "Meera Iyer"), .init(path: "People/Nayan.md", title: "Nayan"), .init(path: "Work/Mumbai launch.md", title: "Mumbai launch"), .init(path: "People/Karan Mehta.md", title: "Karan Mehta")]
        #expect(QuickOpen.rank("", entries: e, recent: ["People/Nayan.md", "Work/Mumbai launch.md"]).map(\.title) == ["Nayan", "Mumbai launch", "Karan Mehta", "Meera Iyer"], "no query: recent first, then by title")
        #expect(QuickOpen.rank("me", entries: e, recent: []).map(\.title) == ["Meera Iyer", "Karan Mehta"], "a prefix beats a word start; no “e” in Mumbai launch")
        #expect(QuickOpen.rank("ml", entries: e, recent: []).map(\.title) == ["Mumbai launch"], "initials")
        #expect(QuickOpen.rank("zz", entries: e, recent: []).isEmpty)
        #expect(QuickOpen.rank("m", entries: e, recent: ["Work/Mumbai launch.md"]).map(\.title).first == "Mumbai launch", "a recent note edges ahead on a tie-ish query")
        #expect(QuickOpen.score("nay", in: "Nayan") != nil && QuickOpen.score("nyx", in: "Nayan") == nil, "every letter must be there, in order")
    }
}
