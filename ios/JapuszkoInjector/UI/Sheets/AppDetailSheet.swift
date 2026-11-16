import SwiftUI

struct AppDetailSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var app: AppRecord
    @State private var share: ShareItems?
    @State private var confirmUninstall = false
    @State private var confirmForget = false

    /// Latest copy from the store (the sheet keeps showing after a refresh).
    private var live: AppRecord { store.apps.first { $0.id == app.id } ?? app }

    var body: some View {
        let a = live
        SheetFrame(code: a.isSelf ? "00" : "VL", title: a.isSelf ? "Injector" : "Vial", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 20) {
                    Vial(fill: a.fill, width: 52, height: 190)
                    VStack(alignment: .leading, spacing: 10) {
                        if !a.isSelf { AppIconView(url: store.iconURL(a), name: a.name, size: 52) }
                        Text(a.name).font(.head(28)).foregroundStyle(Theme.text).textCase(.uppercase)
                            .lineLimit(2).minimumScaleFactor(0.6)
                        Text(a.secondsLeft.readout).font(.readout(26)).foregroundStyle(Theme.level(a.fill))
                        Text("expires \(Date(timeIntervalSince1970: TimeInterval(a.expiresAt)).stamp)").caps(9)
                    }
                }

                Panel(code: "01", title: "Spec") {
                    VStack(spacing: 8) {
                        row("Version", a.version)
                        row("Bundle", a.installedBundleId)
                        if a.id != a.installedBundleId && !a.isSelf { row("Source", a.id) }
                        row("Account", a.account.isEmpty ? "—" : a.account)
                        row("App IDs", "\(a.appIdCount)")
                        if a.sizeBytes > 0 { row("Size", a.sizeBytes.megabytes) }
                        if a.installedAt > 0 { row("Injected", Date(timeIntervalSince1970: TimeInterval(a.installedAt)).stamp) }
                        let tags = optionTags(a.options)
                        if !tags.isEmpty {
                            HStack { ForEach(tags, id: \.self) { Tag(text: $0, color: Theme.acid) }; Spacer() }
                        }
                    }
                }

                PlungerButton(label: a.isSelf ? "Hold to re-inject self" : "Hold to re-inject",
                              enabled: store.busy == nil,
                              progress: store.busy?.value,
                              stage: store.busy?.stage) {
                    Task { await store.refresh(a) }
                }

                if !a.isSelf {
                    VStack(spacing: 10) {
                        Button("Export cert + profile") {
                            Task {
                                if let r = await store.exportCert(a.account, password: nil, appId: a.id) {
                                    store.show(.info, "p12 password: \(r.password)")
                                    share = ShareItems(urls: r.files)
                                }
                            }
                        }
                        .buttonStyle(LabButtonStyle())
                        HStack(spacing: 10) {
                            Button("Uninstall") { confirmUninstall = true }
                                .buttonStyle(LabButtonStyle(kind: .danger))
                            Button("Forget") { confirmForget = true }
                                .buttonStyle(LabButtonStyle())
                        }
                    }
                    .disabled(store.busy != nil)
                }
            }
        }
        .sheet(item: $share) { s in ShareSheet(items: s.urls) }
        .confirmationDialog("Uninstall \(a.name) from this device?", isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) {
                Task { await store.remove(a, uninstall: true); dismiss() }
            }
        } message: { Text("Its data on the device is deleted too.") }
        .confirmationDialog("Forget \(a.name)?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                Task { await store.remove(a, uninstall: false); dismiss() }
            }
        } message: { Text("The app stays installed but JapuszkoInjector stops refreshing it.") }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).caps(9).frame(width: 70, alignment: .leading)
            Text(v).font(.readout(12)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private func optionTags(_ o: InstallOptions) -> [String] {
        var t: [String] = []
        if o.stripExtensions { t.append("no ext") }
        if o.increasedMemoryLimit { t.append("mem+") }
        if o.fileSharing { t.append("files") }
        if o.stripDeviceRestrictions { t.append("any device") }
        if o.customBundleId != nil { t.append("custom id") }
        return t
    }
}
