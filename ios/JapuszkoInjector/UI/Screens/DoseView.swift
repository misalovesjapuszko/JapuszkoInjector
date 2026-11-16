import SwiftUI
import UniformTypeIdentifiers

/// Load an IPA, adjust the formula, pick an account, push the plunger.
struct DoseView: View {
    @Environment(AppStore.self) private var store
    @Binding var incoming: URL?

    @State private var cartridge: URL?
    @State private var info: Inspected?
    @State private var options = InstallOptions()
    @State private var customName = ""
    @State private var customId = ""
    @State private var account: String? = nil   // nil = auto
    @State private var picking = false
    @State private var urlText = ""
    @State private var showURL = false
    @State private var runInside = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("DOSE").font(.head(44)).foregroundStyle(Theme.text)
                cartridgePanel
                if info != nil {
                    modeSwitch
                    formulaPanel
                    if !runInside { accountPanel }
                    plunger
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.ipa, .zip, .data]) { result in
            if case .success(let url) = result, let staged = store.stage(url) { load(staged) }
        }
        .onAppear {
            takeIncoming()
            takeSuggestion()
        }
        .onChange(of: incoming) { _, _ in takeIncoming() }
        .onChange(of: store.suggestRunInside) { _, _ in takeSuggestion() }
    }

    private func takeSuggestion() {
        guard store.suggestRunInside else { return }
        store.suggestRunInside = false
        withAnimation { runInside = true }
    }

    // MARK: mode

    private var modeSwitch: some View {
        HStack(spacing: 0) {
            modeButton("Install", detail: "Own icon · uses a slot", on: !runInside) { runInside = false }
            modeButton("Run inside", detail: "No slot · no app ID", on: runInside) { runInside = true }
        }
        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
    }

    private func modeButton(_ title: String, detail: String, on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.easeOut(duration: 0.15)) { tap() }
        } label: {
            VStack(spacing: 3) {
                Text(title).caps(11, on ? Theme.bg : Theme.text)
                Text(detail).font(.label(9)).foregroundStyle(on ? Theme.bg.opacity(0.7) : Theme.dim)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(on ? Theme.acid : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The account an install would land on (selected, or Auto's pick).
    private var targetAccount: AccountInfo? {
        if let a = account { return store.accounts.first { $0.email == a } }
        return store.accounts.min { store.appsOn($0.email) < store.appsOn($1.email) }
    }

    private var targetFull: Bool {
        guard store.config.enforceFreeLimits, let t = targetAccount else { return false }
        let existing = store.apps.contains { $0.id == info?.bundleId && $0.account.caseInsensitiveCompare(t.email) == .orderedSame }
        return !existing && store.appsOn(t.email) >= 3
    }

    private func takeIncoming() {
        guard let url = incoming else { return }
        incoming = nil
        load(url)
    }

    private func load(_ url: URL) {
        guard let i = store.inspect(url) else { return }
        cartridge = url
        info = i
        options = InstallOptions()
        customName = ""
        customId = ""
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func eject() {
        if let c = cartridge { try? FileManager.default.removeItem(at: c) }
        cartridge = nil
        info = nil
    }

    // MARK: 01 cartridge

    private var cartridgePanel: some View {
        Panel(code: "01", title: "Cartridge", accessory: {
            if info != nil {
                Button("Eject", action: eject).buttonStyle(LabButtonStyle(kind: .danger, compact: true))
            }
        }) {
            if let i = info {
                HStack(spacing: 14) {
                    AppIconView(url: i.icon.map { URL(fileURLWithPath: $0) }, name: i.name, size: 58)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(i.name).font(.head(24)).foregroundStyle(Theme.text).textCase(.uppercase).lineLimit(1)
                        Text(i.bundleId).font(.label(11)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 6) {
                            Tag(text: "v\(i.version)")
                            Tag(text: "\(i.extensions) ext", color: i.extensions > 0 ? Theme.amber : Theme.dim)
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                VStack(spacing: 12) {
                    Button { picking = true } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "shippingbox").font(.system(size: 26, weight: .light))
                            Text("Load .ipa from Files").caps(11, Theme.text)
                            Text("or open an .ipa with JapuszkoInjector from anywhere").font(.body(11)).foregroundStyle(Theme.dim)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 26)
                        .foregroundStyle(Theme.acid)
                        .background(
                            Rectangle().strokeBorder(Theme.acid.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showURL {
                        HStack(alignment: .bottom, spacing: 10) {
                            LabField(caption: "IPA URL", text: $urlText, placeholder: "https://…", keyboard: .URL)
                            Button("Fetch") {
                                guard let u = URL(string: urlText.trimmingCharacters(in: .whitespaces)) else { return }
                                Task { if let local = await store.download(u) { load(local) } }
                            }
                            .buttonStyle(LabButtonStyle(kind: .primary, compact: true))
                        }
                    } else {
                        Button("Download from URL") { showURL = true }.buttonStyle(LabButtonStyle(compact: true))
                    }
                }
            }
        }
    }

    // MARK: 02 formula

    private var formulaPanel: some View {
        Panel(code: "02", title: "Formula") {
            VStack(alignment: .leading, spacing: 14) {
                LabField(caption: "Display name", text: $customName, placeholder: info?.name ?? "")
                if runInside {
                    Text("Runs inside JapuszkoInjector, signed with its own certificate. Extensions are removed. Apps that need push notifications, widgets or special entitlements may not work.")
                        .font(.body(11)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                } else {
                    installOptions
                }
            }
        }
    }

    @ViewBuilder
    private var installOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
                LabField(caption: "Bundle ID override", text: $customId, placeholder: info?.bundleId ?? "")
                Rectangle().fill(Theme.line).frame(height: 1)
                LabToggle(title: "Strip extensions",
                          detail: "Widgets/share sheets each cost an app ID. Saves \(info?.extensions ?? 0).",
                          isOn: $options.stripExtensions)
                LabToggle(title: "Increased memory limit", detail: "Emulators and heavy apps.", isOn: $options.increasedMemoryLimit)
                LabToggle(title: "File sharing", detail: "Show its Documents in Files.", isOn: $options.fileSharing)
                LabToggle(title: "Run on any device", detail: "Removes iPhone/iPad-only restrictions.", isOn: $options.stripDeviceRestrictions)
        }
    }

    // MARK: 03 account

    private var accountPanel: some View {
        Panel(code: "03", title: "Account") {
            if store.accounts.isEmpty {
                Text("No Apple account signed in. Add one in Lab.").font(.body(13)).foregroundStyle(Theme.amber)
            } else {
                if targetFull, let t = targetAccount {
                    HStack(alignment: .top, spacing: 10) {
                        HazardStripes().frame(width: 8)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(t.email) is at 3/3 apps.").font(.body(13)).foregroundStyle(Theme.amber)
                            Text("Pick another account, replace an app when you inject, or use Run inside.")
                                .font(.body(11)).foregroundStyle(Theme.dim)
                            Button("Use Run inside") { withAnimation { runInside = true } }
                                .buttonStyle(LabButtonStyle(kind: .primary, compact: true))
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                }
                VStack(spacing: 8) {
                    accountChip(nil, title: "Auto", detail: "Account with the most room")
                    ForEach(store.accounts) { a in
                        let ids = store.appIds[a.id]
                        let left = ids?.available.map { "\($0) IDs left" } ?? "? IDs"
                        accountChip(a.email, title: a.email, detail: "\(store.appsOn(a.email))/3 apps · \(left)")
                    }
                }
            }
        }
    }

    private func accountChip(_ email: String?, title: String, detail: String) -> some View {
        let selected = account == email
        return Button {
            account = email
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: 10) {
                Rectangle().fill(selected ? Theme.acid : Theme.line).frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body(14)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(detail).font(.label(10)).foregroundStyle(Theme.dim)
                }
                Spacer()
                if selected { Image(systemName: "scope").foregroundStyle(Theme.acid) }
            }
            .padding(.vertical, 8).padding(.trailing, 10)
            .background(selected ? Theme.acid.opacity(0.06) : Color.clear)
            .overlay(Rectangle().stroke(selected ? Theme.acid.opacity(0.5) : Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 04 plunger

    private var linkFailed: Bool {
        if case .failed = store.link { return true }
        return false
    }

    private var plunger: some View {
        let working = store.busy?.title == "Injecting" || store.busy?.title == "Loading into container"
        let ready = cartridge != nil && !store.accounts.isEmpty && store.busy == nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("04").font(.label(9)).foregroundStyle(Theme.bg).padding(.horizontal, 4).background(Theme.dim)
                Text(working ? (runInside ? "Loading" : "Injecting") : "Plunger").caps(10, Theme.text)
                Spacer()
                if !runInside && linkFailed { Text("No link: turn on the VPN").caps(9, Theme.red) }
            }
            PlungerButton(label: runInside ? "Hold to load inside" : "Hold to inject",
                          enabled: ready,
                          progress: working ? store.busy?.value : nil,
                          stage: store.busy?.stage) {
                guard let c = cartridge else { return }
                if runInside {
                    Task {
                        if await store.addGuest(c, name: customName) != nil {
                            cartridge = nil
                            info = nil
                        }
                    }
                    return
                }
                var o = options
                o.customName = customName.isEmpty ? nil : customName
                o.customBundleId = customId.isEmpty ? nil : customId
                Task {
                    if await store.inject(c, options: o, account: account) != nil {
                        cartridge = nil
                        info = nil
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.panel)
        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
        .overlay(CornerBrackets().stroke(Theme.acid.opacity(ready ? 0.8 : 0.2), lineWidth: 1.5).padding(-1))
    }
}
