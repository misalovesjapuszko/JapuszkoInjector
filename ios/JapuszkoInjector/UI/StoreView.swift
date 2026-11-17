import SwiftUI

struct StoreView: View {
    @Environment(AppStore.self) private var appStore
    @State private var sourceStore = SourceStore.shared
    @State private var askURL = false
    @State private var urlText = ""
    @State private var downloading: String?

    private let acid = Color(hex: 0xB6FF3B)

    var body: some View {
        NavigationStack {
            List {
                if sourceStore.loading {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("FETCHING SOURCE DATA...")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let err = sourceStore.error {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                if sourceStore.sources.isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "flask")
                                .font(.system(size: 36))
                                .foregroundStyle(acid.opacity(0.5))
                            Text("NO SOURCES CONFIGURED")
                                .font(.caption.monospaced().weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("Tap + to add a source URL.\nSources use the AltStore/SideStore JSON format.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                }
                ForEach(sourceStore.sources) { source in
                    Section {
                        ForEach(source.apps) { app in
                            StoreAppRow(app: app,
                                        downloading: downloading == app.id,
                                        onInstall: { downloadApp(app) })
                        }
                    } header: {
                        HStack {
                            Text("[ \(source.name.uppercased()) ]")
                                .font(.caption.monospaced().weight(.semibold))
                            Spacer()
                            Text("\(source.apps.count) app\(source.apps.count == 1 ? "" : "s")")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !sourceStore.sources.isEmpty {
                    Section {
                        ForEach(sourceStore.sources) { source in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.name)
                                        .font(.subheadline)
                                    Text(source.sourceURL)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Button {
                                    Task { await sourceStore.refreshSource(id: source.id) }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("Remove", role: .destructive) {
                                    sourceStore.removeSource(id: source.id)
                                }
                            }
                        }
                    } header: {
                        Text("[ SOURCES ]")
                            .font(.caption.monospaced().weight(.semibold))
                    } footer: {
                        Text("Swipe to remove a source. Apps use the AltStore/SideStore JSON format.")
                    }
                }
            }
            .navigationTitle("Store")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await sourceStore.refreshSources() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(sourceStore.sources.isEmpty || sourceStore.loading)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { askURL = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("Add Source", isPresented: $askURL) {
                TextField("https://example.com/source.json", text: $urlText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add") {
                    let url = urlText
                    urlText = ""
                    Task { await sourceStore.addSource(url: url) }
                }
                Button("Cancel", role: .cancel) { urlText = "" }
            } message: {
                Text("Enter the URL of an AltStore/SideStore-format source JSON.")
            }
            .refreshable {
                await sourceStore.refreshSources()
            }
        }
    }

    private func downloadApp(_ app: SourceApp) {
        guard let url = URL(string: app.downloadURL) else { return }
        downloading = app.id
        Task {
            defer { downloading = nil }
            if let local = await appStore.download(url) {
                appStore.pendingInstall = PendingInstall(url: local)
            }
        }
    }
}

private struct StoreAppRow: View {
    var app: SourceApp
    var downloading: Bool
    var onInstall: () -> Void

    private let acid = Color(hex: 0xB6FF3B)

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: app.iconURL.flatMap { URL(string: $0) }) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().interpolation(.high)
                case .failure:
                    fallbackIcon
                default:
                    fallbackIcon
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 48 * 0.225, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 48 * 0.225, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let dev = app.developerName {
                        Text(dev)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text("v\(app.version)")
                        .font(.caption.monospaced())
                        .foregroundStyle(acid.opacity(0.7))
                }
                if let desc = app.localizedDescription {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let size = app.size {
                    Text(size.megabytes)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if downloading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Install", action: onInstall)
                    .pill()
            }
        }
        .padding(.vertical, 4)
    }

    private var fallbackIcon: some View {
        ZStack {
            LinearGradient(colors: [Color(.systemGray3), Color(.systemGray)],
                           startPoint: .top, endPoint: .bottom)
            Text(String(app.name.prefix(1)).uppercased())
                .font(.system(size: 48 * 0.45, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}
