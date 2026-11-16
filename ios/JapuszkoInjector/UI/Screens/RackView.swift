import SwiftUI

/// Home: every injected app as a vial on a rack, plus the manifest.
struct RackView: View {
    @Environment(AppStore.self) private var store
    var goDose: () -> Void
    @State private var detail: AppRecord?
    @State private var guest: GuestRecord?

    /// Registry apps, plus a synthetic record for ourselves if the registry
    /// doesn't have one (first install done by another tool).
    private var items: [AppRecord] {
        var list = store.apps
        if !list.contains(where: \.isSelf), let exp = store.selfExpiry {
            list.insert(AppRecord(id: "__self__", name: "JapuszkoInjector",
                                  version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                                  installedBundleId: Bundle.main.bundleIdentifier ?? "",
                                  installedAt: 0, expiresAt: Int64(exp.timeIntervalSince1970),
                                  options: InstallOptions(), appIdCount: 1, hasIcon: false,
                                  sizeBytes: 0, account: store.accounts.first?.email ?? ""), at: 0)
        }
        return list.sorted { a, b in
            if a.isSelf != b.isSelf { return a.isSelf }
            return a.expiresAt < b.expiresAt
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if needsSetup { SetupPanel() }
                if items.isEmpty {
                    emptyRack
                } else {
                    rack
                    manifest
                }
                if !store.guests.isEmpty { container }
                if !store.accounts.isEmpty { slots }
                HStack(spacing: 10) {
                    Button("Refresh due") { Task { _ = await store.refreshAll(force: false, includeSelf: true) } }
                        .buttonStyle(LabButtonStyle(kind: .primary))
                    Button("Force all") { Task { _ = await store.refreshAll(force: true, includeSelf: false) } }
                        .buttonStyle(LabButtonStyle())
                }
                .disabled(store.busy != nil)
            }
            .padding(.horizontal, 16).padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await store.checkLink()
            await store.refreshDue(includeSelf: false)
        }
        .sheet(item: $detail) { app in AppDetailSheet(app: app) }
        .sheet(item: $guest) { g in GuestSheet(guest: g) }
    }

    private var needsSetup: Bool {
        if !store.hasPairing || store.accounts.isEmpty { return true }
        if case .failed = store.link { return true }
        return false
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("RACK").font(.head(44)).foregroundStyle(Theme.text)
                Spacer()
                LinkBadge()
            }
            HStack(spacing: 8) {
                Text("\(store.apps.filter { !$0.isSelf }.count) vials").caps()
                Text("/").foregroundStyle(Theme.faint).font(.label())
                if let next = store.apps.filter({ !$0.isSelf }).map(\.secondsLeft).min() {
                    Text("next expiry \(next.readout)").caps(10, Theme.level(next / (7 * 86400)))
                } else {
                    Text("nothing expiring").caps()
                }
            }
        }
    }

    // MARK: rack

    private var rack: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(alignment: .bottom, spacing: 20) {
                    ForEach(items) { app in
                        Button { detail = app } label: { VialColumn(app: app, iconURL: store.iconURL(app)) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18).padding(.top, 14)
            }
            .scrollIndicators(.hidden)
            // the shelf
            ZStack {
                Rectangle().fill(Theme.panelHi).frame(height: 14)
                Rectangle().fill(Theme.lineHi).frame(height: 1).frame(maxHeight: .infinity, alignment: .top)
                HStack(spacing: 6) {
                    ForEach(0..<40, id: \.self) { _ in Rectangle().fill(Theme.line).frame(width: 1, height: 6) }
                }
            }
            .frame(height: 14)
        }
        .background(
            LinearGradient(colors: [Theme.panel.opacity(0.0), Theme.panel], startPoint: .top, endPoint: .bottom)
        )
        .overlay(CornerBrackets().stroke(Theme.lineHi, lineWidth: 1.5))
    }

    private var emptyRack: some View {
        Panel(code: "00", title: "Rack empty") {
            HStack(spacing: 18) {
                Vial(fill: 0, width: 34, height: 110, live: false).opacity(0.6)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Nothing injected yet.").font(.head(22)).foregroundStyle(Theme.text)
                    Text("Load an .ipa, pick an account and hold the plunger.").font(.body(13)).foregroundStyle(Theme.dim)
                    Button("Load first dose", action: goDose).buttonStyle(LabButtonStyle(kind: .primary, compact: true))
                }
            }
        }
    }

    // MARK: manifest

    private var manifest: some View {
        Panel(code: "01", title: "Manifest") {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, app in
                    Button { detail = app } label: {
                        ManifestRow(index: i + 1, app: app, iconURL: store.iconURL(app))
                    }
                    .buttonStyle(.plain)
                    if i < items.count - 1 { Rectangle().fill(Theme.line).frame(height: 1) }
                }
            }
        }
    }

    // MARK: container

    private var container: some View {
        Panel(code: "CT", title: "Container", accessory: {
            Text("\(store.guests.count) inside").caps(9, Theme.acid)
        }) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Run inside JapuszkoInjector. No app slots, no app IDs, and they live as long as the injector does.")
                    .font(.body(11)).foregroundStyle(Theme.dim)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 12)], spacing: 14) {
                    ForEach(store.guests) { g in
                        Button { guest = g } label: {
                            VStack(spacing: 6) {
                                AppIconView(url: g.iconRel.map { store.guestURL($0) }, name: g.name, size: 52)
                                    .overlay(alignment: .bottomTrailing) {
                                        Image(systemName: "shippingbox.fill").font(.system(size: 9))
                                            .foregroundStyle(Theme.bg).padding(3).background(Theme.acid)
                                            .offset(x: 3, y: 3)
                                    }
                                Text(g.name).caps(8, Theme.text).lineLimit(1)
                                if store.guestNeedsJIT(g) { Tag(text: "jit", color: Theme.amber) }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: slots

    private var slots: some View {
        Panel(code: "02", title: "Slots") {
            VStack(spacing: 14) {
                ForEach(store.accounts) { a in
                    AccountMeters(account: a)
                }
            }
        }
    }
}

struct VialColumn: View {
    var app: AppRecord
    var iconURL: URL?
    var body: some View {
        VStack(spacing: 7) {
            if app.isSelf {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.acid.opacity(0.12))
                    Image(systemName: "syringe.fill").font(.system(size: 13)).foregroundStyle(Theme.acid)
                }
                .frame(width: 28, height: 28)
            } else {
                AppIconView(url: iconURL, name: app.name, size: 28)
            }
            Vial(fill: app.fill)
            Text(app.secondsLeft.readout).font(.readout(10)).foregroundStyle(Theme.level(app.fill))
            Text(app.isSelf ? "SELF" : app.name).caps(8).lineLimit(1).frame(width: 58)
        }
    }
}

struct ManifestRow: View {
    var index: Int
    var app: AppRecord
    var iconURL: URL?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Text(String(format: "%02d", index)).font(.readout(10)).foregroundStyle(Theme.faint)
                AppIconView(url: iconURL, name: app.name, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.head(18)).foregroundStyle(Theme.text).lineLimit(1).textCase(.uppercase)
                    Text("v\(app.version) · \(app.appIdCount) ID\(app.appIdCount == 1 ? "" : "s")")
                        .font(.label(10)).foregroundStyle(Theme.dim).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(app.secondsLeft.readout).font(.readout(14)).foregroundStyle(Theme.level(app.fill))
                    if !app.account.isEmpty {
                        Tag(text: String(app.account.split(separator: "@").first ?? "").prefix(10).description)
                    }
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.line)
                    Rectangle().fill(Theme.level(app.fill)).frame(width: g.size.width * app.fill)
                }
            }
            .frame(height: 2)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

struct AccountMeters: View {
    @Environment(AppStore.self) private var store
    var account: AccountInfo

    var body: some View {
        let ids = store.appIds[account.id]
        let max = Int(ids?.max ?? 10)
        let used = ids?.available.map { max - Int($0) } ?? 0
        let apps = store.appsOn(account.email)
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(account.firstName.isEmpty ? account.email : "\(account.firstName) \(account.lastName)")
                    .font(.head(16)).foregroundStyle(Theme.text)
                Spacer()
                Text(account.teamId).font(.readout(10)).foregroundStyle(Theme.faint)
            }
            HStack(spacing: 10) {
                Text("Apps").caps(9).frame(width: 34, alignment: .leading)
                SegmentMeter(total: 3, filled: apps, color: apps >= 3 ? Theme.amber : Theme.acid)
                Text("\(apps)/3").font(.readout(10)).foregroundStyle(Theme.dim).frame(width: 36, alignment: .trailing)
            }
            HStack(spacing: 10) {
                Text("IDs").caps(9).frame(width: 34, alignment: .leading)
                SegmentMeter(total: max, filled: used, color: used >= max ? Theme.red : Theme.acid)
                Text("\(used)/\(max)").font(.readout(10)).foregroundStyle(Theme.dim).frame(width: 36, alignment: .trailing)
            }
        }
    }
}

struct LinkBadge: View {
    @Environment(AppStore.self) private var store
    private var look: (Color, String, Bool) {
        switch store.link {
        case .ok: return (Theme.acid, "Link ok", false)
        case .checking: return (Theme.amber, "Probing", true)
        case .failed: return (Theme.red, "No link", true)
        case .unknown: return (Theme.faint, "Idle", false)
        }
    }

    var body: some View {
        let color = look.0
        let text = look.1
        let blink = look.2
        Button { Task { await store.checkLink() } } label: {
            HStack(spacing: 6) {
                Lamp(color: color, blinking: blink).id(text)
                Text(text).caps(9, color)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .overlay(Rectangle().stroke(color.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// First-run checklist.
struct SetupPanel: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let linkOK: Bool = { if case .ok = store.link { return true }; return false }()
        Panel(code: "!!", title: "Setup") {
            VStack(alignment: .leading, spacing: 10) {
                step(done: store.hasPairing, "Pairing file", "Run the Linux bootstrap, or import one in Lab → Link.")
                step(done: linkOK, "Loopback VPN", linkDetail)
                step(done: !store.accounts.isEmpty, "Apple account", "Add one in Lab → Accounts.")
            }
        }
    }

    private var linkDetail: String {
        if case .failed(let why) = store.link { return why }
        return "Turn on LocalDevVPN, then tap the link badge."
    }

    private func step(done: Bool, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .foregroundStyle(done ? Theme.acid : Theme.amber).font(.system(size: 15))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body(14)).foregroundStyle(Theme.text)
                if !done { Text(detail).font(.body(11)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}
