import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var addingAccount = false
    @State private var exporting = false
    @State private var importingPairing = false

    private var unsignedEmails: [String] {
        store.savedEmails.filter { e in !store.accounts.contains { $0.id == e.lowercased() } }
    }

    private var linkText: String {
        switch store.link {
        case .ok(let d): return "\(d.name) · iOS \(d.iosVersion)"
        case .checking: return "Checking…"
        case .failed: return "Not Connected"
        case .unknown: return "Not Checked"
        }
    }

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section {
                    ForEach(store.accounts) { a in
                        NavigationLink { AccountDetailView(account: a) } label: { AccountRow(account: a) }
                    }
                    ForEach(unsignedEmails, id: \.self) { e in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e)
                                Text("Not signed in").font(.caption).foregroundStyle(.orange)
                            }
                            Spacer()
                            Button("Sign In") { Task { await store.signInSaved() } }.pill()
                        }
                    }
                    Button { addingAccount = true } label: { Label("Add Apple ID", systemImage: "plus") }
                } header: {
                    Text("Apple IDs")
                } footer: {
                    Text("Each free Apple ID can have 3 apps installed and register 10 app IDs per week. Add more Apple IDs for more room.")
                }

                Section {
                    LabeledContent("Pairing File", value: store.hasPairing ? "Imported" : "Missing")
                    Button("Import Pairing File…") { importingPairing = true }
                    LabeledContent("Device") {
                        HStack(spacing: 6) {
                            Circle().fill(linkColor).frame(width: 8, height: 8)
                            Text(linkText).foregroundStyle(.secondary)
                        }
                    }
                    Button("Test Connection") { Task { await store.checkLink() } }
                    if case .failed(let why) = store.link {
                        Text(why).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Apps are installed through a loopback VPN. Keep LocalDevVPN turned on while installing or refreshing.")
                }

                Section {
                    Stepper(value: Binding(
                        get: { store.config.refreshThresholdHours },
                        set: { store.config.refreshThresholdHours = $0; store.saveConfig() }
                    ), in: 12...156, step: 12) {
                        LabeledContent("Refresh When Less Than", value: hoursText(store.config.refreshThresholdHours))
                    }
                    Button("Refresh All Now") { Task { _ = await store.refreshAll(force: true, includeSelf: false) } }
                        .disabled(store.busy != nil)
                    Button("Refresh JapuszkoInjector") { Task { await store.refreshSelf() } }
                        .disabled(store.busy != nil)
                } header: {
                    Text("Refresh")
                } footer: {
                    Text("Apps refresh automatically when you open JapuszkoInjector. For hands-off refreshing, create a Shortcuts automation (for example daily, or when charging) that runs “Refresh Apps”.")
                }

                Section("Signing") {
                    Toggle("Free Account Limits", isOn: Binding(
                        get: { store.config.enforceFreeLimits },
                        set: { store.config.enforceFreeLimits = $0; store.saveConfig() }))
                    Toggle("Revoke Old Certificates Automatically", isOn: Binding(
                        get: { store.config.autoRevokeCerts },
                        set: { store.config.autoRevokeCerts = $0; store.saveConfig() }))
                    Button("Export Certificate…") { exporting = true }
                        .disabled(store.accounts.isEmpty)
                    if !store.guests.isEmpty {
                        Button("Re-sign Apps Inside This App") { Task { await store.resignGuests() } }
                            .disabled(store.busy != nil)
                    }
                }

                Section("Advanced") {
                    NavigationLink("Network Test") { NetworkTestView() }
                    NavigationLink("Anisette Servers") { AnisetteView() }
                    NavigationLink("Apps on This Device") { DeviceAppsView() }
                    NavigationLink("Logs") { LogView() }
                    LabeledContent("StikDebug", value: store.stikDebugInstalled ? "Installed" : "Not Installed")
                }

                Section {
                    LabeledContent("Version",
                                   value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    if let s = store.selfExpiry {
                        LabeledContent("Signature", value: s.timeIntervalSinceNow.expiryText)
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $addingAccount) { AccountSheet().modalLevel() }
            .sheet(isPresented: $exporting) { ExportSheet().modalLevel() }
            .fileImporter(isPresented: $importingPairing, allowedContentTypes: [.propertyList, .data]) { r in
                if case .success(let url) = r { store.importPairing(url) }
            }
        }
    }

    private var linkColor: Color {
        switch store.link {
        case .ok: return .green
        case .checking: return .orange
        case .failed: return .red
        case .unknown: return .gray
        }
    }

    private func hoursText(_ h: Int) -> String {
        h % 24 == 0 ? "\(h / 24) day\(h == 24 ? "" : "s")" : "\(h) hours"
    }
}

struct AccountRow: View {
    @Environment(AppStore.self) private var store
    var account: AccountInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(account.email)
            Text(usage).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var usage: String {
        var parts = ["\(store.appsOn(account.email)) of 3 apps"]
        if let a = store.appIds[account.id]?.available { parts.append("\(max(a, 0)) app IDs left") }
        return parts.joined(separator: " · ")
    }
}

struct AccountDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var account: AccountInfo
    @State private var certs: [CertInfo] = []
    @State private var loading = true
    @State private var revoking: CertInfo?
    @State private var confirmSignOut = false
    @State private var exporting = false

    var body: some View {
        List {
            Section {
                LabeledContent("Name", value: "\(account.firstName) \(account.lastName)")
                LabeledContent("Team ID", value: account.teamId)
                LabeledContent("Apps", value: "\(store.appsOn(account.email)) of 3")
                if let ids = store.appIds[account.id] {
                    let max = Int(ids.max ?? 10)
                    let left = Swift.max(Int(ids.available ?? 0), 0)
                    LabeledContent("App IDs This Week", value: "\(max - left) of \(max) used")
                }
            }

            Section {
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if certs.isEmpty {
                    Text("No certificates").foregroundStyle(.secondary)
                }
                ForEach(certs) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(c.machineName.isEmpty ? c.name : c.machineName)
                            if c.isOurs {
                                Text("This App")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        Text(c.serial).font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Revoke", role: .destructive) { revoking = c }
                    }
                }
            } header: {
                Text("Certificates")
            } footer: {
                Text("Swipe to revoke. Apps signed with a revoked certificate stop opening until they're refreshed.")
            }

            Section {
                Button("Export Certificate…") { exporting = true }
                Button("Refresh App IDs") { Task { await store.loadAppIds(account.email) } }
            }

            Section {
                Button("Sign Out", role: .destructive) { confirmSignOut = true }
            }
        }
        .navigationTitle(account.firstName.isEmpty ? "Apple ID" : account.firstName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $exporting) { ExportSheet(preselected: account.email).modalLevel() }
        .confirmationDialog("Revoke this certificate?",
                            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                            titleVisibility: .visible) {
            Button("Revoke", role: .destructive) {
                guard let c = revoking else { return }
                Task { await store.revoke(c, on: account.email); await load() }
            }
        }
        .confirmationDialog("Sign out of \(account.email)?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                Task { await store.signOut(account.email); dismiss() }
            }
        } message: {
            Text("Apps signed with this Apple ID won't be refreshed anymore.")
        }
    }

    private func load() async {
        loading = true
        certs = await store.certs(account.email)
        loading = false
    }
}

struct AccountSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Apple ID", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } footer: {
                    Text("Your password is stored in this device's Keychain so apps can be refreshed automatically. It's only sent to Apple.")
                }
                if working {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Signing in…").foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("If Apple asks for a verification code, it shows up here.")
                    }
                }
            }
            .navigationTitle("Add Apple ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if working { store.cancelPendingPrompts() }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sign In") { signIn() }
                        .bold()
                        .disabled(working || email.isEmpty || password.isEmpty)
                }
            }
            .interactiveDismissDisabled(working)
        }
    }

    private func signIn() {
        working = true
        Task {
            let ok = await store.signIn(email: email, password: password)
            working = false
            if ok { dismiss() }
        }
    }
}

struct ExportSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var preselected: String? = nil
    @State private var account = ""
    @State private var password = ""
    @State private var appId: String? = nil
    @State private var share: ShareItems?
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Apple ID", selection: $account) {
                        ForEach(store.accounts) { a in Text(a.email).tag(a.email) }
                    }
                    Picker("Provisioning Profile", selection: $appId) {
                        Text("None").tag(String?.none)
                        ForEach(store.apps.filter { !$0.isSelf && $0.account.caseInsensitiveCompare(account) == .orderedSame }) { a in
                            Text(a.name).tag(Optional(a.id))
                        }
                    }
                    TextField("Password (Optional)", text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Exports the signing certificate and its private key as a .p12, for signers like Feather or ESign. Anyone with the file can sign apps as you, so keep it private. Without a password, the machine ID is used.")
                }
                if let result {
                    Section {
                        Text(result).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Export Certificate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") {
                        Task {
                            if let r = await store.exportCert(account, password: password, appId: appId) {
                                result = "Password: \(r.password)"
                                share = ShareItems(urls: r.files)
                            }
                        }
                    }
                    .bold()
                    .disabled(account.isEmpty || store.busy != nil)
                }
            }
            .sheet(item: $share) { s in ShareSheet(items: s.urls) }
        }
        .onAppear {
            if account.isEmpty { account = preselected ?? store.accounts.first?.email ?? "" }
        }
    }
}

struct AnisetteView: View {
    @Environment(AppStore.self) private var store
    @State private var newServer = ""

    var body: some View {
        @Bindable var store = store
        List {
            Section {
                ForEach(store.config.anisetteServers, id: \.self) { s in
                    Text(s).lineLimit(1).truncationMode(.middle)
                }
                .onDelete { idx in
                    store.config.anisetteServers.remove(atOffsets: idx)
                    store.saveConfig()
                }
                .onMove { from, to in
                    store.config.anisetteServers.move(fromOffsets: from, toOffset: to)
                    store.saveConfig()
                }
            } footer: {
                Text("Tried from top to bottom. A self-hosted anisette-v3-server is the most reliable option.")
            }
            Section {
                TextField("https://ani.example.com", text: $newServer)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add Server") {
                    let s = newServer.trimmingCharacters(in: .whitespaces)
                    guard s.hasPrefix("http") else { return }
                    store.config.anisetteServers.insert(s, at: 0)
                    store.saveConfig()
                    newServer = ""
                }
                .disabled(newServer.isEmpty)
            }
        }
        .navigationTitle("Anisette Servers")
        .toolbar { EditButton() }
    }
}

struct DeviceAppsView: View {
    @Environment(AppStore.self) private var store
    @State private var apps: [DeviceApp] = []
    @State private var loading = true

    var body: some View {
        List {
            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            ForEach(apps) { a in
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name.isEmpty ? a.id : a.name)
                    Text("\(a.id) · \(a.version)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Apps on This Device")
        .task {
            apps = await store.deviceApps()
            loading = false
        }
    }
}

struct LogView: View {
    @Environment(AppStore.self) private var store
    @State private var share: ShareItems?

    var body: some View {
        List {
            if store.logs.isEmpty {
                Text("No log entries yet.").foregroundStyle(.secondary)
            }
            ForEach(store.logs.reversed()) { l in
                VStack(alignment: .leading, spacing: 2) {
                    Text(l.message)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(color(l.level))
                        .textSelection(.enabled)
                    Text(l.date.formatted(date: .omitted, time: .standard))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Logs")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { exportLog() } label: { Image(systemName: "square.and.arrow.up") }
                Button { store.logs.removeAll() } label: { Image(systemName: "trash") }
            }
        }
        .sheet(item: $share) { s in ShareSheet(items: s.urls) }
    }

    private func color(_ level: String) -> Color {
        switch level {
        case "error": return .red
        case "warn": return .orange
        default: return .primary
        }
    }

    private func exportLog() {
        let text = store.logs.map { "\($0.date) [\($0.level)] \($0.message)" }.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("JapuszkoInjector-log.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        share = ShareItems(urls: [url])
    }
}

struct NetworkTestView: View {
    @Environment(AppStore.self) private var store
    @State private var result: NetTestResult?
    @State private var running = false

    var body: some View {
        List {
            Section {
                Button(running ? "Testing…" : "Run Test") { run() }.disabled(running)
            } footer: {
                Text("Checks the connection to the first anisette server: name lookup, connection, then a secure request.")
            }
            if let result {
                Section(result.server) {
                    ForEach(result.steps) { s in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: s.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(s.ok ? .green : .red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.step).font(.headline)
                                Text(s.detail).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Network Test")
        .task { if result == nil { run() } }
    }

    private func run() {
        running = true
        Task {
            result = await store.netTest()
            running = false
        }
    }
}
