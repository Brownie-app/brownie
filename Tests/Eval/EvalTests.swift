import Testing
import Foundation
import Domain
import Inference
import Ingest
import Privacy

/// Scores the reader's prompts against a labelled corpus. Skips when the model isn't downloaded
/// (CI); run locally with `swift test --filter EvalTests` after the first launch.
@Suite struct EvalTests {
    struct Case: Decodable { let id: String; let kind: SourceKind; let name: String?; let chat: String?; let isGroup: Bool?; let text: String; let expect: String; let mustOmit: [String]?; let mustContain: [String]?; let mustNotSay: [String]? }

    @Test func testReaderCorpus() async throws {
        guard let path = ModelCatalog.locate(ModelCatalog.gemma4E4B) else { print("eval skipped: reader model not downloaded"); return }
        let url = Bundle.module.url(forResource: "corpus", withExtension: "json", subdirectory: "Corpus") ?? Bundle.module.url(forResource: "corpus", withExtension: "json")!
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        let reader = Reader(modelPath: path, jsonSchema: Triage.jsonSchema)
        try await reader.load()
        let triage = try Triage(), policy = DefaultSensitivityPolicy()
        var verdictHits = 0, ruleFails: [String] = []
        for c in cases {
            let cand = Candidate(source: "eval", bucket: BucketID("eval"), key: ItemKey(order: 1, tiebreak: c.id), kind: c.kind, id: c.id, itemDate: nil,
                                 metadata: ["name": c.name ?? c.chat ?? c.id, "displayPath": c.name ?? c.chat ?? c.id, "isGroup": (c.isGroup ?? false) ? "1" : "0", "chat": c.chat ?? ""])
            let a = Artifact(candidate: cand, text: c.text)
            let r = try await reader.generate(GenerateRequest(prompt: triage.prompt(for: a, now: Date())))
            let outcome = Triage.parse(r.text).map(policy.admit) ?? Outcome(reason: .parseFailed)
            let got: String = { switch outcome.verdict { case .keep: return "keep"; case .drop: return "drop"; case .sensitive: return "sensitive" } }()
            if got == c.expect { verdictHits += 1 } else { ruleFails.append("\(c.id): expected \(c.expect), got \(got) (\(outcome.reason))") }
            let summary = (outcome.survivor?.summary ?? "") + " " + (outcome.survivor?.title ?? "")
            for s in c.mustOmit ?? [] where summary.contains(s) { ruleFails.append("\(c.id): summary leaked '\(s)'") }
            for s in c.mustContain ?? [] where got == "keep" && !summary.localizedCaseInsensitiveContains(s) { ruleFails.append("\(c.id): summary missing '\(s)'") }
            for s in c.mustNotSay ?? [] where summary.contains(s) { ruleFails.append("\(c.id): summary says '\(s)'") }
            print("[eval] \(c.id): \(got) — \(outcome.survivor?.summary ?? "(nothing kept)")")
        }
        await reader.unload()
        let accuracy = Double(verdictHits) / Double(cases.count)
        print("[eval] verdict accuracy \(verdictHits)/\(cases.count) = \(Int(accuracy * 100))%; rule failures: \(ruleFails.count)")
        for f in ruleFails { print("[eval]   - \(f)") }
        #expect(accuracy >= 0.8, "reader verdict accuracy below 80%")
        #expect(ruleFails.filter { $0.contains("leaked") }.isEmpty, "a summary leaked a private specific: \(ruleFails)")
    }
}
