import SwiftUI
import SQLite3

/// Browse other apps' container data via sandbox escape.
struct AppDataView: View {
    @State private var status: LoadStatus = .idle
    @State private var containers: [AppContainer] = []
    @State private var searchText = ""

    private enum LoadStatus {
        case idle, scanning, ready, error(String)
    }

    var body: some View {
        List {
            switch status {
            case .idle:
                Section {
                    Button { Task { await scan() } } label: {
                        Label("Scan App Containers", systemImage: "magnifyingglass")
                    }
                } footer: {
                    Text("Enumerates app containers under /var/mobile/Containers/Data/Application/ by brute-forcing inodes.")
                }

            case .scanning:
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Scanning inodes\u{2026}")
                                .font(.subheadline.weight(.medium))
                            Text("This can take a minute")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

            case .error(let msg):
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Error", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Button("Retry") { Task { await scan() } }
                }

            case .ready:
                let visible = filteredContainers
                Section {
                    Text("\(containers.count) containers found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(visible) { container in
                    NavigationLink {
                        AppContainerBrowser(container: container)
                    } label: {
                        containerRow(container)
                    }
                }
            }
        }
        .navigationTitle("App Data")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Filter by name or bundle ID")
        .toolbar {
            if case .ready = status {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await scan() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func containerRow(_ container: AppContainer) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(container.displayName)
                .font(.body.weight(.medium))
                .lineLimit(1)
            if !container.bundleId.isEmpty {
                Text(container.bundleId)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(container.uuid)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var filteredContainers: [AppContainer] {
        guard !searchText.isEmpty else { return containers }
        return containers.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.bundleId.localizedCaseInsensitiveContains(searchText) ||
            $0.uuid.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Scanning

    private func scan() async {
        status = .scanning

        let results: [AppContainer] = await Task.detached {
            let basePath = "/var/mobile/Containers/Data/Application"
            let ceiling = SandboxEscape.defaultMaxInode

            var children = SandboxEscape.enumerateChildren(of: basePath, maxInode: ceiling)

            // If enumeration returned nothing, try with a sandbox extension.
            if children.isEmpty {
                if let handle = try? SandboxEscape.acquireAccessAuto(to: basePath) {
                    children = SandboxEscape.enumerateChildren(of: basePath, maxInode: ceiling)
                    SandboxEscape.releaseAccess(handle)
                }
            }

            return children.compactMap { path -> AppContainer? in
                let uuid = (path as NSString).lastPathComponent
                let metaPath = path + "/.com.apple.mobile_container_manager.metadata.plist"
                var bundleId = ""
                var displayName = uuid
                if let data = try? Data(contentsOf: URL(fileURLWithPath: metaPath)),
                   let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    if let bid = plist["MCMMetadataIdentifier"] as? String {
                        bundleId = bid
                        displayName = bid.components(separatedBy: ".").last ?? bid
                    }
                }
                return AppContainer(path: path, uuid: uuid, bundleId: bundleId, displayName: displayName)
            }.sorted { a, b in
                a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            }
        }.value

        containers = results
        status = results.isEmpty ? .error("No containers found. Check that worse_query works on this iOS version and that the app group entitlement is correct.") : .ready
    }
}

// MARK: - Container model

struct AppContainer: Identifiable, Sendable {
    nonisolated var id: String { path }
    let path: String
    let uuid: String
    let bundleId: String
    let displayName: String

    nonisolated init(path: String, uuid: String, bundleId: String, displayName: String) {
        self.path = path
        self.uuid = uuid
        self.bundleId = bundleId
        self.displayName = displayName
    }
}

// MARK: - Container file browser

struct AppContainerBrowser: View {
    let container: AppContainer
    @State private var sandboxHandle: Int64 = -1
    @State private var status: BrowserStatus = .acquiring
    @State private var items: [BrowserItem] = []
    @State private var currentPath: String = ""
    @State private var pathStack: [String] = []
    @State private var searchText = ""
    @State private var selectedDB: String?
    @State private var showError: String?

    private enum BrowserStatus {
        case acquiring, ready, error(String)
    }

    var body: some View {
        Group {
            switch status {
            case .acquiring:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Acquiring sandbox access\u{2026}")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

            case .error(let msg):
                VStack(spacing: 12) {
                    Image(systemName: "xmark.octagon.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

            case .ready:
                fileList
            }
        }
        .navigationTitle(container.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search files")
        .sheet(item: Binding(
            get: { selectedDB.map { DBViewerID(path: $0) } },
            set: { selectedDB = $0?.path }
        )) { dbId in
            NavigationStack {
                SQLiteViewer(path: dbId.path)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { selectedDB = nil }
                        }
                    }
            }
        }
        .alert("Error", isPresented: Binding(
            get: { showError != nil },
            set: { if !$0 { showError = nil } }
        )) {
            Button("OK") { showError = nil }
        } message: {
            Text(showError ?? "")
        }
        .task { await acquire() }
        .onDisappear {
            if sandboxHandle >= 0 {
                SandboxEscape.releaseAccess(sandboxHandle)
                sandboxHandle = -1
            }
        }
    }

    @ViewBuilder
    private var fileList: some View {
        List {
            if !pathStack.isEmpty {
                Section {
                    Text(currentPath.replacingOccurrences(of: container.path, with: "~"))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            let visible = filteredItems
            if visible.isEmpty {
                Section {
                    Text(searchText.isEmpty ? "Empty directory" : "No results")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(visible) { item in
                    fileRow(item)
                }
            }
        }
    }

    @ViewBuilder
    private func fileRow(_ item: BrowserItem) -> some View {
        Button {
            if item.isDirectory {
                pathStack.append(currentPath)
                currentPath = item.path
                loadDirectory()
            } else if item.name.hasSuffix(".db") || item.name.hasSuffix(".sqlite") || item.name.hasSuffix(".sqlite3") || item.name.hasSuffix(".sqlitedb") {
                selectedDB = item.path
            } else if item.name.hasSuffix(".plist") {
                // We could add a plist viewer here
            }
        } label: {
            HStack {
                Image(systemName: item.icon)
                    .foregroundStyle(item.iconColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.body)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        if let size = item.size {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        }
                        if let date = item.modified {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }

                Spacer()

                if item.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .foregroundStyle(.primary)
    }

    private var filteredItems: [BrowserItem] {
        guard !searchText.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    // MARK: - Logic

    private func acquire() async {
        status = .acquiring
        do {
            let handle = try await Task.detached {
                try SandboxEscape.acquireAccessAuto(to: container.path)
            }.value
            sandboxHandle = handle
            currentPath = container.path
            loadDirectory()
            status = .ready
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private func loadDirectory() {
        let fm = FileManager.default
        do {
            let urls = try fm.contentsOfDirectory(
                at: URL(fileURLWithPath: currentPath),
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            items = urls.compactMap { url -> BrowserItem? in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let isDir = values?.isDirectory ?? false
                return BrowserItem(
                    path: url.path,
                    name: url.lastPathComponent,
                    isDirectory: isDir,
                    size: isDir ? nil : (values?.fileSize),
                    modified: values?.contentModificationDate
                )
            }.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        } catch {
            showError = error.localizedDescription
            items = []
        }
    }
}

// MARK: - Browser item model

struct BrowserItem: Identifiable, Sendable {
    nonisolated var id: String { path }
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int?
    let modified: Date?

    var icon: String {
        if isDirectory { return "folder.fill" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "plist": return "doc.text"
        case "db", "sqlite", "sqlite3", "sqlitedb": return "cylinder"
        case "json": return "curlybraces"
        case "png", "jpg", "jpeg", "heic": return "photo"
        default: return "doc"
        }
    }

    var iconColor: Color {
        if isDirectory { return .cyan }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "plist": return .orange
        case "db", "sqlite", "sqlite3", "sqlitedb": return Color(hex: 0xB6FF3B)
        case "json": return .yellow
        default: return .secondary
        }
    }
}

// MARK: - Identifiable wrapper for sheet binding

private struct DBViewerID: Identifiable {
    var id: String { path }
    let path: String
}

// MARK: - SQLite viewer

struct SQLiteViewer: View {
    let path: String
    @State private var tables: [SQLiteTable] = []
    @State private var showError: String?

    var body: some View {
        List {
            Section {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            } header: {
                Text("Database")
            }

            if tables.isEmpty {
                Section {
                    Text("No tables found or could not read database")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Tables") {
                    ForEach(tables) { table in
                        HStack {
                            Image(systemName: "tablecells")
                                .foregroundStyle(Color(hex: 0xB6FF3B))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(table.name)
                                    .font(.system(.body, design: .monospaced))
                                Text("\(table.rowCount) rows, \(table.columnCount) columns")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("SQLite Viewer")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .alert("Error", isPresented: Binding(
            get: { showError != nil },
            set: { if !$0 { showError = nil } }
        )) {
            Button("OK") { showError = nil }
        } message: {
            Text(showError ?? "")
        }
    }

    private func load() {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            showError = "Failed to open database"
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }

        // Get table names
        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var result: [SQLiteTable] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 0))

            // Get row count
            var countStmt: OpaquePointer?
            let countSQL = "SELECT COUNT(*) FROM \"\(name)\""
            var rowCount = 0
            if sqlite3_prepare_v2(db, countSQL, -1, &countStmt, nil) == SQLITE_OK {
                if sqlite3_step(countStmt) == SQLITE_ROW {
                    rowCount = Int(sqlite3_column_int64(countStmt, 0))
                }
                sqlite3_finalize(countStmt)
            }

            // Get column count
            var infoStmt: OpaquePointer?
            let infoSQL = "PRAGMA table_info(\"\(name)\")"
            var colCount = 0
            if sqlite3_prepare_v2(db, infoSQL, -1, &infoStmt, nil) == SQLITE_OK {
                while sqlite3_step(infoStmt) == SQLITE_ROW {
                    colCount += 1
                }
                sqlite3_finalize(infoStmt)
            }

            result.append(SQLiteTable(name: name, rowCount: rowCount, columnCount: colCount))
        }
        tables = result
    }
}

struct SQLiteTable: Identifiable, Sendable {
    nonisolated var id: String { name }
    let name: String
    let rowCount: Int
    let columnCount: Int
}
