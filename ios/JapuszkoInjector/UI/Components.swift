import SwiftUI
import UniformTypeIdentifiers

struct AppIcon: View {
    var url: URL?
    var name: String
    var size: CGFloat = 48
    var systemImage: String? = nil
    var isSelf: Bool = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        Group {
            if let url, let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img).resizable().interpolation(.high)
            } else if isSelf, let img = Self.bundleIcon {
                Image(uiImage: img).resizable().interpolation(.high)
            } else if let systemImage {
                ZStack {
                    Color.accentColor.opacity(0.15)
                    Image(systemName: systemImage)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            } else {
                ZStack {
                    LinearGradient(colors: [Color(.systemGray3), Color(.systemGray)],
                                   startPoint: .top, endPoint: .bottom)
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private static let bundleIcon: UIImage? = {
        if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String],
           let name = files.last {
            return UIImage(named: name)
        }
        return UIImage(named: "AppIcon")
    }()
}

/// Colour for "time left" text.
func expiryColor(_ secondsLeft: TimeInterval) -> Color {
    if secondsLeft < 86400 { return .red }
    if secondsLeft < 2 * 86400 { return .orange }
    return .secondary
}

/// App Store style capsule button.
struct PillButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
    }
}

extension View {
    func pill() -> some View { modifier(PillButtonStyle()) }
}

/// Progress of the running job, used at the top of lists.
struct BusyRow: View {
    var busy: BusyState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(busy.title).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(busy.value * 100))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: busy.value)
            Text(busy.stage).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// Small "Done" style toast at the bottom.
struct ToastView: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .padding(.horizontal, 24)
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

extension Date {
    var short: String { formatted(date: .abbreviated, time: .shortened) }
}
