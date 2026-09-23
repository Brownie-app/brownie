import SwiftUI
import AVFoundation
import Domain
import LocalSources

/// What the evidence sheet is showing: the chat window around the line, or the clip at its moment.
struct EvidenceShown: Equatable {
    enum State: Equatable { case loading, window(EvidenceWindow), clip(name: String, seconds: TimeInterval, url: URL?), missing(String) }
    let ref: EvidenceRef
    let source: String
    let when: String
    let text: String
    var state: State
}

/// The original behind a card's evidence — the messages, read from the app's own database on this Mac, shown and then forgotten.
struct EvidenceSheet: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    let shown: EvidenceShown
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text(shown.source + (shown.when.isEmpty ? "" : " · " + shown.when)).font(.system(size: 11)).foregroundStyle(t.ink2)
                }
                Spacer()
                if case .chat(let app, let name) = shown.ref { BButton(title: "Open in \(appName(app))", kind: .quiet) { m.openChatApp(app, name: name) } }
                BButton(title: "Done", kind: .primary) { m.evidenceShown = nil }
            }.padding(EdgeInsets(top: 16, leading: 18, bottom: 12, trailing: 18))
            Divider()
            switch shown.state {
            case .loading: HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Reading the chat on this Mac…").font(.system(size: 12.5)).foregroundStyle(t.ink2) }.frame(maxWidth: .infinity, minHeight: 200)
            case .missing(let why): VStack(spacing: 8) { Image(systemName: "questionmark.bubble").font(.system(size: 22)).foregroundStyle(t.ink3); Text(why).font(.system(size: 12.5)).foregroundStyle(t.ink2).multilineTextAlignment(.center) }.padding(30).frame(maxWidth: .infinity, minHeight: 200)
            case .window(let w): ChatWindowView(window: w, evidence: shown.text)
            case .clip(let name, let seconds, let url): ClipPlayer(name: name, seconds: seconds, url: url).frame(minHeight: 160)
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(t.ink2)
                Text(footer).font(.system(size: 11)).foregroundStyle(t.ink2)
            }.padding(EdgeInsets(top: 10, leading: 18, bottom: 12, trailing: 18))
        }.frame(width: 640, height: 520)
    }
    var title: String {
        switch shown.ref {
        case .chat(let app, let name): return "\(EvidenceRef.cleanName(name)) · \(appName(app))"
        case .recording(let name, _): return name
        default: return "The original"
        }
    }
    var footer: String {
        if case .recording = shown.ref { return "Played from the file on this Mac. The audio was transcribed here and never copied anywhere." }
        return "Read from the app's own database on this Mac just now. Nothing here is stored by Brownie or sent to the brain."
    }
    func appName(_ app: String) -> String { ["whatsapp": "WhatsApp", "imessage": "Messages", "telegram": "Telegram", "slack": "Slack", "teams": "Teams"][app] ?? app.capitalized }
}

struct ChatWindowView: View {
    @Environment(\.theme) var t
    let window: EvidenceWindow
    let evidence: String
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if window.messages.isEmpty { Text("No messages in this stretch of the chat.").font(.system(size: 12.5)).foregroundStyle(t.ink2).padding(20) }
                    ForEach(Array(window.messages.enumerated()), id: \.offset) { i, msg in
                        let hit = i == window.highlight
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .trailing, spacing: 1) { Text(msg.isMe ? "Me" : msg.sender).font(.system(size: 11, weight: .semibold)).foregroundStyle(msg.isMe ? t.accentInk : t.ink2); Text(time(msg.date)).font(.system(size: 10)).foregroundStyle(t.ink3) }.frame(width: 96, alignment: .trailing)
                            Text(msg.text).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(hit ? t.accentSoft : .clear)).overlay(RoundedRectangle(cornerRadius: 8).stroke(hit ? t.accent : .clear))
                        .id(i)
                    }
                }.padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            }
            .onAppear { if let h = window.highlight { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { withAnimation { proxy.scrollTo(h, anchor: .center) } } } }
        }
        .overlay(alignment: .top) {
            if window.highlight == nil, !window.messages.isEmpty { Text("Brownie couldn't point at one line — here is the stretch of chat the summary came from.").font(.system(size: 11)).foregroundStyle(t.ink2).padding(6).background(t.card).clipShape(Capsule()).padding(.top, 6) }
        }
    }
    func time(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"; return f.string(from: d) }
}

/// The recording at the moment a promise was made: starts a few seconds before, plays on.
struct ClipPlayer: View {
    @Environment(\.theme) var t
    let name: String
    let seconds: TimeInterval
    let url: URL?
    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var position: TimeInterval = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let url {
                HStack(spacing: 12) {
                    Button { toggle() } label: { Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 34)).foregroundStyle(t.accent) }.buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Transcript.stamp(position)) · starts 5 s before \(Transcript.stamp(seconds))").font(.system(size: 12.5, weight: .medium))
                        Text(url.lastPathComponent).font(.system(size: 11)).foregroundStyle(t.ink2)
                    }
                    Spacer()
                    BButton(title: "Back to the moment", kind: .quiet) { seek() }
                    BButton(title: "Show in Finder", kind: .quiet) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            } else {
                Text("The recording “\(name)” isn't in your Voice Memos or Recordings folder any more.").font(.system(size: 12.5)).foregroundStyle(t.ink2)
            }
        }
        .padding(18)
        .onAppear { guard let url else { return }; let p = AVPlayer(url: url); player = p; seek(); p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 10), queue: .main) { t in position = t.seconds } }
        .onDisappear { player?.pause() }
    }
    func seek() { player?.seek(to: CMTime(seconds: max(0, seconds - 5), preferredTimescale: 600)); if !playing { toggle() } }
    func toggle() { guard let player else { return }; if playing { player.pause() } else { player.play() }; playing.toggle() }
}
