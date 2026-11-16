import SwiftUI
import UniformTypeIdentifiers

/// Settings, accounts, certificates, link, anisette.
struct LabView: View {
    @Environment(AppStore.self) private var store
    @State private var addingAccount = false
    @State private var certsFor: AccountInfo?
    @State private var exporting = false
    @State private var importingPairing = false
    @State private var newServer = ""
    @State private var deviceApps: [DeviceApp] = []
    @State private var showDeviceApps = false

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("LAB").font(.head(44)).foregroundStyle(Theme.text)
                accounts
                link
                refresh
                signing
                anisette
                device
                jit
                about
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $addingAccount) { AccountSheet() }
        .sheet(item: $certsFor) { a in CertsSheet(account: a) }
        .sheet(isPresented: $exporting) { ExportSheet() }
        .fileImporter(isPresented: $importingPairing, allowedContentTypes: [.propertyList, .data]) { r in
            if case .success(let url) = r { store.importPairing(url) }
        }
    }

    // MARK: 01 accounts

    private var accounts: some View {
        Panel(code: "01", title: "Accounts", accessory: {
            Button("Add") { addingAccount = true }.buttonStyle(LabButtonStyle(kind: .primary, compact: true))
        }) {
            VStack(alignment: .leading, spacing: 14) {
                if store.accounts.isEmpty && store.savedEmails.isEmpty {
                    Text("No Apple ID yet. Each free account gets 3 apps and 10 app IDs a week, so add a second one for more room.")
                        .font(.body(12)).foregroundStyle(Theme.dim)
                }
                ForEach(store.accounts) { a in
                    VStack(alignment: .leading, spacing: 10) {
                        AccountMeters(account: a)
                        Text(a.email).font(.label(10)).foregroundStyle(Theme.dim)
                        HStack(spacing: 8) {
                            Button("Certs") { certsFor = a }.buttonStyle(LabButtonStyle(compact: true))
                            Button("IDs") { Task { await store.loadAppIds(a.email) } }.buttonStyle(LabButtonStyle(compact: true))
                            Spacer()
                            Button("Sign out") { Task { await store.signOut(a.email) } }
                                .buttonStyle(LabButtonStyle(kind: .danger, compact: true))
                        }
                    }
                    .padding(10)
                    .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                }
                // saved but not signed in (e.g. 2FA pending)
                ForEach(store.savedEmails.filter { e in !store.accounts.contains { $0.id == e.lowercased() } }, id: \.self) { e in
                    HStack {
                        Lamp(color: Theme.amber)
                        Text(e).font(.label(11)).foregroundStyle(Theme.text)
                        Spacer()
                        Button("Retry") { Task { await store.signInSaved() } }.buttonStyle(LabButtonStyle(compact: true))
                        Button("Drop") { Task { await store.signOut(e) } }.buttonStyle(LabButtonStyle(kind: .danger, compact: true))
                    }
                }
            }
        }
    }

    // MARK: 02 link

    private var link: some View {
        Panel(code: "02", title: "Link") {
            VStack(alignment: .leading, spacing: 12) {
                statusRow("Pairing", ok: store.hasPairing, store.hasPairing ? "Imported" : "Missing")
                switch store.link {
                case .ok(let d):
                    statusRow("Device", ok: true, "\(d.name) · iOS \(d.iosVersion)")
                case .failed(let why):
                    statusRow("Device", ok: false, why)
                case .checking:
                    statusRow("Device", ok: nil, "Probing…")
                case .unknown:
                    statusRow("Device", ok: nil, "Not checked")
                }
                Text("Installs go through a loopback VPN to this device. Keep LocalDevVPN (or StosVPN) on while injecting or refreshing.")
                    .font(.body(11)).foregroundStyle(Theme.dim)
                HStack(spacing: 8) {
                    Button("Test link") { Task { await store.checkLink() } }.buttonStyle(LabButtonStyle(kind: .primary, compact: true))
                    Button("Import pairing") { importingPairing = true }.buttonStyle(LabButtonStyle(compact: true))
                    Spacer()
                }
                LabField(caption: "Loopback address", text: Binding(
                    get: { store.config.target.ip ?? "10.7.0.1" },
                    set: { store.config.target.ip = $0 }
                ), placeholder: "10.7.0.1", keyboard: .numbersAndPunctuation)
                .onSubmit { store.saveConfig() }
            }
        }
    }

    private func statusRow(_ k: String, ok: Bool?, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Lamp(color: ok == nil ? Theme.amber : (ok! ? Theme.acid : Theme.red))
                .padding(.top, 4)
            Text(k).caps(9).frame(width: 84, alignment: .leading).padding(.top, 2)
            Text(v).font(.label(11)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: 03 refresh

    private var refresh: some View {
        Panel(code: "03", title: "Refresh") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto refresh window").font(.body(14)).foregroundStyle(Theme.text)
                        Text("Refresh anything with less than this left.").font(.body(11)).foregroundStyle(Theme.dim)
                    }
                    Spacer()
                    Stepper("", value: Binding(
                        get: { store.config.refreshThresholdHours },
                        set: { store.config.refreshThresholdHours = $0; store.saveConfig() }
                    ), in: 12...156, step: 12)
                    .labelsHidden()
                    Text("\(store.config.refreshThresholdHours)H").font(.readout(14)).foregroundStyle(Theme.acid)
                        .frame(width: 50, alignment: .trailing)
                }
                if let s = store.selfExpiry {
                    statusRow("Injector", ok: s.timeIntervalSinceNow > 86400, "\(s.timeIntervalSinceNow.readout) left")
                }
                HStack(spacing: 8) {
                    Button("Refresh due") { Task { _ = await store.refreshAll(force: false, includeSelf: true) } }
                        .buttonStyle(LabButtonStyle(kind: .primary, compact: true))
                    Button("Re-inject self") { Task { await store.refreshSelf() } }
                        .buttonStyle(LabButtonStyle(compact: true))
                    Spacer()
                }
                .disabled(store.busy != nil)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hands-off refresh").caps(9, Theme.amber)
                    Text("Shortcuts → Automation → New → Time of Day (e.g. 04:00) → Run Immediately → add “Refresh Apps” from JapuszkoInjector. Keep the VPN on. Opening the app also refreshes what's due, and you get a notice 24h and 3h before anything expires.")
                        .font(.body(11)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .overlay(Rectangle().stroke(Theme.amber.opacity(0.35), lineWidth: 1))
            }
        }
    }

    // MARK: 04 signing

    private var signing: some View {
        Panel(code: "04", title: "Signing") {
            VStack(alignment: .leading, spacing: 12) {
                LabField(caption: "Certificate machine name", text: Binding(
                    get: { store.config.machineName },
                    set: { store.config.machineName = $0 }
                ))
                .onSubmit { store.saveConfig() }
                LabToggle(title: "Auto-revoke old certificates",
                          detail: "When an account hits its cert limit, revoke without asking.",
                          isOn: Binding(get: { store.config.autoRevokeCerts },
                                        set: { store.config.autoRevokeCerts = $0; store.saveConfig() }))
                LabToggle(title: "Free account limits",
                          detail: "Stop at 3 apps per account and offer to replace one. Turn off for paid accounts.",
                          isOn: Binding(get: { store.config.enforceFreeLimits },
                                        set: { store.config.enforceFreeLimits = $0; store.saveConfig() }))
                Button("Re-sign container apps") { Task { await store.resignGuests() } }
                    .buttonStyle(LabButtonStyle())
                    .disabled(store.guests.isEmpty || store.busy != nil)
                Button("Export certificate (.p12)") { exporting = true }
                    .buttonStyle(LabButtonStyle())
                    .disabled(store.accounts.isEmpty)
            }
        }
    }

    // MARK: 05 anisette

    private var anisette: some View {
        Panel(code: "05", title: "Anisette") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Tried top to bottom. Put your own server first (anisette-v3-server runs fine on an always-on phone or Pi).")
                    .font(.body(11)).foregroundStyle(Theme.dim)
                ForEach(Array(store.config.anisetteServers.enumerated()), id: \.offset) { i, s in
                    HStack(spacing: 8) {
                        Text(String(format: "%02d", i + 1)).font(.readout(10)).foregroundStyle(Theme.faint)
                        Text(s).font(.label(11)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if i > 0 {
                            Button { move(i, to: i - 1) } label: { Image(systemName: "arrow.up") }
                                .buttonStyle(LabButtonStyle(compact: true))
                        }
                        Button {
                            store.config.anisetteServers.remove(at: i)
                            store.saveConfig()
                        } label: { Image(systemName: "xmark") }
                        .buttonStyle(LabButtonStyle(kind: .danger, compact: true))
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    LabField(caption: "Add server", text: $newServer, placeholder: "https://ani.example.com", keyboard: .URL)
                    Button("Add") {
                        let s = newServer.trimmingCharacters(in: .whitespaces)
                        guard s.hasPrefix("http") else { return }
                        store.config.anisetteServers.insert(s, at: 0)
                        store.saveConfig()
                        newServer = ""
                    }
                    .buttonStyle(LabButtonStyle(kind: .primary, compact: true))
                }
            }
        }
    }

    private func move(_ from: Int, to: Int) {
        let s = store.config.anisetteServers.remove(at: from)
        store.config.anisetteServers.insert(s, at: to)
        store.saveConfig()
    }

    // MARK: 06 device

    private var device: some View {
        Panel(code: "06", title: "Device") {
            VStack(alignment: .leading, spacing: 10) {
                Button(showDeviceApps ? "Hide installed apps" : "List installed apps") {
                    if showDeviceApps { showDeviceApps = false; return }
                    Task {
                        deviceApps = await store.deviceApps()
                        showDeviceApps = true
                    }
                }
                .buttonStyle(LabButtonStyle(compact: true))
                if showDeviceApps {
                    ForEach(deviceApps) { a in
                        HStack {
                            Text(a.name.isEmpty ? a.id : a.name).font(.body(13)).foregroundStyle(Theme.text).lineLimit(1)
                            Spacer()
                            Text(a.version).font(.label(10)).foregroundStyle(Theme.dim)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    // MARK: JIT

    private var jit: some View {
        Panel(code: "JT", title: "JIT") {
            VStack(alignment: .leading, spacing: 10) {
                statusRow("StikDebug", ok: store.stikDebugInstalled, store.stikDebugInstalled ? "Installed" : "Not installed")
                statusRow("This process", ok: store.jitActive ? true : nil, store.jitActive ? "JIT on" : "No JIT (normal)")
                Text("Container apps marked “Needs JIT” launch through StikDebug: it relaunches JapuszkoInjector with a debugger attached, then the guest starts with JIT. Normal apps don't need any of this.")
                    .font(.body(11)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 07 about

    private var about: some View {
        Panel(code: "07", title: "About") {
            VStack(alignment: .leading, spacing: 6) {
                Text("JapuszkoInjector \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.head(18)).foregroundStyle(Theme.text)
                Text("Signing and install engine built on isideload (MIT) and idevice (MIT).")
                    .font(.body(11)).foregroundStyle(Theme.dim)
            }
        }
    }
}
