import SwiftUI

/// MobileGestalt plist editor -- reads/writes CacheExtra entries via sandbox escape.
struct GestaltView: View {
    @State private var status: LoadStatus = .idle
    @State private var containerPath: String?
    @State private var plistPath: String?
    @State private var cacheExtra: [String: Any] = [:]
    @State private var fullPlist: [String: Any] = [:]
    @State private var searchText = ""
    @State private var sandboxHandle: Int64 = -1
    @State private var showSaveConfirm = false
    @State private var showError: String?
    @State private var modified = false

    private enum LoadStatus {
        case idle, scanning, loading, ready, error(String)
    }

    // Known quick-toggle keys
    private static let quickToggles: [(key: String, label: String)] = [
        ("cGkISOgzSEaFHxTbCfOJcA", "Always On Display"),
        ("HCzWusHQwZDea6nNhaKndw", "Camera Control"),
        ("nVh/gwNpy7Jv1NOk00CMrw", "Charge Limit"),
        ("qeaj75wk3HF4DwQ8qbIi7g", "Crash Detection"),
        ("YlEtNHlZcm90Rm5Ackhj", "Stage Manager"),
        ("A62OafQ85EJAiiqKn4agtg", "Apple Intelligence"),
    ]

    var body: some View {
        List {
            switch status {
            case .idle:
                Section {
                    Button { Task { await discover() } } label: {
                        Label("Scan for MobileGestalt Cache", systemImage: "magnifyingglass")
                    }
                }

            case .scanning:
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Scanning inodes\u{2026}")
                                .font(.subheadline.weight(.medium))
                            Text("Enumerating SystemGroup containers")
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
                        Text("Acquiring sandbox access\u{2026}")
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
                quickTogglesSection
                rawEditorSection
            }
        }
        .navigationTitle("MobileGestalt")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Filter CacheExtra keys")
        .toolbar {
            if case .ready = status, modified {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { showSaveConfirm = true }
                        .bold()
                        .foregroundStyle(Color(hex: 0xB6FF3B))
                }
            }
        }
        .confirmationDialog(
            "Save MobileGestalt Changes?",
            isPresented: $showSaveConfirm,
            titleVisibility: .visible
        ) {
            Button("Save", role: .destructive) { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This writes directly to the MobileGestalt cache. A reboot is usually needed for changes to take effect. Incorrect values could cause instability.")
        }
        .alert("Error", isPresented: Binding(
            get: { showError != nil },
            set: { if !$0 { showError = nil } }
        )) {
            Button("OK") { showError = nil }
        } message: {
            Text(showError ?? "")
        }
        .onDisappear {
            if sandboxHandle >= 0 {
                SandboxEscape.releaseAccess(sandboxHandle)
                sandboxHandle = -1
            }
        }
    }

    // MARK: - Quick Toggles

    @ViewBuilder
    private var quickTogglesSection: some View {
        Section {
            ForEach(Self.quickToggles, id: \.key) { toggle in
                quickToggleRow(key: toggle.key, label: toggle.label)
            }
        } header: {
            Text("Quick Toggles")
        } footer: {
            Text("Toggle known feature flags. Changes are written when you tap Save.")
        }
    }

    @ViewBuilder
    private func quickToggleRow(key: String, label: String) -> some View {
        let currentValue = cacheExtra[key]
        let isOn = (currentValue as? Bool) ?? (currentValue as? NSNumber)?.boolValue ?? false

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.body.weight(.medium))
                Text(key)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { newValue in
                    cacheExtra[key] = newValue
                    modified = true
                }
            ))
            .tint(Color(hex: 0xB6FF3B))
        }
    }

    // MARK: - Raw Editor

    @ViewBuilder
    private var rawEditorSection: some View {
        let keys = filteredKeys
        Section {
            if keys.isEmpty {
                Text("No matching keys")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(keys, id: \.self) { key in
                    NavigationLink {
                        GestaltValueEditor(
                            key: key,
                            cacheExtra: $cacheExtra,
                            modified: $modified
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                            Text(describeValue(cacheExtra[key]))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        } header: {
            Text("Raw Editor (\(cacheExtra.count) keys)")
        }
    }

    private var filteredKeys: [String] {
        let sorted = cacheExtra.keys.sorted()
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    private func describeValue(_ value: Any?) -> String {
        switch value {
        case let b as Bool: return b ? "true" : "false"
        case let n as NSNumber: return n.stringValue
        case let s as String: return s
        case let d as Data: return "\(d.count) bytes"
        case let a as [Any]: return "Array (\(a.count) items)"
        case let dict as [String: Any]: return "Dict (\(dict.count) keys)"
        case nil: return "nil"
        default: return String(describing: value!)
        }
    }

    // MARK: - Discovery & Loading

    private func discover() async {
        status = .scanning

        let container: String? = await Task.detached {
            SandboxEscape.findSystemGroupContainer(
                matching: "systemgroup.com.apple.mobilegestaltcache"
            )
        }.value

        guard let container else {
            status = .error("Could not find MobileGestalt container. Check that worse_query works on this iOS version and that the app group entitlement is correct.")
            return
        }

        containerPath = container
        let gestaltPlist = container + "/Library/Caches/com.apple.MobileGestalt.plist"
        plistPath = gestaltPlist
        status = .loading

        do {
            // Acquire sandbox access to the container root.
            let handle = try await Task.detached {
                try SandboxEscape.acquireAccessAuto(to: container)
            }.value
            sandboxHandle = handle

            // On iOS 27.0.1 we may also need access to the specific Caches
            // subdirectory if the container extension doesn't cover it.
            let cachesDir = container + "/Library/Caches"
            if !FileManager.default.isReadableFile(atPath: gestaltPlist) {
                if let subHandle = try? SandboxEscape.acquireAccessAuto(to: cachesDir) {
                    // Keep this alive -- releasing happens in onDisappear via
                    // the main sandboxHandle. We intentionally leak this sub-
                    // handle; it's released when the process exits, and the
                    // only alternative (tracking multiple handles) adds
                    // complexity for no user-visible benefit.
                    _ = subHandle
                }
            }

            let data = try Data(contentsOf: URL(fileURLWithPath: gestaltPlist))
            guard let plist = try PropertyListSerialization.propertyList(
                from: data, options: .mutableContainersAndLeaves, format: nil
            ) as? [String: Any] else {
                status = .error("MobileGestalt plist is not a dictionary")
                return
            }

            fullPlist = plist
            cacheExtra = (plist["CacheExtra"] as? [String: Any]) ?? [:]
            modified = false
            status = .ready
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    // MARK: - Save

    private func save() {
        guard let path = plistPath else { return }
        var plist = fullPlist
        plist["CacheExtra"] = cacheExtra

        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .binary,
                options: 0
            )
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            modified = false
        } catch {
            showError = error.localizedDescription
        }
    }
}

// MARK: - Value editor sub-view

struct GestaltValueEditor: View {
    let key: String
    @Binding var cacheExtra: [String: Any]
    @Binding var modified: Bool

    @State private var editText = ""
    @State private var valueType: ValueType = .string

    private enum ValueType: String, CaseIterable {
        case bool = "Bool"
        case integer = "Integer"
        case float = "Float"
        case string = "String"
        case data = "Data (hex)"
    }

    var body: some View {
        Form {
            Section("Key") {
                Text(key)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            Section("Current Value") {
                Text(describe(cacheExtra[key]))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("Edit") {
                Picker("Type", selection: $valueType) {
                    ForEach(ValueType.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Value", text: $editText)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button("Apply") { apply() }
                    .bold()
                    .foregroundStyle(Color(hex: 0xB6FF3B))

                Button("Delete Key", role: .destructive) {
                    cacheExtra.removeValue(forKey: key)
                    modified = true
                }
            }
        }
        .navigationTitle("Edit Value")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadCurrent() }
    }

    private func loadCurrent() {
        let value = cacheExtra[key]
        switch value {
        case let b as Bool:
            valueType = .bool
            editText = b ? "true" : "false"
        case let n as NSNumber:
            if CFNumberIsFloatType(n) {
                valueType = .float
                editText = n.stringValue
            } else {
                valueType = .integer
                editText = n.stringValue
            }
        case let s as String:
            valueType = .string
            editText = s
        case let d as Data:
            valueType = .data
            editText = d.map { String(format: "%02x", $0) }.joined()
        default:
            valueType = .string
            editText = value.map { String(describing: $0) } ?? ""
        }
    }

    private func apply() {
        switch valueType {
        case .bool:
            let v = editText.lowercased()
            cacheExtra[key] = (v == "true" || v == "1" || v == "yes")
        case .integer:
            cacheExtra[key] = Int(editText) ?? 0
        case .float:
            cacheExtra[key] = Double(editText) ?? 0.0
        case .string:
            cacheExtra[key] = editText
        case .data:
            let hex = editText.filter { $0.isHexDigit }
            var bytes: [UInt8] = []
            var i = hex.startIndex
            while i < hex.endIndex {
                let next = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
                if let byte = UInt8(hex[i..<next], radix: 16) {
                    bytes.append(byte)
                }
                i = next
            }
            cacheExtra[key] = Data(bytes)
        }
        modified = true
    }

    private func describe(_ value: Any?) -> String {
        switch value {
        case let b as Bool: return b ? "true (Bool)" : "false (Bool)"
        case let n as NSNumber:
            if CFNumberIsFloatType(n) { return "\(n.stringValue) (Float)" }
            return "\(n.stringValue) (Integer)"
        case let s as String: return "\"\(s)\" (String)"
        case let d as Data: return "\(d.count) bytes (Data)"
        case let a as [Any]: return "Array (\(a.count) items)"
        case let dict as [String: Any]: return "Dict (\(dict.count) keys)"
        case nil: return "nil"
        default: return String(describing: value!)
        }
    }
}
