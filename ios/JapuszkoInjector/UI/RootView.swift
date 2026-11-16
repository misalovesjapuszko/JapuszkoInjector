import SwiftUI
import UniformTypeIdentifiers

enum LabTab: String, CaseIterable {
    case rack, dose, lab, log

    var title: String {
        switch self {
        case .rack: return "Rack"
        case .dose: return "Dose"
        case .lab: return "Lab"
        case .log: return "Log"
        }
    }
    var icon: String {
        switch self {
        case .rack: return "testtube.2"
        case .dose: return "syringe"
        case .lab: return "slider.vertical.3"
        case .log: return "terminal"
        }
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var tab: LabTab = .rack
    @State private var incoming: URL?

    var body: some View {
        @Bindable var store = store
        ZStack(alignment: .bottom) {
            GridBackground()

            Group {
                switch tab {
                case .rack: RackView(goDose: { tab = .dose })
                case .dose: DoseView(incoming: $incoming)
                case .lab: LabView()
                case .log: LogView()
                }
            }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: store.busy != nil && tab != .dose ? 104 : 60) }

            VStack(spacing: 0) {
                if let busy = store.busy, tab != .dose {
                    BusyStrip(busy: busy)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                LabTabBar(tab: $tab)
            }
            .animation(.easeOut(duration: 0.2), value: store.busy)
        }
        .overlay(alignment: .top) { BannerView() }
        .sheet(item: $store.twoFactor) { p in TwoFactorSheet(prompt: p).interactiveDismissDisabled() }
        .sheet(item: $store.appIdLimit) { p in AppIdLimitSheet(prompt: p).interactiveDismissDisabled() }
        .sheet(item: $store.maxCerts) { p in MaxCertsSheet(prompt: p).interactiveDismissDisabled() }
        .sheet(item: $store.slotsFull) { p in SlotsFullSheet(prompt: p).interactiveDismissDisabled() }
        .onChange(of: store.suggestRunInside) { _, on in if on { tab = .dose } }
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

    /// Files opened "in" the app and japuszkoinjector://install?url=… links.
    private func open(_ url: URL) {
        if url.isFileURL {
            let ext = url.pathExtension.lowercased()
            if ext == "ipa" || ext == "zip" {
                if let staged = store.stage(url) { incoming = staged; tab = .dose }
            } else if ext == "plist" || ext == "mobiledevicepairing" {
                store.importPairing(url)
                tab = .lab
            }
            return
        }
        guard url.scheme == "japuszkoinjector",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        if url.host == "install",
           let s = comps.queryItems?.first(where: { $0.name == "url" })?.value,
           let remote = URL(string: s) {
            tab = .dose
            Task { if let local = await store.download(remote) { incoming = local } }
        } else if url.host == "refresh" {
            Task { _ = await store.refreshAll(force: false, includeSelf: true) }
        }
    }
}

struct LabTabBar: View {
    @Binding var tab: LabTab
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(LabTab.allCases, id: \.self) { t in
                Button {
                    guard t != tab else { return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { tab = t }
                } label: {
                    VStack(spacing: 5) {
                        ZStack {
                            if t == tab {
                                Rectangle().fill(Theme.acid).frame(height: 2)
                                    .matchedGeometryEffect(id: "bar", in: ns)
                                    .shadow(color: Theme.acid, radius: 6)
                            } else {
                                Rectangle().fill(.clear).frame(height: 2)
                            }
                        }
                        Image(systemName: t.icon)
                            .font(.system(size: 17, weight: t == tab ? .semibold : .regular))
                            .frame(height: 20)
                        Text(t.title).caps(9, t == tab ? Theme.acid : Theme.dim)
                    }
                    .foregroundStyle(t == tab ? Theme.acid : Theme.dim)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .background(Theme.panel.ignoresSafeArea(edges: .bottom))
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .top)
    }
}

struct BusyStrip: View {
    var busy: BusyState
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Lamp(color: Theme.acid, blinking: true)
                Text(busy.title).caps(10, Theme.text)
                Text("·").foregroundStyle(Theme.faint)
                Text(busy.stage).caps(10)
                Spacer()
                Text("\(Int(busy.value * 100))%").font(.readout(11)).foregroundStyle(Theme.acid)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.line)
                    Rectangle().fill(Theme.acid).frame(width: g.size.width * busy.value)
                        .shadow(color: Theme.acid, radius: 4)
                }
            }
            .frame(height: 3)
            .animation(.easeOut(duration: 0.3), value: busy.value)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Theme.panelHi)
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .top)
    }
}

struct BannerView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        if let b = store.banner {
            let color: Color = b.kind == .good ? Theme.acid : (b.kind == .bad ? Theme.red : Theme.amber)
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(color).frame(width: 3)
                Text(b.text).font(.label(12)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10).padding(.trailing, 10)
            .background(Theme.panelHi)
            .overlay(Rectangle().stroke(color.opacity(0.5), lineWidth: 1))
            .padding(.horizontal, 12).padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onTapGesture { withAnimation { store.banner = nil } }
            .id(b.id)
        }
    }
}

/// UIActivityViewController for exported files.
struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ShareItems: Identifiable {
    let id = UUID()
    var urls: [URL]
}

extension UTType {
    static let ipa = UTType(filenameExtension: "ipa", conformingTo: .zip) ?? .zip
}
