import Testing
import Foundation
@testable import Ingest
import Domain

@Suite struct TranscriptPromptTests {
    @Test func transcriptsGetTheirOwnPrompt() throws {
        let t = try Triage()
        let c = Candidate(source: "recordings", bucket: BucketID("recordings"), key: ItemKey(order: 1), kind: .transcript, id: "/x/Meera call.m4a", itemDate: Date(),
                          metadata: ["displayPath": "Recordings/Meera call", "created": "2026-09-10T10:00:00Z"])
        let p = t.prompt(for: Artifact(candidate: c, text: "[03:12] I'll send it by Thursday."), now: Date())
        #expect(p.contains("said out loud"), "the reader is told this is speech, not a document")
        #expect(p.contains("Item: Recordings/Meera call"))
        #expect(p.contains("Recorded: 2026-09-10T10:00:00Z"))
        #expect(p.contains("[03:12] I'll send it by Thursday."))
        #expect(p.contains("with the time and the words used"), "promises keep their timestamp so a card can point at the moment")
    }
}
