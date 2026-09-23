import Testing
import Foundation
import AVFoundation
@testable import LocalSources
import Domain

/// A transcriber that returns what it is told and counts calls — the speech engine stays out of tests.
final class FakeTranscriber: Transcriber, @unchecked Sendable {
    var calls = 0
    var result: Transcript
    init(_ result: Transcript) { self.result = result }
    func transcribe(_ url: URL) async throws -> Transcript { calls += 1; return result }
}

@Suite struct TranscriptTests {
    @Test func rendersTimestampsPerLine() {
        let t = Transcript(lines: [.init(start: 0, end: 2, text: "Hi Meera."), .init(start: 192.4, end: 195, text: "I'll send it by Thursday."), .init(start: 3725, end: 3730, text: "Bye.")], duration: 3730)
        #expect(t.text == "[00:00] Hi Meera.\n[03:12] I'll send it by Thursday.\n[1:02:05] Bye.")
        #expect(!t.isEmpty)
        #expect(Transcript(lines: [.init(start: 0, end: 1, text: "  ")], duration: 1).isEmpty)
    }

    @Test func chunksStitchWithOffsets() {
        let a = Transcript(lines: [.init(start: 1, end: 2, text: "one")], duration: 55)
        let b = Transcript(lines: [.init(start: 3, end: 4, text: "two")], duration: 20).shifted(by: 55)
        let all = a + b
        #expect(all.lines.map(\.start) == [1, 58])
        #expect(all.duration == 55)
        #expect(all.text == "[00:01] one\n[00:58] two")
    }

    @Test func wordsBecomeLinesAtPausesAndSentenceEnds() {
        let words: [(text: String, start: TimeInterval, duration: TimeInterval)] = [
            ("I'll", 0, 0.2), ("send", 0.3, 0.2), ("it", 0.6, 0.1), ("Thursday.", 0.8, 0.4),
            ("Also", 1.4, 0.3), ("the", 1.8, 0.1), ("deck", 2.0, 0.3),
            ("Bye", 4.0, 0.3),   // a 1.7 s pause before this word
        ]
        let lines = Transcript.lines(from: words)
        #expect(lines.map(\.text) == ["I'll send it Thursday.", "Also the deck", "Bye"])
        #expect(lines.map(\.start) == [0, 1.4, 4.0])
        #expect(abs(lines[0].end - 1.2) < 0.001)
    }

    @Test func stamp() {
        #expect(Transcript.stamp(0) == "00:00"); #expect(Transcript.stamp(65.9) == "01:05"); #expect(Transcript.stamp(3600) == "1:00:00"); #expect(Transcript.stamp(-3) == "00:00")
    }
}

@Suite struct AudioFolderTests {
    func folder() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u.appendingPathComponent("sub"), withIntermediateDirectories: true)
        return u
    }
    func touch(_ name: String, in root: URL, created: Date, modified: Date? = nil) throws {
        let u = root.appendingPathComponent(name)
        try Data([0, 1, 2]).write(to: u)
        try FileManager.default.setAttributes([.creationDate: created, .modificationDate: modified ?? created], ofItemAtPath: u.path)
    }

    @Test func listsAudioNewestFirstAndSkipsTheRest() throws {
        let root = try folder()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try touch("standup.m4a", in: root, created: old)
        try touch("zoom call.mp4", in: root, created: old.addingTimeInterval(60))
        try touch("sub/phone.wav", in: root, created: old.addingTimeInterval(120))
        try touch("notes.txt", in: root, created: old)
        try touch(".hidden.m4a", in: root, created: old)
        try touch("still-recording.m4a", in: root, created: Date(), modified: Date())
        let r = AudioFolder.recordings(in: root)
        #expect(r.map { $0.url.lastPathComponent } == ["phone.wav", "zoom call.mp4", "standup.m4a"])
        #expect(r.first?.size == 3)
    }

    @Test func missingFolderIsEmpty() {
        #expect(AudioFolder.recordings(in: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")).isEmpty)
    }

    @Test func costLine() {
        #expect(VoiceCost.line(count: 0, seconds: 0) == "Nothing to read yet")
        #expect(VoiceCost.line(count: 1, seconds: 90) == "1 recording · 2 min of audio · about 1 min to transcribe")
        #expect(VoiceCost.line(count: 14, seconds: 7800) == "14 recordings · 2 h 10 min of audio · about 13 min to transcribe")
    }
}

@Suite struct VoiceSourceTests {
    func setup() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let u = root.appendingPathComponent("Meera call.m4a"); try Data([1]).write(to: u)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_700_000_000), .modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: u.path)
        return (root, cache)
    }
    let said = Transcript(lines: [.init(start: 192, end: 195, text: "I'll send it by Thursday.")], duration: 600)

    /// The fixture recording is from 2023; a first read only looks back the policy's window, so these tests widen it.
    var everything: FirstRead { var p = FirstRead(); p.voiceDays = 10_000; return p }

    @Test func aFirstReadListsOnlyRecentRecordingsUntilTheFolderHasBeenReadOnce() async throws {
        let (root, cache) = try setup()
        let s = RecordingsSource(folder: root, transcriber: FakeTranscriber(said), cache: cache)
        #expect(try await s.buckets(since: [:], enabled: nil)[0].items.isEmpty, "a 2023 recording is outside the 90-day first read")
        let read = try await s.buckets(since: [BucketID("recordings"): ItemKey(order: 1_600_000_000)], enabled: nil)
        #expect(read[0].items.count == 1, "once the folder has a mark, everything is listed and the core keeps what is newer")
    }

    @Test func candidatesAreTranscriptsWithDisplayPaths() async throws {
        let (root, cache) = try setup()
        let s = RecordingsSource(folder: root, transcriber: FakeTranscriber(said), cache: cache, policy: { everything })
        let b = try await s.buckets(since: [:], enabled: nil)
        #expect(b.count == 1 && b[0].id == BucketID("recordings"))
        let c = try #require(b[0].items.first)
        #expect(c.kind == .transcript)
        #expect(c.metadata["displayPath"] == "Recordings/Meera call")
        #expect(c.itemDate == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(c.key.order == 1_700_000_000)
    }

    @Test func loadTranscribesOnceThenReadsTheCache() async throws {
        let (root, cache) = try setup()
        let fake = FakeTranscriber(said)
        let s = RecordingsSource(folder: root, transcriber: fake, cache: cache, policy: { everything })
        let c = try await s.buckets(since: [:], enabled: nil)[0].items[0]
        let a = try await s.load(c)
        #expect(a.text == "[03:12] I'll send it by Thursday.")
        #expect(a.metadata["duration"] == "10:00" && a.metadata["lines"] == "1")
        #expect(a.kind == .transcript)
        _ = try await s.load(c)
        #expect(fake.calls == 1, "the cache answers the second time")
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).count == 1)
        // a changed file is transcribed again
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: c.id))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_500)], ofItemAtPath: c.id)
        _ = try await s.load(c)
        #expect(fake.calls == 2)
    }

    @Test func silentRecordingHasNoText() async throws {
        let (root, cache) = try setup()
        let s = RecordingsSource(folder: root, transcriber: FakeTranscriber(Transcript(lines: [], duration: 30)), cache: cache, policy: { everything })
        let c = try await s.buckets(since: [:], enabled: nil)[0].items[0]
        #expect(try await s.load(c).text == nil)
    }

    @Test func goneFileThrows() async throws {
        let (root, cache) = try setup()
        let s = RecordingsSource(folder: root, transcriber: FakeTranscriber(said), cache: cache, policy: { everything })
        let c = try await s.buckets(since: [:], enabled: nil)[0].items[0]
        try FileManager.default.removeItem(atPath: c.id)
        await #expect(throws: SourceError.itemGone) { try await s.load(c) }
    }

    @Test func availabilityNeedsAFolderThenSpeech() async throws {
        let (root, cache) = try setup()
        let missing = RecordingsSource(folder: root.appendingPathComponent("nope"), transcriber: FakeTranscriber(said), cache: cache)
        if case .unavailable(let why) = await missing.availability() { #expect(why.contains("choose one")) } else { Issue.record("a missing folder must be reported") }
        let memos = VoiceMemosSource(folder: root.appendingPathComponent("nope"), transcriber: FakeTranscriber(said), cache: cache)
        #expect(await memos.availability() == .notInstalled)
    }

    /// Real audio through the real chunker: 130 s of silence → three pieces at 0, 55 and 110 s.
    @Test func chunkerCutsAtTheRightOffsets() async throws {
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("silence-\(UUID().uuidString).wav")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        // written and released before it is read back — AVAudioFile finishes the header when it goes away
        func writeSilence() throws {
            let f = try AVAudioFile(forWriting: wav, settings: fmt.settings)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 16_000 * 130)!; buf.frameLength = buf.frameCapacity
            try f.write(from: buf)
        }
        try writeSilence()
        let asset = AVURLAsset(url: wav)
        let total = try await asset.load(.duration).seconds
        #expect(abs(total - 130) < 0.01)
        var starts: [Double] = [], lengths: [Double] = []
        var start = 0.0
        while start < total { let len = min(55, total - start); starts.append(start); lengths.append(len); start += len }
        #expect(starts == [0, 55, 110] && lengths == [55, 55, 20])
        let piece = try await AudioChunker.export(asset, from: 110, length: 20)
        defer { try? FileManager.default.removeItem(at: piece) }
        let d = try await AVURLAsset(url: piece).load(.duration).seconds
        #expect(abs(d - 20) < 0.2)
    }
}
