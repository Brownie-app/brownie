import Testing
import Foundation
@testable import Proactive
import Domain

/// The card's source is where the person wrote, as a fact from the summaries — not the brain's wording.
@Suite struct GroundSourcesTests {
    let now = Date(timeIntervalSince1970: 1_758_000_000)
    var summaries: [SummaryRecord] {
        [SummaryRecord(id: 1, runID: 1, source: "whatsapp", bucket: BucketID("whatsapp:507"), bucketName: "Nitesh", kind: .directMessage, title: "t", text: "Nitesh asked for estimates to be posted in the Slack channel", itemDate: now, createdAt: now),
         SummaryRecord(id: 2, runID: 1, source: "gmail", bucket: BucketID("gmail"), bucketName: "Inbox", kind: .mail, title: "t", text: "x", itemDate: now, createdAt: now)]
    }
    func card(label: String, evidence: [Evidence], loop: String? = nil, title: String = "Send Nitesh the estimates") -> Card {
        Card(id: "1", title: title, sourceLabel: label, why: "", actionLabel: "", dueLine: "", urgency: .medium, draftLabel: "", draft: "", recipe: .whatsapp(chat: "Nitesh", body: ""), evidence: evidence, verification: .verified, verifiedLine: "", createdAt: now, loopID: loop)
    }

    @Test func theLabelComesFromTheSummaryTheCandidateUsedNotTheBrainsWord() {
        let cand = ActionItem(title: "Send Nitesh the estimates", action: "", importance: "", dueDate: nil, sources: ["#1"], urgency: .medium)
        let c = Preparer.groundSources(card(label: "Slack · Nitesh", evidence: [Evidence(source: "Summary #1", when: "16 Sep 2026", text: "asked in Slack")]), candidates: [cand], summaries: summaries)
        #expect(c.sourceLabel == "WhatsApp · Nitesh")
        #expect(c.evidence[0].source == "WhatsApp · Nitesh", "the evidence viewer can now open the chat")
    }

    @Test func summaryReferencesInAnyStyleResolve() {
        for ref in ["Summary #2", "#2 · Gmail Inbox", "summary 2", "2"] {
            let c = Preparer.groundSources(card(label: "Mail", evidence: [Evidence(source: ref, when: "", text: "")]), candidates: [], summaries: summaries)
            #expect(c.sourceLabel == "Gmail · Inbox", Comment(rawValue: ref))
        }
    }

    @Test func nonSummaryEvidenceAndUnknownNumbersAreLeftAlone() {
        let c = Preparer.groundSources(card(label: "Loops", evidence: [Evidence(source: "People/Nitesh.md", when: "", text: ""), Evidence(source: "Summary #9", when: "", text: "")]), candidates: [], summaries: summaries)
        #expect(c.evidence.map(\.source) == ["People/Nitesh.md", "Summary #9"] && c.sourceLabel == "Loops")
    }

    @Test func appNames() {
        #expect(Preparer.appName("imessage") == "Messages" && Preparer.appName("mcp:linear") == "Linear" && Preparer.appName("voicememos") == "Voice Memo")
    }
}
