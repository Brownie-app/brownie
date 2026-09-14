import Foundation
import AppKit
import PDFKit
import Domain
import Platform
import Support

/// Reads the user's folders. One bucket per root; key = (dateAdded, path).
public struct FilesSource: Source {
    public static let descriptor = SourceDescriptor(
        id: "files", name: "Files", detail: "Documents, Desktop, Downloads · screenshots included",
        door: .localDatabase, permissions: [], supportsPerBucketOptIn: true)

    public let roots: [URL]
    private let log = Log("source.files")

    public init(roots: [URL]) { self.roots = roots }

    public static var defaultRoots: [URL] {
        let h = FileManager.default.homeDirectoryForCurrentUser
        return ["Documents", "Desktop", "Downloads"].map { h.appendingPathComponent($0, isDirectory: true) }
    }

    public func availability() async -> Availability {
        guard !roots.isEmpty else { return .unavailable("No folders chosen") }
        // macOS gates Desktop/Documents/Downloads per app. Touching the folder triggers the consent
        // prompt on first use; a nil listing afterwards means it was declined.
        let readable = roots.filter { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) != nil }
        if readable.isEmpty { return .unavailable("macOS hasn't allowed Brownie into \(roots.map(\.lastPathComponent).joined(separator: ", ")) — System Settings → Privacy & Security → Files and Folders") }
        return .available
    }

    public func discoverBuckets() async throws -> [BucketInfo] {
        roots.map { root in
            let c = Self.counts(root)
            let detail = c.bulk > 0 ? "\(c.eligible) files to read · \(c.bulk) in bulk folders left unread" : "\(c.eligible) files to read"
            return BucketInfo(id: Self.bucketID(root), name: root.lastPathComponent, detail: detail, isGroup: false, count: c.eligible)
        }
    }

    /// Cached per root for 10 minutes — a Desktop walk can take seconds.
    nonisolated(unsafe) static var countCache: [String: (Date, (eligible: Int, bulk: Int))] = [:]
    public static func counts(_ root: URL) -> (eligible: Int, bulk: Int) {
        if let (at, c) = countCache[root.path], Date().timeIntervalSince(at) < 600 { return c }
        let src = FilesSource(roots: [root])
        var bulk = 0
        let eligible = src.eligibleFiles(in: root, bulkOut: &bulk).count
        let c = (eligible, bulk); countCache[root.path] = (Date(), c); return c
    }

    static func bucketID(_ root: URL) -> BucketID { BucketID("files:" + root.standardizedFileURL.path) }

    public func buckets(since marks: [BucketID: ItemKey], enabled: Set<BucketID>?) async throws -> [Bucket] {
        var out: [Bucket] = []
        for root in roots {
            let id = Self.bucketID(root)
            // Roots are chosen explicitly by the user; an empty selection means "all of them".
            if let enabled, !enabled.isEmpty, !enabled.contains(id) { continue }
            let files = eligibleFiles(in: root)
            log.info("\(root.lastPathComponent): \(files.count) eligible files")
            let items = files.map { f in
                Candidate(source: Self.descriptor.id, bucket: id, key: ItemKey(order: f.added.timeIntervalSince1970, tiebreak: f.url.path),
                          kind: .document, id: f.url.path, itemDate: f.added,
                          metadata: ["displayPath": f.url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"),
                                     "name": f.url.lastPathComponent, "created": Self.iso(f.created), "bytes": String(f.size)])
            }.sorted { $0.key > $1.key }   // newest first
            out.append(Bucket(id: id, name: root.lastPathComponent, items: items))
        }
        return out
    }

    public func load(_ c: Candidate) async throws -> Artifact {
        let url = URL(fileURLWithPath: c.id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw SourceError.itemGone }
        let ext = url.pathExtension.lowercased()
        if Self.imageExtensions.contains(ext) {
            return Artifact(candidate: c, text: nil, imageJPEG: Self.downsampledJPEG(url))
        }
        return Artifact(candidate: c, text: Self.extractText(url, ext: ext))
    }

    // MARK: listing

    struct Entry { let url: URL; let added: Date; let created: Date; let size: Int }

    static let skipNames: Set<String> = ["node_modules", ".git", "Library", ".Trash", "DerivedData", ".build", "Pods", "build", "dist", "target", ".gradle", ".cache", ".next", "venv", ".venv", "__pycache__", "vendor", "Vendor", ".swiftpm", "Caches"]
    /// A folder holding any of these is a code project: skipped whole. Code is never vault material.
    static let projectMarkers = [".git", "Package.swift", "package.json", "build.gradle", "build.gradle.kts", "pubspec.yaml", "Cargo.toml", "go.mod", "pyproject.toml", "pom.xml", ".xcodeproj"]
    static let skipExtensions: Set<String> = ["app", "dmg", "pkg", "zip", "tar", "gz", "iso", "exe", "msi", "framework", "xcodeproj", "bundle", "plist", "lock", "ds_store", "swift", "kt", "java", "py", "js", "ts", "tsx", "jsx", "css", "scss", "html", "xml", "sh", "sql", "yaml", "yml", "json", "toml", "log", "map", "o", "a", "dylib", "so", "class", "jar", "sqlite", "db"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "gif", "tiff"]
    static let textExtensions: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "rtf", "tex"]
    static let maxBytes = 25 * 1024 * 1024

    func eligibleFiles(in root: URL) -> [Entry] { var b = 0; return eligibleFiles(in: root, bulkOut: &b) }
    func eligibleFiles(in root: URL, bulkOut: inout Int) -> [Entry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isPackageKey, .isHiddenKey, .addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [Entry] = []
        for case let url as URL in e {
            guard let rv = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if rv.isDirectory == true {
                if Self.skipNames.contains(url.lastPathComponent) || Self.isProject(url) { e.skipDescendants() }
                continue
            }
            if rv.isPackage == true { e.skipDescendants(); continue }
            guard rv.isRegularFile == true else { continue }
            if Self.skipExtensions.contains(url.pathExtension.lowercased()) { continue }
            let size = rv.fileSize ?? 0
            if size > Self.maxBytes || size == 0 { continue }
            let added = rv.addedToDirectoryDate ?? rv.contentModificationDate ?? rv.creationDate ?? Date()
            out.append(Entry(url: url, added: added, created: rv.creationDate ?? added, size: size))
        }
        // A folder with hundreds of files is a dataset or an export, not a life. Keep the newest
        // `perFolderCap` per directory; the rest are bulk and never read.
        var byDir: [URL: [Entry]] = [:]
        for e in out { byDir[e.url.deletingLastPathComponent(), default: []].append(e) }
        var kept: [Entry] = []
        var bulk = 0
        for (_, entries) in byDir {
            if entries.count > Self.perFolderCap {
                kept += entries.sorted { $0.added > $1.added }.prefix(Self.perFolderCap); bulk += entries.count - Self.perFolderCap
            } else { kept += entries }
        }
        if bulk > 0 { log.info("\(root.lastPathComponent): \(bulk) files in bulk folders left unread") }
        bulkOut = bulk
        return kept
    }
    static let perFolderCap = 100

    static func isProject(_ dir: URL) -> Bool {
        let fm = FileManager.default
        for m in projectMarkers where fm.fileExists(atPath: dir.appendingPathComponent(m).path) { return true }
        return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasSuffix(".xcodeproj") }
    }

    // MARK: extraction

    static let maxTextChars = 24_000

    static func extractText(_ url: URL, ext: String) -> String? {
        if textExtensions.contains(ext), let s = try? String(contentsOf: url, encoding: .utf8) { return String(s.prefix(maxTextChars)) }
        if ext == "pdf", let doc = PDFDocument(url: url) {
            var s = ""
            for i in 0..<min(doc.pageCount, 12) { if let p = doc.page(at: i)?.string { s += p + "\n"; if s.count > maxTextChars { break } } }
            return s.isEmpty ? nil : String(s.prefix(maxTextChars))
        }
        let rich: [String: NSAttributedString.DocumentType] = ["docx": .officeOpenXML, "doc": .docFormat, "rtf": .rtf, "rtfd": .rtfd, "html": .html, "odt": .openDocument]
        if let type = rich[ext], let a = try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil) {
            return String(a.string.prefix(maxTextChars))
        }
        return nil   // judged from path + dates
    }

    static func downsampledJPEG(_ url: URL, maxSide: CGFloat = 1024) -> Data? {
        guard let img = NSImage(contentsOf: url), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
        let scale = min(1, maxSide / max(w, h))
        let size = NSSize(width: w * scale, height: h * scale)
        let out = NSImage(size: size)
        out.lockFocus(); rep.draw(in: NSRect(origin: .zero, size: size)); out.unlockFocus()
        guard let t = out.tiffRepresentation, let r = NSBitmapImageRep(data: t) else { return nil }
        return r.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
}
