import SwiftUI

struct LogView: View {
    @Environment(AppStore.self) private var store
    @State private var filter: String? = nil
    @State private var share: ShareItems?

    private var lines: [LogLine] {
        guard let f = filter else { return store.logs }
        return store.logs.filter { $0.level == f || (f == "warn" && $0.level == "error") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("LOG").font(.head(44)).foregroundStyle(Theme.text)
                Spacer()
                Text("\(store.logs.count) lines").caps(9)
            }
            HStack(spacing: 8) {
                chip(nil, "All")
                chip("warn", "Problems")
                chip("info", "Info")
                Spacer()
                Button { exportLog() } label: { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(LabButtonStyle(compact: true))
                Button { store.logs.removeAll() } label: { Image(systemName: "trash") }
                    .buttonStyle(LabButtonStyle(kind: .danger, compact: true))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if lines.isEmpty {
                            Text("> idle").font(.readout(12)).foregroundStyle(Theme.faint)
                        }
                        ForEach(lines) { l in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(time(l.date)).font(.readout(10)).foregroundStyle(Theme.faint)
                                Text(l.message).font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(color(l.level))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(l.id)
                        }
                    }
                    .padding(12)
                }
                .background(Color.black.opacity(0.55))
                .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                .onChange(of: store.logs.count) { _, _ in
                    if let last = lines.last { withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 8)
        .sheet(item: $share) { s in ShareSheet(items: s.urls) }
    }

    private func chip(_ level: String?, _ title: String) -> some View {
        Button(title) { filter = level }
            .buttonStyle(LabButtonStyle(kind: filter == level ? .primary : .plain, compact: true))
    }

    private func color(_ level: String) -> Color {
        switch level {
        case "error": return Theme.red
        case "warn": return Theme.amber
        case "debug", "trace": return Theme.faint
        default: return Theme.text.opacity(0.85)
        }
    }

    private func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    private func exportLog() {
        let text = store.logs.map { "\(time($0.date)) [\($0.level)] \($0.message)" }.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("japuszkoinjector-log.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        share = ShareItems(urls: [url])
    }
}
