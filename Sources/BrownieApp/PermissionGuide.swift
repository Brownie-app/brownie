import SwiftUI
import AppKit
import Domain
import Platform

/// A small floating panel that follows the user into System Settings: it names the pane, shows the
/// Brownie icon to drag into the list, and re-checks the grant every second so it can close itself.
@MainActor
final class PermissionGuide {
    static let shared = PermissionGuide()
    private var panel: NSPanel?
    private var timer: Timer?

    func show(for permission: Permission, then done: @escaping () -> Void) {
        PermissionProbe.openSettings(for: permission)
        let view = GuideView(permission: permission) { [weak self] in self?.close(); done() }
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 210), styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            p.isFloatingPanel = true; p.level = .floating; p.titleVisibility = .hidden; p.titlebarAppearsTransparent = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; p.isMovableByWindowBackground = true
            panel = p
        }
        panel?.contentView = NSHostingView(rootView: view)
        if let screen = NSScreen.main { panel?.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 380, y: screen.visibleFrame.maxY - 240)) }
        panel?.orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            if PermissionProbe.status(permission) { Task { @MainActor in self?.close(); done() } }
        }
    }

    func close() { timer?.invalidate(); timer = nil; panel?.orderOut(nil) }
}

struct GuideView: View {
    let permission: Permission
    let skip: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                    .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text("Drag this icon into the list on the right, then flip the switch on.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Text(why).font(.system(size: 12)).foregroundStyle(.secondary)
            Text("If you can't drag: press +, then ⌘⇧G and paste\n\(Bundle.main.bundleURL.path)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            HStack { Text("This closes by itself once it's granted.").font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Button("Skip for now", action: skip).font(.system(size: 12)) }
        }.padding(16).frame(width: 360)
    }
    var title: String { switch permission { case .fullDiskAccess: return "Full Disk Access"; case .accessibility: return "Accessibility"; case .screenRecording: return "Screen Recording"; default: return permission.rawValue } }
    var why: String { switch permission { case .fullDiskAccess: return "To read Messages, WhatsApp and Notes on this Mac. Nothing leaves it."; case .accessibility: return "So Hands can click and type in your apps when you ask it to."; case .screenRecording: return "Optional: lets Hands see the window it's working in."; default: return "" } }
}
