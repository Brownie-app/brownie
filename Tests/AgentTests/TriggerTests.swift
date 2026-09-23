import Testing
import Foundation
@testable import Agent
import Domain

@Suite struct GlobTests {
    @Test func stars() {
        #expect(Glob.matches("*invoice*.pdf", "Zoho-Invoice-2026.pdf"))
        #expect(Glob.matches("*.pdf", "a.PDF"))
        #expect(!Glob.matches("*.pdf", "a.pdf.download"))
        #expect(Glob.matches("*", "anything"))
        #expect(Glob.matches("report-??.csv", "report-09.csv"))
        #expect(!Glob.matches("report-??.csv", "report-9.csv"))
        #expect(!Glob.matches("invoice*", "myinvoice.pdf"))
    }
}

@Suite struct FolderWatcherTests {
    func temp() throws -> URL { let u = FileManager.default.temporaryDirectory.appendingPathComponent("fw-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u }
    func write(_ dir: URL, _ name: String, age: TimeInterval = 10) throws -> URL {
        let u = dir.appendingPathComponent(name); try "x".write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: u.path); return u
    }
    @Test func onlyNewMatchingSettledFiles() throws {
        let d = try temp()
        let old = try write(d, "old-invoice.pdf")
        let fresh = try write(d, "new-invoice.pdf")
        _ = try write(d, "notes.txt")
        _ = try write(d, "busy-invoice.pdf", age: 0)           // still being written
        _ = try write(d, ".hidden-invoice.pdf")
        let found = FolderWatcher.newFiles(in: d, pattern: "*invoice*.pdf", known: [old.resolvingSymlinksInPath().path])
        #expect(found.map(\.path) == [fresh.resolvingSymlinksInPath().path])
    }
    @Test func partialDownloadsAreIgnored() throws {
        let d = try temp(); _ = try write(d, "inv.pdf.crdownload"); _ = try write(d, "inv.pdf.part")
        #expect(FolderWatcher.newFiles(in: d, pattern: "*", known: []).isEmpty)
    }
    @Test func startRemembersExistingFilesAndFiresOnNewOnes() async throws {
        let d = try temp(); _ = try write(d, "already-there.pdf")
        let w = FolderWatcher()
        let box = Box()
        w.start(d, pattern: "*.pdf") { seen in Task { await box.add(seen.path) } }
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = try write(d, "arrived.pdf", age: 5)
        try await Task.sleep(nanoseconds: 4_500_000_000)
        let got = await box.paths
        #expect(got.map { ($0 as NSString).lastPathComponent } == ["arrived.pdf"], "only the file that arrived after watching began")
        w.stop()
    }
    actor Box { var paths: [String] = []; func add(_ p: String) { paths.append(p) } }
}

@Suite struct TriggerSubstitutionTests {
    @Test func fileFillsPlaceholders() {
        let r = TaughtRecipe(name: "File it", steps: [.init(kind: .launch, app: "Mail", target: "Mail"), .init(kind: .type, app: "Mail", target: "Body", role: "TextField", text: "Invoice {filename} attached: {file}")], parameters: [], schedule: .folder(path: "~/Downloads", pattern: "*.pdf"), createdAt: Date())
        let steps = RecipeRunner.substituted(r, values: ["file": "/Users/v/Downloads/zoho.pdf"])
        #expect(steps[1].text == "Invoice zoho.pdf attached: /Users/v/Downloads/zoho.pdf")
    }
    @Test func scheduleLineAndFlag() {
        let s = TaughtRecipe.Schedule.folder(path: "/Users/v/Downloads", pattern: "*invoice*.pdf")
        #expect(s.isTrigger); #expect(s.line.hasPrefix("When *invoice*.pdf arrives in "))
        #expect(!TaughtRecipe.Schedule.onDemand.isTrigger)
        let back = try? JSONDecoder().decode(TaughtRecipe.Schedule.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}
