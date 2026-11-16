import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var tab = 0

    var body: some View {
        @Bindable var store = store
        TabView(selection: $tab) {
            AppsView()
                .tabItem { Label("Apps", systemImage: "square.stack.3d.up.fill") }
                .tag(0)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(1)
        }
        .overlay(alignment: .bottom) {
            if let b = store.banner {
                ToastView(text: b.text)
                    .padding(.bottom, 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { store.banner = nil }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.banner)
        .promptHost()
        .sheet(item: $store.pendingInstall) { p in
            InstallSheet(file: p.url).modalLevel()
        }
        .onOpenURL { open($0) }
        .onChange(of: phase) { _, new in
            guard new == .active else { return }
            store.reloadLocal()
            Task {
                await store.checkLink()
                if case .ok = store.link { await store.refreshDue(includeSelf: true) }
            }
        }
    }

    /// Files opened in the app, and japuszkoinjector://install?url=… links.
    private func open(_ url: URL) {
        if url.isFileURL {
            let ext = url.pathExtension.lowercased()
            if ext == "ipa" || ext == "zip" {
                if let staged = store.stage(url) {
                    tab = 0
                    store.pendingInstall = PendingInstall(url: staged)
                }
            } else if ext == "plist" || ext == "mobiledevicepairing" {
                store.importPairing(url)
                tab = 1
            }
            return
        }
        guard url.scheme == "japuszkoinjector",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        if url.host == "install",
           let s = comps.queryItems?.first(where: { $0.name == "url" })?.value,
           let remote = URL(string: s) {
            tab = 0
            Task {
                if let local = await store.download(remote) {
                    store.pendingInstall = PendingInstall(url: local)
                }
            }
        } else if url.host == "refresh" {
            Task { _ = await store.refreshAll(force: false, includeSelf: true) }
        }
    }
}
