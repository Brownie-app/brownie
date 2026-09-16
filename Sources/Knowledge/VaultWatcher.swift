import Foundation
import CoreServices
import Support

/// Watches the vault for a note changed on disk by someone other than this screen — Obsidian, the phone coming
/// back through iCloud, the household — so the Notes screen reloads instead of showing last night's text until
/// the next run. FSEvents over the root (the folders below it included); the events of one save are coalesced
/// and hidden folders (`.sync/`, `.brownie/`) never count.
public final class VaultWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "brownie.vault-watch")
    private var pending: DispatchWorkItem?
    private var onChange: (@Sendable ([String]) -> Void)?
    private var root = ""
    private var settle: TimeInterval = 0.5
    private let log = Log("vault-watch")

    public init() {}

    /// Whether a changed path is a note the screen shows: Markdown, under the root, not under a hidden folder.
    /// FSEvents names `/private/var/…` where Foundation says `/var/…`; both spellings are the same place here.
    public static func matters(_ path: String, root: String) -> Bool {
        let p = canonical(path), r = canonical(root)
        guard p.hasSuffix(".md"), p.hasPrefix(r + "/") else { return false }
        let rel = String(p.dropFirst(r.count))
        return !rel.contains("/.")
    }
    static func canonical(_ p: String) -> String { p.hasPrefix("/private/") ? String(p.dropFirst("/private".count)) : p }

    /// Starts watching; `onChange` is called once per burst of changes with the notes' paths, on a background queue.
    public func start(_ folder: URL, settle: TimeInterval = 0.5, onChange: @escaping @Sendable ([String]) -> Void) {
        stop()
        self.onChange = onChange; self.settle = settle
        root = folder.resolvingSymlinksInPath().standardizedFileURL.path
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<VaultWatcher>.fromOpaque(info).takeUnretainedValue()
            let base = paths.assumingMemoryBound(to: UnsafeMutablePointer<CChar>.self)
            me.changed((0..<count).map { String(cString: base[$0]) })
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else { log.warn("can't watch \(root)"); return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
        log.info("watching \(root)")
    }

    private var burst: Set<String> = []
    private func changed(_ paths: [String]) {
        let notes = paths.filter { Self.matters($0, root: root) }
        guard !notes.isEmpty else { return }
        // Obsidian saves in two or three events and iCloud lands a file in several; one reload covers the burst.
        burst.formUnion(notes)
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let changed = self.burst.sorted(); self.burst = []
            self.log.info("\(changed.count) note(s) changed on disk")
            self.onChange?(changed)
        }
        pending = work
        queue.asyncAfter(deadline: .now() + settle, execute: work)
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        stream = nil; pending?.cancel(); pending = nil
    }
    deinit { stop() }
}
