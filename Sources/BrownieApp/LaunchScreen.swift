import SwiftUI

/// The screen Brownie opens on, held for `LaunchScreen.hold` seconds before the app appears underneath it.
///
/// It covers the window rather than replacing it: `RootView`/`OnboardingView` render behind, and the async
/// bootstrap — store, settings, permissions, source discovery — runs the whole time. So the hold is a held
/// screen, not a delay; by the time it lifts, most of the work that used to happen in front of the user is done.
struct LaunchScreen: View {
    @Environment(\.theme) var t

    /// How long it stays. One number, named, because it is the whole behaviour.
    static let hold: Duration = .seconds(5)

    /// Drawn in, not snapped in: the mark settles while the window is still arriving.
    @State private var arrived = false

    var body: some View {
        ZStack {
            t.content.ignoresSafeArea()
            VStack(spacing: 18) {
                DawnMark(size: 96)
                    .scaleEffect(arrived ? 1 : 0.94)
                    .opacity(arrived ? 1 : 0)
                VStack(spacing: 7) {
                    HStack(spacing: 0) {
                        Text("brownie").font(.system(size: 30, weight: .bold)).tracking(-0.8)
                        Circle().fill(t.accent).frame(width: 8, height: 8).offset(x: 2, y: -12)
                    }
                    Text("A house spirit that lives in your Mac.")
                        .font(.system(size: 13))
                        .foregroundStyle(t.ink2)
                }
                .opacity(arrived ? 1 : 0)
            }
            .offset(y: -12)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.5)) { arrived = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Brownie is starting")
    }
}
