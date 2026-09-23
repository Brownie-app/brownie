import Foundation
import Domain
import Platform
import Privacy
import LocalSources
import Inference
import Ingest
import Support

// browniectl — the same pipeline from Terminal, for scripted runs and evals.
//   browniectl list files ~/Documents        list eligible items
//   browniectl read files ~/Documents        read a folder with the reader and print verdicts
//   browniectl notes                          list Apple Notes candidates
let args = CommandLine.arguments.dropFirst()
guard let cmd = args.first else { print("usage: browniectl list|read files <root> | notes"); exit(1) }

func run() async {
    switch cmd {
    case "list", "read":
        let root = args.dropFirst(2).first.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? FilesSource.defaultRoots[0]
        let src = FilesSource(roots: [root])
        let buckets = (try? await src.buckets(since: [:], enabled: nil)) ?? []
        let items = buckets.flatMap(\.items)
        print("\(items.count) eligible items in \(root.path)")
        guard cmd == "read" else { for c in items.prefix(50) { print(" ", c.metadata["displayPath"] ?? c.id) }; return }
        guard let mp = ModelCatalog.locate(ModelCatalog.gemma4E4B) else { print("model missing: download it in the app first"); return }
        let store = try! SQLiteRunStore.inMemory()
        let reader = Reader(modelPath: mp, jsonSchema: Triage.jsonSchema)
        try! await reader.load()
        let ingest = IngestRun(store: store, reader: reader, triage: try! Triage(), policy: DefaultSensitivityPolicy())
        let id = try! await store.beginRun(trigger: .test, at: Date())
        let stats = try! await ingest.read(src, enabledBuckets: nil, runID: id) { p in
            if let t = p.lastTitle { print("[\(p.itemIndex)/\(p.itemCount)] \(t)\n    \(p.lastSummary ?? "(dropped)")") }
        }
        print(stats)
    case "notes":
        let n = NotesSource(); print(await n.availability())
        let b = (try? await n.buckets(since: [:], enabled: nil)) ?? []
        for c in b.flatMap(\.items).prefix(30) { print(" ", c.metadata["displayPath"] ?? c.id) }
    default: print("unknown command")
    }
}
await run()
