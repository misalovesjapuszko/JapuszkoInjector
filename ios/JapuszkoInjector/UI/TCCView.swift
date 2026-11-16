import SwiftUI
import SQLite3

/// TCC.db permission editor -- uses sandbox escape to read/write the TCC database.
struct TCCView: View {
    @State private var status: LoadStatus = .idle
    @State private var entries: [TCCEntry] = []
    @State private var searchText = ""
    @State private var sandboxHandle: Int64 = -1
    @State private var dbPath: String?
    @State private var showError: String?
    @State private var showSaveWarning = false
    @State private var pendingToggle: TCCEntry?

    private enum LoadStatus {
        case idle, scanning, loading, ready, error(String)
    }

    var body: some View {
        List {
            switch status {
            case .idle:
                Section {
                    Button { Task { await discover() } } label: {
                        Label("Scan for TCC Database", systemImage: "magnifyingglass")
                    }
                } footer: {
                    Text("Locates the TCC.db privacy database under SystemGroup containers.")
                }

            case .scanning:
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Scanning inodes\u{2026}")
                                .font(.subheadline.weight(.medium))
                            Text("Looking for TCC container")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

            case .loading:
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Reading TCC database\u{2026}")
                            .font(.subheadline)
                    }
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
                    Button("Retry") { Task { await discover() } }
                }

            case .ready:
                warningSection
                statsSection
                entriesSection
            }
        }
        .navigationTitle("TCC Manager")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Filter by app or service")
        .toolbar {
            if case .ready = status {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await reload() } } label: {
                        Image(systemName: "arrow.clockwise")
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
        .confirmationDialog(
            "Change Permission?",
            isPresented: $showSaveWarning,
            titleVisibility: .visible
        ) {
            Button("Allow", role: .none) {
                if let entry = pendingToggle {
                    togglePermission(entry, to: 2)
                }
            }
            Button("Deny") {
                if let entry = pendingToggle {
                    togglePermission(entry, to: 0)
                }
            }
            Button("Cancel", role: .cancel) { pendingToggle = nil }
        } message: {
            if let entry = pendingToggle {
                Text("Change \(entry.service) permission for \(entry.client)?\n\nModifying TCC.db directly can break app permissions or cause instability.")
            }
        }
        .onDisappear {
            if sandboxHandle >= 0 {
                SandboxEscape.releaseAccess(sandboxHandle)
                sandboxHandle = -1
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var warningSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Editing TCC.db directly bypasses system safeguards. Incorrect changes may break app permissions or require a device reset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var statsSection: some View {
        let services = Set(entries.map(\.service))
        let clients = Set(entries.map(\.client))
        Section("Overview") {
            LabeledContent("Total Entries", value: "\(entries.count)")
            LabeledContent("Unique Services", value: "\(services.count)")
            LabeledContent("Unique Apps", value: "\(clients.count)")
        }
    }

    @ViewBuilder
    private var entriesSection: some View {
        let visible = filteredEntries
        let grouped = Dictionary(grouping: visible, by: \.client)
        let sortedClients = grouped.keys.sorted()

        if sortedClients.isEmpty {
            Section {
                Text("No matching entries")
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(sortedClients, id: \.self) { client in
                Section(client) {
                    ForEach(grouped[client]!, id: \.id) { entry in
                        tccRow(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tccRow(_ entry: TCCEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(friendlyService(entry.service))
                    .font(.body.weight(.medium))
                Text(entry.service)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                pendingToggle = entry
                showSaveWarning = true
            } label: {
                Text(authLabel(entry.authValue))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(authColor(entry.authValue).opacity(0.15), in: Capsule())
                    .foregroundStyle(authColor(entry.authValue))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    private var filteredEntries: [TCCEntry] {
        guard !searchText.isEmpty else { return entries }
        return entries.filter {
            $0.client.localizedCaseInsensitiveContains(searchText) ||
            $0.service.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Display helpers

    private func authLabel(_ value: Int32) -> String {
        switch value {
        case 0: return "Denied"
        case 2: return "Allowed"
        case 3: return "Limited"
        default: return "auth=\(value)"
        }
    }

    private func authColor(_ value: Int32) -> Color {
        switch value {
        case 0: return .red
        case 2: return Color(hex: 0xB6FF3B)
        case 3: return .orange
        default: return .secondary
        }
    }

    private func friendlyService(_ service: String) -> String {
        let map: [String: String] = [
            "kTCCServicePhotos": "Photos",
            "kTCCServiceCamera": "Camera",
            "kTCCServiceMicrophone": "Microphone",
            "kTCCServiceAddressBook": "Contacts",
            "kTCCServiceCalendar": "Calendar",
            "kTCCServiceReminders": "Reminders",
            "kTCCServiceMotion": "Motion & Fitness",
            "kTCCServiceMediaLibrary": "Media Library",
            "kTCCServiceBluetoothAlways": "Bluetooth",
            "kTCCServiceWillow": "Home",
            "kTCCServiceFaceID": "Face ID",
            "kTCCServiceLocationAlways": "Location (Always)",
            "kTCCServiceLocationWhenInUse": "Location (In Use)",
            "kTCCServiceLiverpool": "Location (Significant Changes)",
            "kTCCServiceUbiquity": "iCloud",
            "kTCCServiceShareKit": "Share Sheet",
            "kTCCServicePhotosAdd": "Add to Photos",
            "kTCCServiceSpeechRecognition": "Speech Recognition",
            "kTCCServiceContactsFull": "Full Contacts Access",
            "kTCCServiceContactsLimited": "Limited Contacts Access",
        ]
        return map[service] ?? service
            .replacingOccurrences(of: "kTCCService", with: "")
    }

    // MARK: - Discovery

    private func discover() async {
        status = .scanning

        // Try multiple known container identifiers for TCC.db
        let possibleIdentifiers = [
            "systemgroup.com.apple.configurationprofiles",
            "systemgroup.com.apple.tcc",
        ]

        var foundContainer: String?
        for identifier in possibleIdentifiers {
            if let container = await Task.detached(operation: {
                SandboxEscape.findSystemGroupContainer(matching: identifier)
            }).value {
                foundContainer = container
                break
            }
        }

        guard let container = foundContainer else {
            status = .error("Could not find TCC container. The inode scan may need a higher ceiling.")
            return
        }

        let tccDb = container + "/Library/TCC/TCC.db"
        dbPath = tccDb
        status = .loading

        do {
            let handle = try await Task.detached {
                try SandboxEscape.acquireAccessAuto(to: container)
            }.value
            sandboxHandle = handle

            entries = readTCC(at: tccDb)
            status = .ready
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private func reload() async {
        guard let path = dbPath else { return }
        entries = readTCC(at: path)
    }

    // MARK: - SQLite operations

    private func readTCC(at path: String) -> [TCCEntry] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            showError = "Failed to open TCC.db: \(String(cString: sqlite3_errmsg(db)))"
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT service, client, client_type, auth_value, auth_reason, indirect_object_identifier FROM access ORDER BY client, service"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            showError = "Failed to query TCC.db: \(String(cString: sqlite3_errmsg(db)))"
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var results: [TCCEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let service = String(cString: sqlite3_column_text(stmt, 0))
            let client = String(cString: sqlite3_column_text(stmt, 1))
            let clientType = sqlite3_column_int(stmt, 2)
            let authValue = sqlite3_column_int(stmt, 3)
            let authReason = sqlite3_column_int(stmt, 4)
            let indirect = sqlite3_column_text(stmt, 5).map { String(cString: $0) }

            results.append(TCCEntry(
                service: service,
                client: client,
                clientType: clientType,
                authValue: authValue,
                authReason: authReason,
                indirectObject: indirect
            ))
        }
        return results
    }

    private func togglePermission(_ entry: TCCEntry, to newValue: Int32) {
        guard let path = dbPath else { return }
        pendingToggle = nil

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            showError = "Failed to open TCC.db for writing: \(String(cString: sqlite3_errmsg(db)))"
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "UPDATE access SET auth_value = ? WHERE service = ? AND client = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            showError = "Failed to prepare update: \(String(cString: sqlite3_errmsg(db)))"
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, newValue)
        sqlite3_bind_text(stmt, 2, entry.service, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 3, entry.client, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        if sqlite3_step(stmt) != SQLITE_DONE {
            showError = "Failed to update: \(String(cString: sqlite3_errmsg(db)))"
            return
        }

        // Update local state
        if let idx = entries.firstIndex(where: { $0.service == entry.service && $0.client == entry.client }) {
            entries[idx].authValue = newValue
        }
    }
}

// MARK: - Data model

struct TCCEntry: Identifiable, Sendable {
    nonisolated var id: String { "\(service)|\(client)" }
    let service: String
    let client: String
    let clientType: Int32
    var authValue: Int32
    let authReason: Int32
    let indirectObject: String?

    nonisolated init(service: String, client: String, clientType: Int32, authValue: Int32, authReason: Int32, indirectObject: String?) {
        self.service = service
        self.client = client
        self.clientType = clientType
        self.authValue = authValue
        self.authReason = authReason
        self.indirectObject = indirectObject
    }
}
