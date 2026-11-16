import SwiftUI

/// Shown after picking an .ipa: options, account, then install.
struct InstallSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var file: URL

    @State private var info: Inspected?
    @State private var failed = false
    @State private var runInside = false
    @State private var account: String? = nil
    @State private var name = ""
    @State private var bundleId = ""
    @State private var options = InstallOptions()
    @State private var working = false

    private var targetAccount: AccountInfo? {
        if let a = account { return store.accounts.first { $0.email == a } }
        return store.accounts.min { store.appsOn($0.email) < store.appsOn($1.email) }
    }

    private var targetFull: Bool {
        guard store.config.enforceFreeLimits, let t = targetAccount else { return false }
        let existing = store.apps.contains {
            $0.id == info?.bundleId && $0.account.caseInsensitiveCompare(t.email) == .orderedSame
        }
        return !existing && store.appsOn(t.email) >= 3
    }

    var body: some View {
        NavigationStack {
            Form {
                if let info {
                    Section {
                        HStack(spacing: 14) {
                            AppIcon(url: info.icon.map { URL(fileURLWithPath: $0) }, name: info.name, size: 60)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(info.name).font(.headline)
                                Text("Version \(info.version)").font(.subheadline).foregroundStyle(.secondary)
                                Text(info.bundleId).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Section {
                        Picker("Install", selection: $runInside) {
                            Text("Normally").tag(false)
                            Text("Inside This App").tag(true)
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        Text(runInside
                             ? "Runs inside JapuszkoInjector. Uses no app slot or app ID. Extensions are removed, and apps that need push notifications or widgets may not work."
                             : "Gets its own home screen icon. Uses one of the 3 app slots of the Apple ID.")
                    }

                    if !runInside {
                        accountSection
                    }

                    Section("Options") {
                        TextField("Name", text: $name, prompt: Text(info.name))
                        if !runInside {
                            TextField("Bundle ID", text: $bundleId, prompt: Text(info.bundleId))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            if info.extensions > 0 {
                                Toggle("Remove Extensions", isOn: $options.stripExtensions)
                            }
                            Toggle("Increased Memory Limit", isOn: $options.increasedMemoryLimit)
                            Toggle("File Sharing", isOn: $options.fileSharing)
                            Toggle("Support All Devices", isOn: $options.stripDeviceRestrictions)
                        }
                    }

                    if let busy = store.busy, working {
                        Section { BusyRow(busy: busy) }
                    }
                } else if failed {
                    ContentUnavailableView("Can't Read This File",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text("Make sure it's a decrypted .ipa."))
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .navigationTitle("Install App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        try? FileManager.default.removeItem(at: file)
                        dismiss()
                    }
                    .disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Install") { install() }
                            .bold()
                            .disabled(info == nil || store.accounts.isEmpty || store.busy != nil)
                    }
                }
            }
            .interactiveDismissDisabled(working)
        }
        .task {
            if info == nil {
                info = store.inspect(file)
                failed = info == nil
            }
        }
        .onAppear { takeSuggestion() }
        .onChange(of: store.suggestRunInside) { _, _ in takeSuggestion() }
    }

    private var accountSection: some View {
        Section {
            if store.accounts.isEmpty {
                Text("Add an Apple ID in Settings first.").foregroundStyle(.secondary)
            } else {
                Picker("Apple ID", selection: $account) {
                    Text("Automatic").tag(String?.none)
                    ForEach(store.accounts) { a in
                        Text(a.email).tag(Optional(a.email))
                    }
                }
                if targetFull, let t = targetAccount {
                    Label("\(t.email) already has 3 apps.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Install Inside This App Instead") { runInside = true }
                }
            }
        } header: {
            Text("Account")
        } footer: {
            if let t = targetAccount {
                let ids = store.appIds[t.id]?.available.map { "\(max($0, 0)) app IDs left this week" } ?? ""
                Text("\(store.appsOn(t.email)) of 3 apps used\(ids.isEmpty ? "" : " · " + ids)")
            }
        }
    }

    private func takeSuggestion() {
        guard store.suggestRunInside else { return }
        store.suggestRunInside = false
        runInside = true
    }

    private func install() {
        working = true
        Task {
            let ok: Bool
            if runInside {
                ok = await store.addGuest(file, name: name) != nil
            } else {
                var o = options
                o.customName = name.isEmpty ? nil : name
                o.customBundleId = bundleId.isEmpty ? nil : bundleId
                ok = await store.inject(file, options: o, account: account) != nil
            }
            working = false
            if ok { dismiss() }
        }
    }
}
