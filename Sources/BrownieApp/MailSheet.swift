import SwiftUI
import AppKit
import Domain
import CloudSources

/// Connecting a mailbox, in three steps and one trip to the browser.
///
/// The shape is deliberate. An unverified OAuth client would be one button, but Google answers it with a
/// full-page warning whose way through is a link labelled "unsafe" — which is a poor thing to ask of someone
/// on the strength of a promise that their mail never leaves their Mac. A pasted app password is one step
/// longer and nothing in it is frightening.
///
/// The address field decides everything downstream as it is typed: which server, what the credential is
/// called, and which page mints it. Nobody is ever asked for a hostname unless Brownie genuinely cannot guess.
struct MailSheet: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss

    @State private var address = ""
    @State private var password = ""
    @State private var host = ""
    @State private var port = "993"
    @State private var advanced = false
    @State private var step = 0
    @State private var busy = false
    @State private var error: String?
    @State private var found = 0

    /// Recomputed on every keystroke, which is what makes the rest of the sheet answer as you type.
    var provider: MailProvider? { MailProvider.forAddress(address) }
    var knowsServer: Bool { provider != nil || !host.trimmingCharacters(in: .whitespaces).isEmpty }
    var looksLikeAddress: Bool { address.contains("@") && !address.hasPrefix("@") && !address.hasSuffix("@") && address.count > 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            steps
            Divider()
            stepBody
            if let error {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(t.bad)
                    Text(error).font(.system(size: 12)).foregroundStyle(t.bad).fixedSize(horizontal: false, vertical: true)
                }
            }
            footer
        }
        .padding(24).frame(width: 520).foregroundStyle(t.ink).background(t.content)
        .onChange(of: address) { _, _ in error = nil }
    }

    var header: some View {
        HStack(spacing: 10) {
            ZStack { RoundedRectangle(cornerRadius: 8).fill(t.accentSoft).frame(width: 34, height: 34); Image(systemName: "envelope").foregroundStyle(t.accentInk).font(.system(size: 15)) }
            VStack(alignment: .leading, spacing: 2) {
                H2(text: step == 2 ? "Connected" : "Connect your mail")
                Text(step == 0 ? "Read-only. It is read on this Mac and never leaves it."
                     : "\(address)\(provider.map { " · \($0.name)" } ?? "")")
                    .font(.system(size: 12)).foregroundStyle(t.ink2)
            }
        }
    }

    var steps: some View {
        HStack(spacing: 6) {
            ForEach(Array(["Address", "Password", "Done"].enumerated()), id: \.offset) { i, s in
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(i < step ? t.ok : (i == step ? t.accent : t.ctl2)).frame(width: 18, height: 18)
                        if i < step { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
                        else { Text("\(i + 1)").font(.system(size: 10, weight: .semibold)).foregroundStyle(i == step ? Color(hex: 0x1A1205) : t.ink2) }
                    }
                    Text(s).font(.system(size: 12, weight: i == step ? .semibold : .regular)).foregroundStyle(i == step ? t.ink : t.ink2)
                }
                if i < 2 { Rectangle().fill(t.sep).frame(width: 24, height: 1) }
            }
        }
    }

    @ViewBuilder var stepBody: some View {
        switch step {
        case 0: addressStep
        case 1: passwordStep
        default: doneStep
        }
    }

    var addressStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Email address").font(.system(size: 12, weight: .medium))
            HStack {
                TextField("them@example.com", text: $address).textFieldStyle(.roundedBorder).frame(width: 260).disabled(busy)
                    .onSubmit { if looksLikeAddress && knowsServer { step = 1 } }
                BButton(title: "Continue", kind: .primary) { step = 1 }.disabled(!looksLikeAddress || !knowsServer)
            }
            if let p = provider {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(t.ok).font(.system(size: 11))
                    Text("Recognised **\(p.name)**. Brownie will use \(p.host):\(String(p.port)) — no server or port to type.")
                        .font(.system(size: 11)).foregroundStyle(t.ink2)
                }
            } else if looksLikeAddress {
                Text("Brownie doesn't know that domain's mail server. Add it under Advanced — your provider's help pages call it the IMAP server.")
                    .font(.system(size: 11)).foregroundStyle(t.ink2).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Gmail, iCloud, Outlook, Fastmail, Proton via its Bridge, or any work IMAP server.")
                    .font(.system(size: 11)).foregroundStyle(t.ink2)
            }
            if advanced || (looksLikeAddress && provider == nil) {
                HStack(spacing: 8) {
                    TextField("imap.theircompany.test", text: $host).textFieldStyle(.roundedBorder).frame(width: 200)
                    Text("port").font(.system(size: 11)).foregroundStyle(t.ink2)
                    TextField("993", text: $port).textFieldStyle(.roundedBorder).frame(width: 56)
                }
            }
        }
    }

    var passwordStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(provider?.credentialNote == nil ? "Password" : "App password").font(.system(size: 12, weight: .medium))
            HStack {
                SecureField("", text: $password).textFieldStyle(.roundedBorder).frame(width: 260).font(.system(size: 13, design: .monospaced)).disabled(busy)
                    .onSubmit(connect)
                HStack(spacing: 8) { if busy { ProgressView().controlSize(.small) }; BButton(title: busy ? "Connecting…" : "Connect", kind: .primary, action: connect).disabled(busy || password.isEmpty) }
            }
            if let note = provider?.credentialNote {
                Text(note).font(.system(size: 11)).foregroundStyle(t.ink2).fixedSize(horizontal: false, vertical: true)
            }
            if let url = provider?.appPasswordURL {
                HStack(spacing: 8) {
                    BButton(title: "Create one at \(provider?.name ?? "your provider")", kind: .quiet) { NSWorkspace.shared.open(URL(string: url)!) }
                    if provider?.name == "Gmail" {
                        Text("Needs 2-Step Verification on first.").font(.system(size: 11)).foregroundStyle(t.ink2)
                    }
                }
            }
        }
    }

    var doneStep: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(t.ok).font(.system(size: 18))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(found) messages found").fontWeight(.semibold)
                Text("Reading the last few days first, then only what is new. Mail is summarised on this Mac; only the summary can reach the brain, and every byte of that is under “What left your Mac”.")
                    .font(.system(size: 12)).foregroundStyle(t.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var footer: some View {
        HStack {
            if step == 1 && !advanced && provider?.name == "Gmail" {
                BButton(title: "Using a work account?", kind: .quiet) {
                    error = "Some Workspace administrators switch app passwords off. If yours has, ask them to allow one for your account: with 2-Step Verification on and app passwords blocked, there is no other way in from here."
                }
            }
            Spacer()
            if step == 1 { BButton(title: "Back", kind: .quiet) { step = 0; error = nil } }
            BButton(title: step == 2 ? "Done" : "Cancel", kind: .quiet) { dismiss() }
        }
    }

    func connect() {
        busy = true; error = nil
        let h = host.trimmingCharacters(in: .whitespaces)
        Task {
            let r = await m.mailConnect(address: address.trimmingCharacters(in: .whitespaces), password: password,
                                        host: h.isEmpty ? nil : h, port: h.isEmpty ? nil : UInt16(port))
            busy = false
            if let e = r.error { error = e } else { found = r.found; step = 2; password = "" }
        }
    }
}
