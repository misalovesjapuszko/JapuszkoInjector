import SwiftUI

struct AppsView: View {
    @Environment(AppStore.self) private var store
    @State private var importing = false
    @State private var askURL = false
    @State private var urlText = ""

    /// Registry apps, plus a synthetic row for ourselves if the registry has
    /// none (first install done by another tool).
    private var installed: [AppRecord] {
        var list = store.apps
        if !list.contains(where: \.isSelf), let exp = store.selfExpiry {
            list.append(AppRecord(id: "__self__", name: "JapuszkoInjector",
                                  version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                                  installedBundleId: Bundle.main.bundleIdentifier ?? "",
                                  installedAt: 0, expiresAt: Int64(exp.timeIntervalSince1970),
                                  options: InstallOptions(), appIdCount: 1, hasIcon: false,
                                  sizeBytes: 0, account: store.accounts.first?.email ?? ""))
        }
        return list.sorted { a, b in
            if a.isSelf != b.isSelf { return a.isSelf }
            return a.expiresAt < b.expiresAt
        }
    }

    private var setupIssues: [(String, String)] {
        var out: [(String, String)] = []
        if store.accounts.isEmpty { out.append(("person.crop.circle.badge.plus", "Add an Apple ID in Settings")) }
        if !store.hasPairing { out.append(("doc.badge.plus", "Import a pairing file in Settings")) }
        if !store.vpnActive && store.hasPairing {
            out.append(("network.slash", "LocalDevVPN is off. Turn it on in Settings → VPN."))
        } else if case .failed = store.link, store.hasPairing {
            out.append(("network.slash", "Can't reach the device. Check LocalDevVPN."))
        }
        return out
    }

    var body: some View {
        NavigationStack {
            List {
                if let busy = store.busy {
                    Section { BusyRow(busy: busy) }
                }
                if !setupIssues.isEmpty {
                    Section("Setup") {
                        ForEach(setupIssues, id: \.1) { issue in
                            Label(issue.1, systemImage: issue.0).foregroundStyle(.orange)
                        }
                    }
                }
                if !installed.isEmpty {
                    Section("Installed") {
                        ForEach(installed) { app in
                            NavigationLink(value: app) { AppRow(app: app) }
                        }
                    }
                }
                if !store.guests.isEmpty {
                    Section {
                        ForEach(store.guests) { g in
                            NavigationLink(value: g) { GuestRow(guest: g) }
                        }
                    } header: {
                        Text("Inside JapuszkoInjector")
                    } footer: {
                        Text("These run inside JapuszkoInjector and don't use an app slot or app ID.")
                    }
                }
            }
            .overlay {
                if installed.isEmpty && store.guests.isEmpty && store.busy == nil {
                    ContentUnavailableView("No Apps",
                                           systemImage: "square.stack.3d.up",
                                           description: Text("Tap + to install an .ipa."))
                }
            }
            .navigationTitle("Apps")
            .navigationDestination(for: AppRecord.self) { AppDetailView(app: $0) }
            .navigationDestination(for: GuestRecord.self) { GuestDetailView(guest: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { _ = await store.refreshAll(force: false, includeSelf: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.busy != nil || store.apps.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { importing = true } label: { Label("Choose File", systemImage: "folder") }
                        Button { askURL = true } label: { Label("Download from URL", systemImage: "link") }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(store.busy != nil)
                }
            }
            .refreshable {
                await store.checkLink()
                await store.refreshDue(includeSelf: false)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.ipa, .zip, .data]) { result in
                if case .success(let url) = result, let staged = store.stage(url) {
                    store.pendingInstall = PendingInstall(url: staged)
                }
            }
            .alert("Download IPA", isPresented: $askURL) {
                TextField("https://…", text: $urlText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Download") {
                    guard let u = URL(string: urlText.trimmingCharacters(in: .whitespaces)) else { return }
                    urlText = ""
                    Task {
                        if let local = await store.download(u) {
                            store.pendingInstall = PendingInstall(url: local)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a direct link to an .ipa file.")
            }
        }
    }
}

struct AppRow: View {
    @Environment(AppStore.self) private var store
    var app: AppRecord

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(url: store.iconURL(app), name: app.name, size: 48,
                    systemImage: app.isSelf ? "syringe.fill" : nil,
                    isSelf: app.isSelf)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.headline).lineLimit(1)
                Text(app.secondsLeft.expiryText)
                    .font(.subheadline)
                    .foregroundStyle(expiryColor(app.secondsLeft))
            }
            Spacer(minLength: 8)
            Button("Refresh") { Task { await store.refresh(app) } }
                .pill()
                .disabled(store.busy != nil)
        }
        .padding(.vertical, 2)
    }
}

struct GuestRow: View {
    @Environment(AppStore.self) private var store
    var guest: GuestRecord

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(url: guest.iconRel.map { store.guestURL($0) }, name: guest.name, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(guest.name).font(.headline).lineLimit(1)
                Text(store.guestNeedsJIT(guest) ? "Runs inside · JIT" : "Runs inside")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Open") {
                store.launch(guest, jit: store.guestNeedsJIT(guest) ? .stikDebug : .off)
            }
            .pill()
            .disabled(store.busy != nil)
        }
        .padding(.vertical, 2)
    }
}
