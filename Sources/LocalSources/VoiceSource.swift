import Foundation
import AVFoundation
import Speech
import Domain
import Platform
import Support

// MARK: - Transcript

/// What a recording said, line by line, with the second each line started. Rendered as `[mm:ss] text`
/// so the reader — and later a card — can point at the moment a promise was made.
public struct Transcript: Codable, Sendable, Equatable {
    public struct Line: Codable, Sendable, Equatable {
        public let start: TimeInterval
        public let end: TimeInterval
        public let text: String
        public init(start: TimeInterval, end: TimeInterval, text: String) { self.start = start; self.end = end; self.text = text }
    }
    public var lines: [Line]
    public var duration: TimeInterval
    public init(lines: [Line], duration: TimeInterval) { self.lines = lines; self.duration = duration }

    public var isEmpty: Bool { lines.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty } }
    public var text: String { lines.map { "[\(Self.stamp($0.start))] \($0.text)" }.joined(separator: "\n") }

    /// Lines from a chunk that started `offset` seconds into the recording, shifted into place.
    public func shifted(by offset: TimeInterval) -> Transcript {
        Transcript(lines: lines.map { Line(start: $0.start + offset, end: $0.end + offset, text: $0.text) }, duration: duration)
    }
    public static func + (a: Transcript, b: Transcript) -> Transcript { Transcript(lines: a.lines + b.lines, duration: max(a.duration, b.duration)) }

    public static func stamp(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Words with times → lines. A new line starts after a pause of `pause` seconds or a sentence end.
    public static func lines(from words: [(text: String, start: TimeInterval, duration: TimeInterval)], pause: TimeInterval = 0.7) -> [Line] {
        var out: [Line] = []
        var cur: [String] = [], start = 0.0, end = 0.0
        func flush() { if !cur.isEmpty { out.append(Line(start: start, end: end, text: cur.joined(separator: " "))) }; cur = [] }
        for w in words {
            let t = w.text.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { continue }
            if !cur.isEmpty, w.start - end > pause { flush() }
            if cur.isEmpty { start = w.start }
            cur.append(t); end = w.start + w.duration
            if t.hasSuffix(".") || t.hasSuffix("?") || t.hasSuffix("!") { flush() }
        }
        flush()
        return out
    }
}

/// Turns audio into a transcript. The real one is Apple's on-device speech engine; tests plug in their own.
public protocol Transcriber: Sendable {
    func transcribe(_ url: URL) async throws -> Transcript
}

public enum VoiceError: Error, Equatable { case speechNotAllowed, noRecogniser, unreadable(String) }

// MARK: - Listing recordings

/// A folder of recordings, newest first. Only audio and screen/meeting recordings; nothing hidden, nothing still being written.
public enum AudioFolder {
    public static let extensions: Set<String> = ["m4a", "mp3", "wav", "aiff", "aif", "caf", "flac", "mp4", "mov", "m4v", "webm", "ogg", "opus"]
    public struct Entry: Sendable, Equatable { public let url: URL; public let created: Date; public let size: Int }

    public static func recordings(in folder: URL, settled: TimeInterval = 30, now: Date = Date()) -> [Entry] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [Entry] = []
        for case let u as URL in e {
            guard extensions.contains(u.pathExtension.lowercased()) else { continue }
            guard let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey]), v.isRegularFile == true else { continue }
            let modified = v.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) < settled { continue }   // a recording still being written
            out.append(Entry(url: u, created: v.creationDate ?? modified, size: v.fileSize ?? 0))
        }
        return out.sorted { $0.created != $1.created ? $0.created > $1.created : $0.url.path > $1.url.path }
    }

    public static func duration(of url: URL) async -> TimeInterval {
        (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
    }
}

/// The Settings line under the two rows: "14 recordings · 2 h 10 min of audio · about 13 min to transcribe".
public enum VoiceCost {
    /// Apple's engine runs about ten times faster than real time on an Apple-silicon GPU.
    public static let speedup = 10.0
    public static func line(count: Int, seconds: TimeInterval) -> String {
        guard count > 0 else { return "Nothing to read yet" }
        let mins = Int((seconds / 60).rounded())
        let audio = mins >= 60 ? "\(mins / 60) h \(mins % 60) min" : "\(mins) min"
        let work = max(1, Int((seconds / 60 / speedup).rounded()))
        return "\(count) recording\(count == 1 ? "" : "s") · \(audio) of audio · about \(work) min to transcribe"
    }
}

// MARK: - The two sources

/// What Voice Memos and Meeting audio share: list a folder, transcribe once, keep the text.
struct AudioSourceCore: Sendable {
    let source: SourceID
    let bucket: BucketID
    let name: String
    let folder: URL
    let transcriber: any Transcriber
    let cache: URL
    private let log: Log

    init(source: SourceID, bucket: BucketID, name: String, folder: URL, transcriber: any Transcriber, cache: URL) {
        self.source = source; self.bucket = bucket; self.name = name; self.folder = folder; self.transcriber = transcriber; self.cache = cache
        log = Log("source.\(source.rawValue)")
    }

    func candidates() -> [Candidate] {
        AudioFolder.recordings(in: folder).map { f in
            Candidate(source: source, bucket: bucket, key: ItemKey(order: f.created.timeIntervalSince1970, tiebreak: f.url.path), kind: .transcript, id: f.url.path, itemDate: f.created,
                      metadata: ["displayPath": "\(name)/\(f.url.deletingPathExtension().lastPathComponent)", "name": f.url.lastPathComponent,
                                 "created": ISO8601DateFormatter().string(from: f.created), "bytes": String(f.size)])
        }
    }

    func buckets() -> [Bucket] { let items = candidates(); log.info("\(items.count) recordings listed in \(folder.lastPathComponent)"); return [Bucket(id: bucket, name: name, items: items)] }

    /// A recording is transcribed once; the text is kept next to a fingerprint of the file (path, size, modified).
    func load(_ c: Candidate) async throws -> Artifact {
        let url = URL(fileURLWithPath: c.id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw SourceError.itemGone }
        let t = try await transcript(for: url)
        let meta = ["duration": Transcript.stamp(t.duration), "lines": String(t.lines.count)]
        return Artifact(candidate: c, text: t.isEmpty ? nil : t.text, metadata: meta)
    }

    func transcript(for url: URL) async throws -> Transcript {
        let key = Self.cacheKey(url)
        let file = cache.appendingPathComponent(key + ".json")
        if let d = try? Data(contentsOf: file), let t = try? JSONDecoder().decode(Transcript.self, from: d) { return t }
        let started = Date()
        let t = try await transcriber.transcribe(url)
        log.info("transcribed \(url.lastPathComponent): \(Transcript.stamp(t.duration)) of audio in \(Int(Date().timeIntervalSince(started))) s, \(t.lines.count) lines")
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try? JSONEncoder().encode(t).write(to: file, options: .atomic)
        return t
    }

    static func cacheKey(_ url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let raw = "\(url.standardizedFileURL.path)|\(v?.fileSize ?? 0)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        return String(raw.utf8.reduce(into: UInt64(1469598103934665603)) { $0 = ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 16)
    }
}

/// Apple Voice Memos: the recordings folder in its group container (needs Full Disk Access) and the speech engine.
public struct VoiceMemosSource: Source {
    public static let descriptor = SourceDescriptor(
        id: "voicememos", name: "Voice Memos", detail: "Transcribed on this Mac with Apple's speech engine · audio never leaves",
        door: .localDatabase, permissions: [.fullDiskAccess, .speech])
    public static var folder: URL { Paths.home.appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings", isDirectory: true) }
    let core: AudioSourceCore

    public init(folder: URL? = nil, transcriber: any Transcriber = SpeechTranscriber(), cache: URL? = nil) {
        core = AudioSourceCore(source: Self.descriptor.id, bucket: BucketID("voicememos"), name: "Voice Memos", folder: folder ?? Self.folder, transcriber: transcriber, cache: cache ?? Paths.transcripts)
    }
    public func availability() async -> Availability {
        guard FileManager.default.fileExists(atPath: core.folder.path) else { return .notInstalled }
        guard (try? FileManager.default.contentsOfDirectory(atPath: core.folder.path)) != nil else { return .needsPermission(.fullDiskAccess) }
        return SpeechTranscriber.availability()
    }
    public func buckets(since marks: [BucketID: ItemKey], enabled: Set<BucketID>?) async throws -> [Bucket] { core.buckets() }
    public func load(_ c: Candidate) async throws -> Artifact { try await core.load(c) }
}

/// A folder of recordings the user keeps — Zoom, QuickTime, the phone. Default `~/Recordings`.
public struct RecordingsSource: Source {
    public static let descriptor = SourceDescriptor(
        id: "recordings", name: "Meeting audio", detail: "A folder of recordings (Zoom, QuickTime, your phone) · the moment a promise was made becomes its evidence",
        door: .localDatabase, permissions: [.speech])
    public static var defaultFolder: URL { Paths.home.appendingPathComponent("Recordings", isDirectory: true) }
    let core: AudioSourceCore
    public var folder: URL { core.folder }

    public init(folder: URL? = nil, transcriber: any Transcriber = SpeechTranscriber(), cache: URL? = nil) {
        core = AudioSourceCore(source: Self.descriptor.id, bucket: BucketID("recordings"), name: "Recordings", folder: folder ?? Self.defaultFolder, transcriber: transcriber, cache: cache ?? Paths.transcripts)
    }
    public func availability() async -> Availability {
        guard (try? FileManager.default.contentsOfDirectory(atPath: core.folder.path)) != nil else { return .unavailable("No folder at \(core.folder.path.replacingOccurrences(of: Paths.home.path, with: "~")) — choose one") }
        return SpeechTranscriber.availability()
    }
    public func buckets(since marks: [BucketID: ItemKey], enabled: Set<BucketID>?) async throws -> [Bucket] { core.buckets() }
    public func load(_ c: Candidate) async throws -> Artifact { try await core.load(c) }
}

// MARK: - Apple's speech engine

/// On-device only (`requiresOnDeviceRecognition`), so nothing is sent to Apple. Long recordings are cut into
/// one-minute pieces, transcribed in turn and stitched back with their offsets.
public struct SpeechTranscriber: Transcriber {
    public let locale: Locale
    public let chunk: TimeInterval
    public init(locale: Locale = .current, chunk: TimeInterval = 55) { self.locale = locale; self.chunk = chunk }

    public static func availability() -> Availability {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return SFSpeechRecognizer(locale: .current)?.supportsOnDeviceRecognition == true ? .available : .unavailable("On-device speech isn't available for \(Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? "this language") — System Settings → Keyboard → Dictation")
        case .notDetermined: return .needsPermission(.speech)
        default: return .needsPermission(.speech)
        }
    }
    public static var isAuthorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }
    public static func requestAccess() async -> Bool {
        await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
    }

    public func transcribe(_ url: URL) async throws -> Transcript {
        guard Self.isAuthorized else { throw VoiceError.speechNotAllowed }
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else { throw VoiceError.noRecogniser }
        rec.defaultTaskHint = .dictation
        let asset = AVURLAsset(url: url)
        let total = (try? await asset.load(.duration).seconds) ?? 0
        guard total.isFinite, total > 0 else { throw VoiceError.unreadable(url.lastPathComponent) }
        var out = Transcript(lines: [], duration: total)
        var start = 0.0
        while start < total {
            let len = min(chunk, total - start)
            let piece = try await AudioChunker.export(asset, from: start, length: len)
            defer { try? FileManager.default.removeItem(at: piece) }
            let t = try await Self.recognise(piece, with: rec)
            out = out + t.shifted(by: start)
            start += len
        }
        return out
    }

    static func recognise(_ url: URL, with rec: SFSpeechRecognizer) async throws -> Transcript {
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        return try await withCheckedThrowingContinuation { c in
            var done = false
            rec.recognitionTask(with: req) { result, error in
                guard !done else { return }
                if let result, result.isFinal {
                    done = true
                    let words = result.bestTranscription.segments.map { (text: $0.substring, start: $0.timestamp, duration: $0.duration) }
                    c.resume(returning: Transcript(lines: Transcript.lines(from: words), duration: words.last.map { $0.start + $0.duration } ?? 0))
                } else if let error {
                    done = true
                    // "No speech detected" is a silent chunk, not a failure.
                    let ns = error as NSError
                    if ns.domain == "kAFAssistantErrorDomain" && (ns.code == 1110 || ns.code == 216) { c.resume(returning: Transcript(lines: [], duration: 0)) } else { c.resume(throwing: error) }
                }
            }
        }
    }
}

/// Cuts one stretch of an asset into a temporary M4A. Works for audio and for meeting videos alike.
public enum AudioChunker {
    public static func export(_ asset: AVAsset, from start: TimeInterval, length: TimeInterval) async throws -> URL {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw VoiceError.unreadable("no audio export") }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("brownie-chunk-\(UUID().uuidString).m4a")
        session.outputURL = out; session.outputFileType = .m4a
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600))
        await session.export()
        if let e = session.error { throw e }
        return out
    }
}
