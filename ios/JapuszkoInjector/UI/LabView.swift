import SwiftUI

/// The "Lab" tab -- hub for sandbox escape tools.
struct LabView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title3)
                            .foregroundStyle(.orange)
                        Text("These tools use the worse_query sandbox escape. Editing system files can brick your device. Proceed with caution.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("System") {
                    NavigationLink {
                        GestaltView()
                    } label: {
                        LabRow(
                            icon: "cpu",
                            title: "MobileGestalt",
                            subtitle: "Feature flags and device spoofing",
                            color: Color(hex: 0xB6FF3B)
                        )
                    }

                    NavigationLink {
                        TCCView()
                    } label: {
                        LabRow(
                            icon: "lock.shield",
                            title: "TCC Manager",
                            subtitle: "App privacy permissions database",
                            color: .orange
                        )
                    }
                }

                Section("Containers") {
                    NavigationLink {
                        AppDataView()
                    } label: {
                        LabRow(
                            icon: "externaldrive",
                            title: "App Data Browser",
                            subtitle: "Browse other apps' sandboxed data",
                            color: .cyan
                        )
                    }
                }

                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("iOS 26.0 \u{2013} 26.7.2 / 27.2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Compatibility")
                } footer: {
                    Text("worse_query by forcequit (GPLv3). Requires the App Group entitlement to be properly signed.")
                }
            }
            .navigationTitle("Lab")
        }
    }
}

// MARK: - Lab row component

private struct LabRow: View {
    var icon: String
    var title: String
    var subtitle: String
    var color: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Hex color helper

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}
