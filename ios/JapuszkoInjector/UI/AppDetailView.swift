import SwiftUI

struct AppDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var app: AppRecord
    @State private var share: ShareItems?
    @State private var confirmUninstall = false
    @State private var confirmForget = false

    /// Latest copy from the store, so the page updates after a refresh.
    private var a: AppRecord { store.apps.first { $0.id == app.id } ?? app }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    AppIcon(url: store.iconURL(a), name: a.name, size: 72,
                            systemImage: a.isSelf ? "syringe.fill" : nil)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(a.name).font(.title2.bold()).lineLimit(2)
                        Text(a.secondsLeft.expiryText)
                            .font(.subheadline)
                            .foregroundStyle(expiryColor(a.secondsLeft))
                    }
                }
                .padding(.vertical, 4)
            }

            if let busy = store.busy {
                Section { BusyRow(busy: busy) }
            }

            Section {
                Button {
                    Task { await store.refresh(a) }
                } label: {
                    Label(a.isSelf ? "Refresh JapuszkoInjector" : "Refresh Now", systemImage: "arrow.clockwise")
                }
                .disabled(store.busy != nil)
                if !a.isSelf && !a.account.isEmpty {
                    Button {
                        Task {
                            if let r = await store.exportCert(a.account, password: nil, appId: a.id) {
                                store.show(.info, "Certificate password: \(r.password)")
                                share = ShareItems(urls: r.files)
                            }
                        }
                    } label: {
                        Label("Export Certificate & Profile", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.busy != nil)
                }
            } footer: {
                if a.isSelf {
                    Text("JapuszkoInjector closes while it reinstalls itself. Open it again afterwards.")
                }
            }

            Section("Information") {
                if !a.version.isEmpty { LabeledContent("Version", value: a.version) }
                LabeledContent("Bundle ID", value: a.installedBundleId)
                if !a.account.isEmpty { LabeledContent("Apple ID", value: a.account) }
                LabeledContent("App IDs Used", value: "\(a.appIdCount)")
                if a.sizeBytes > 0 { LabeledContent("Size", value: a.sizeBytes.megabytes) }
                if a.installedAt > 0 {
                    LabeledContent("Installed", value: Date(timeIntervalSince1970: TimeInterval(a.installedAt)).short)
                }
                LabeledContent("Expires", value: Date(timeIntervalSince1970: TimeInterval(a.expiresAt)).short)
            }

            if !a.isSelf {
                Section {
                    Button("Uninstall", role: .destructive) { confirmUninstall = true }
                    Button("Stop Refreshing", role: .destructive) { confirmForget = true }
                } footer: {
                    Text("Stop Refreshing keeps the app installed, but it stops working when it expires.")
                }
                .disabled(store.busy != nil)
            }
        }
        .navigationTitle(a.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $share) { s in ShareSheet(items: s.urls) }
        .confirmationDialog("Uninstall \(a.name)?", isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) {
                Task { await store.remove(a, uninstall: true); dismiss() }
            }
        } message: {
            Text("The app and its data are removed from this device.")
        }
        .confirmationDialog("Stop refreshing \(a.name)?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Stop Refreshing", role: .destructive) {
                Task { await store.remove(a, uninstall: false); dismiss() }
            }
        }
    }
}

struct GuestDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var guest: GuestRecord
    @State private var needsJIT = false
    @State private var script = ""
    @State private var confirmRemove = false

    private var hostTeam: String? {
        let acct = store.apps.first(where: \.isSelf)?.account ?? ""
        return store.accounts.first { $0.email.caseInsensitiveCompare(acct) == .orderedSame }?.teamId
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    AppIcon(url: guest.iconRel.map { store.guestURL($0) }, name: guest.name, size: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(guest.name).font(.title2.bold()).lineLimit(2)
                        Text("Runs inside JapuszkoInjector").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if let t = hostTeam, t != guest.teamId {
                Section {
                    Label("Signed by a different team than JapuszkoInjector. Re-sign it before opening.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button {
                    store.launch(guest, jit: needsJIT ? .stikDebug : .off)
                } label: {
                    Label(needsJIT ? "Open with JIT" : "Open", systemImage: "play.fill")
                }
                .disabled(store.busy != nil || (needsJIT && !store.stikDebugInstalled))
                if needsJIT {
                    Button {
                        store.launch(guest, jit: .manual)
                    } label: {
                        Label("Open, I'll Enable JIT Myself", systemImage: "hand.tap")
                    }
                }
            } footer: {
                Text("JapuszkoInjector closes and \(guest.name) opens in its place. To come back, close it from the app switcher and open JapuszkoInjector again.")
            }

            Section {
                Toggle("Requires JIT", isOn: $needsJIT)
                    .onChange(of: needsJIT) { _, on in store.setGuestNeedsJIT(guest, on) }
                if needsJIT {
                    TextField("StikDebug Script (Optional)", text: $script)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: script) { _, v in store.setGuestScript(guest, v) }
                    LabeledContent("StikDebug", value: store.stikDebugInstalled ? "Installed" : "Not Installed")
                }
            } header: {
                Text("JIT")
            } footer: {
                Text("For emulators and VMs. JIT is turned on through StikDebug. On newer iOS versions some apps also need a StikDebug script.")
            }

            Section("Information") {
                if !guest.version.isEmpty { LabeledContent("Version", value: guest.version) }
                LabeledContent("Bundle ID", value: guest.bundleId)
                LabeledContent("Signed By", value: guest.teamId)
                LabeledContent("Size", value: guest.sizeBytes.megabytes)
                LabeledContent("Added", value: Date(timeIntervalSince1970: TimeInterval(guest.addedAt)).short)
            }

            Section {
                Button("Re-sign") { Task { await store.resignGuests(guest.id) } }
                    .disabled(store.busy != nil)
                Button("Remove", role: .destructive) { confirmRemove = true }
            }
        }
        .navigationTitle(guest.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            needsJIT = store.guestNeedsJIT(guest)
            script = store.guestScript(guest)
        }
        .confirmationDialog("Remove \(guest.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove and Keep Data") { store.removeGuest(guest, wipeData: false); dismiss() }
            Button("Remove and Delete Data", role: .destructive) { store.removeGuest(guest, wipeData: true); dismiss() }
        }
    }
}
