import SwiftUI

/// First-time tips: one per screen, keyed, completes only when the user does the action.
/// Views register targets with `.walkthroughTarget("key")`; the overlay spotlights the target
/// and anchors the popover to it. Storage is in the app store; Replay lives in About.
struct WalkthroughTargetKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) { value.merge(nextValue()) { $1 } }
}

extension View {
    func walkthroughTarget(_ key: String?) -> some View {
        anchorPreference(key: WalkthroughTargetKey.self, value: .bounds) { a in key.map { [$0: a] } ?? [:] }
    }
}

struct Tip { let title: String; let body: String; let action: String }

let walkthroughTips: [String: Tip] = [
    "foryou": Tip(title: "This is your morning.", body: "Everything here was prepared overnight, on this Mac. Nothing has been sent.", action: "Tap the first card to see why it’s here"),
    "card": Tip(title: "Nothing goes out until you tap.", body: "The draft is in your voice and the evidence is on the right. Hands does the steps and stops at Send.", action: "Press the button to watch it go"),
    "knowledge": Tip(title: "These are plain files.", body: "Your knowledge base is Markdown on disk. Fix anything that’s wrong; it only gets better when you do.", action: "Pick a folder on the left"),
    "graph": Tip(title: "People, sized by how much is known.", body: "Click anyone to see what Brownie knows about them.", action: "Click a person"),
    "excluded": Tip(title: "Here’s what it chose not to keep.", body: "The reason is recorded, never the content. Widen the window to see a week.", action: "Switch to 7 days"),
    "sources": Tip(title: "You decide what it reads.", body: "Turn a source off and its notes stay; nothing new is read. Chats are off until you pick them one by one.", action: "Flip any switch"),
    "loops": Tip(title: "Promises, both ways.", body: "What you said you’d do and what others said they’d do for you, from your chats. A loop closes by itself when the next read sees it done.", action: "Press Nudge on any loop"),
    "recipes": Tip(title: "Teach it once.", body: "Do something the way you always do, and Hands turns it into a recipe it can repeat — on a schedule, or when you ask.", action: "Press “Teach Hands something”"),
    "sendlog": Tip(title: "Nothing is hidden about what goes out.", body: "Every request to the brain is here, byte for byte. Open one and read exactly what was sent.", action: "Open any row"),
]
let walkthroughOrder = ["foryou", "card", "knowledge", "graph", "excluded", "sources", "loops", "recipes", "sendlog"]

struct Walkthrough: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t

    var activeKey: String? {
        let k: String?
        switch m.overlay {
        case .card: k = "card"
        case .none:
            switch m.screen {
            case .forYou: k = m.cards.isEmpty ? nil : "foryou"; case .notes: k = m.folders.isEmpty ? nil : "knowledge"; case .graph: k = "graph"; case .excluded: k = "excluded"; case .settings: k = "sources"
            case .loops: k = m.loops.contains { $0.status == .open } ? "loops" : nil; case .recipes: k = "recipes"; case .sendLog: k = m.sendLog.isEmpty ? nil : "sendlog"; case .ask: k = nil
            }
        default: k = nil
        }
        guard let k, !m.walkthroughDone.contains(k), m.onboardingDone else { return nil }
        return k
    }

    var body: some View {
        GeometryReader { geo in
            Color.clear.overlayPreferenceValue(WalkthroughTargetKey.self) { anchors in
                if let key = activeKey, let tip = walkthroughTips[key], let a = anchors[key] {
                    let r = geo[a]
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.38).allowsHitTesting(false)
                            .mask(Rectangle().overlay(RoundedRectangle(cornerRadius: 10).frame(width: r.width + 8, height: r.height + 8).position(x: r.midX, y: r.midY).blendMode(.destinationOut)))
                        RoundedRectangle(cornerRadius: 10).stroke(t.accent, lineWidth: 3).frame(width: r.width + 8, height: r.height + 8).position(x: r.midX, y: r.midY).allowsHitTesting(false)
                        popover(tip, n: (walkthroughOrder.firstIndex(of: key) ?? 0) + 1, key: key)
                            .frame(width: 300)
                            .offset(x: min(max(8, r.minX), geo.size.width - 316), y: r.maxY + 14 > geo.size.height - 180 ? max(8, r.minY - 190) : r.maxY + 14)
                    }
                } else { EmptyView() }
            }
        }
    }

    func popover(_ tip: Tip, n: Int, key: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("First time here · \(n) of \(walkthroughOrder.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(t.accentInk).textCase(.uppercase)
            Text(tip.title).font(.system(size: 14, weight: .semibold))
            Text(tip.body).font(.system(size: 12.5)).foregroundStyle(t.ink2)
            HStack(spacing: 6) { Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(t.accentInk); Text(tip.action).font(.system(size: 12.5, weight: .medium)) }
            HStack { Text("Shown once. Done when you do it.").font(.system(size: 11)).foregroundStyle(t.ink2); Spacer(); Button("Skip") { m.markWalkthrough(key) }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(t.ink2) }.padding(.top, 4)
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
        .background(RoundedRectangle(cornerRadius: 10).fill(t.card)).overlay(RoundedRectangle(cornerRadius: 10).stroke(t.cardBorder))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 14)
    }
}
