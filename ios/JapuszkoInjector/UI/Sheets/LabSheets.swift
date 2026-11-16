import SwiftUI

struct AccountSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var working = false

    var body: some View {
        SheetFrame(code: "AC", title: "Add account", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: 18) {
                LabField(caption: "Apple ID", text: $email, placeholder: "name@icloud.com", keyboard: .emailAddress)
                LabField(caption: "Password", text: $password, secure: true)
                Text("The password stays in this device's Keychain so refreshes can sign in again by themselves. A spare Apple ID works too, and every extra account means 3 more app slots.")
                    .font(.body(11)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                Button(working ? "Signing in…" : "Sign in") {
                    working = true
                    Task {
                        let ok = await store.signIn(email: email, password: password)
                        working = false
                        if ok { dismiss() }
                    }
                }
                .buttonStyle(LabButtonStyle(kind: .primary))
                .disabled(working || email.isEmpty || password.isEmpty)
            }
        }
    }
}

struct CertsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var account: AccountInfo
    @State private var certs: [CertInfo] = []
    @State private var loading = true
    @State private var revoking: CertInfo?

    var body: some View {
        SheetFrame(code: "CT", title: "Certificates", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: 12) {
                Text(account.email).font(.label(11)).foregroundStyle(Theme.dim)
                if loading {
                    Text("> reading portal…").font(.readout(12)).foregroundStyle(Theme.faint)
                } else if certs.isEmpty {
                    Text("No development certificates.").font(.body(13)).foregroundStyle(Theme.dim)
                }
                ForEach(certs) { c in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(c.machineName.isEmpty ? c.name : c.machineName).font(.body(14)).foregroundStyle(Theme.text)
                                if c.isOurs { Tag(text: "ours", color: Theme.acid) }
                            }
                            Text(c.serial).font(.label(10)).foregroundStyle(Theme.dim)
                            if let e = c.expiresAt {
                                Text("valid until \(Date(timeIntervalSince1970: TimeInterval(e)).stamp)").caps(8)
                            }
                        }
                        Spacer()
                        Button("Revoke") { revoking = c }.buttonStyle(LabButtonStyle(kind: .danger, compact: true))
                    }
                    .padding(10)
                    .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                }
            }
        }
        .task { await load() }
        .confirmationDialog("Revoke this certificate?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
            Button("Revoke", role: .destructive) {
                guard let c = revoking else { return }
                Task { await store.revoke(c, on: account.email); await load() }
            }
        } message: {
            Text("Apps signed with it may stop opening until you refresh them.")
        }
    }

    private func load() async {
        loading = true
        certs = await store.certs(account.email)
        loading = false
    }
}

struct ExportSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var account = ""
    @State private var password = ""
    @State private var appId: String? = nil
    @State private var share: ShareItems?
    @State private var result: String?

    var body: some View {
        SheetFrame(code: "EX", title: "Export cert", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Exports the development certificate and its private key as .p12, plus a provisioning profile if you pick an app. Works in signers like Feather or ESign. Keep it private: it can sign apps as you.")
                    .font(.body(12)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)

                Text("Account").caps(9)
                ForEach(store.accounts) { a in
                    choice(a.email, selected: account == a.email) { account = a.email }
                }

                Text("Profile").caps(9)
                choice("None (.p12 only)", selected: appId == nil) { appId = nil }
                ForEach(store.apps.filter { !$0.isSelf && $0.account.caseInsensitiveCompare(account) == .orderedSame }) { a in
                    choice(a.name, selected: appId == a.id) { appId = a.id }
                }

                LabField(caption: "p12 password (blank = machine id)", text: $password)

                if let result {
                    Text(result).font(.label(11)).foregroundStyle(Theme.acid).textSelection(.enabled)
                }
                Button("Export") {
                    Task {
                        if let r = await store.exportCert(account, password: password, appId: appId) {
                            result = "Password: \(r.password)"
                            share = ShareItems(urls: r.files)
                        }
                    }
                }
                .buttonStyle(LabButtonStyle(kind: .primary))
                .disabled(account.isEmpty || store.busy != nil)
            }
        }
        .onAppear { if account.isEmpty { account = store.accounts.first?.email ?? "" } }
        .sheet(item: $share) { s in ShareSheet(items: s.urls) }
    }

    private func choice(_ title: String, selected: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack {
                Rectangle().fill(selected ? Theme.acid : Theme.line).frame(width: 3)
                Text(title).font(.body(14)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer()
            }
            .padding(.vertical, 8)
            .overlay(Rectangle().stroke(selected ? Theme.acid.opacity(0.5) : Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
