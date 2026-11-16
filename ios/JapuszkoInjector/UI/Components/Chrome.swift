import SwiftUI

/// Faint measurement grid behind everything.
struct GridBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 22
            var minor = Path()
            var x: CGFloat = 0
            while x < size.width { minor.move(to: CGPoint(x: x, y: 0)); minor.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y: CGFloat = 0
            while y < size.height { minor.move(to: CGPoint(x: 0, y: y)); minor.addLine(to: CGPoint(x: size.width, y: y)); y += step }
            ctx.stroke(minor, with: .color(Color.white.opacity(0.025)), lineWidth: 0.5)

            var major = Path()
            x = 0
            while x < size.width { major.move(to: CGPoint(x: x, y: 0)); major.addLine(to: CGPoint(x: x, y: size.height)); x += step * 5 }
            y = 0
            while y < size.height { major.move(to: CGPoint(x: 0, y: y)); major.addLine(to: CGPoint(x: size.width, y: y)); y += step * 5 }
            ctx.stroke(major, with: .color(Color.white.opacity(0.045)), lineWidth: 0.5)
        }
        .background(Theme.bg)
        .ignoresSafeArea()
    }
}

/// L-shaped marks on each corner, like a viewfinder.
struct CornerBrackets: Shape {
    var length: CGFloat = 8
    func path(in r: CGRect) -> Path {
        var p = Path()
        let l = length
        p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - l, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - l)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))
        p.move(to: CGPoint(x: r.minX + l, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - l))
        return p
    }
}

/// A titled instrument panel. `code` is the little index tag ("01").
struct Panel<Content: View, Accessory: View>: View {
    var code: String
    var title: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(code).font(.label(9)).foregroundStyle(Theme.bg)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Theme.dim)
                Text(title).caps(10, Theme.text)
                Rectangle().fill(Theme.line).frame(height: 1)
                accessory()
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            content()
                .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .background(Theme.panel)
        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
        .overlay(CornerBrackets().stroke(Theme.lineHi, lineWidth: 1.5).padding(-1))
    }
}

extension Panel where Accessory == EmptyView {
    init(code: String, title: String, @ViewBuilder content: @escaping () -> Content) {
        self.code = code
        self.title = title
        self.accessory = { EmptyView() }
        self.content = content
    }
}

/// LED-style segmented meter, e.g. app IDs used this week.
struct SegmentMeter: View {
    var total: Int
    var filled: Int
    var color: Color = Theme.acid
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(total, 1), id: \.self) { i in
                Rectangle()
                    .fill(i < filled ? color : Theme.line)
                    .frame(height: 8)
                    .shadow(color: i < filled ? color.opacity(0.5) : .clear, radius: 3)
            }
        }
    }
}

/// Tiny bordered tag.
struct Tag: View {
    var text: String
    var color: Color = Theme.dim
    var body: some View {
        Text(text).font(.label(9)).tracking(1).textCase(.uppercase)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .overlay(Rectangle().stroke(color.opacity(0.6), lineWidth: 1))
    }
}

/// Blinking status lamp.
struct Lamp: View {
    var color: Color
    var blinking = false
    @State private var on = true
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .shadow(color: color, radius: on ? 4 : 0)
            .opacity(on ? 1 : 0.35)
            .onAppear {
                guard blinking else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever()) { on = false }
            }
    }
}

/// Diagonal warning stripes.
struct HazardStripes: View {
    var color: Color = Theme.amber
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                p.addLine(to: CGPoint(x: x + size.height + 8, y: 0))
                p.addLine(to: CGPoint(x: x + 8, y: size.height))
                p.closeSubpath()
                x += 16
            }
            ctx.fill(p, with: .color(color))
        }
        .background(Theme.bg)
        .clipped()
    }
}

struct LabButtonStyle: ButtonStyle {
    enum Kind { case primary, plain, danger }
    var kind: Kind = .plain
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        let tint: Color = kind == .primary ? Theme.acid : (kind == .danger ? Theme.red : Theme.text)
        let pressed = configuration.isPressed
        configuration.label
            .font(.label(compact ? 10 : 11)).tracking(1.4).textCase(.uppercase)
            .foregroundStyle(pressed ? Theme.bg : tint)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 7 : 11)
            .frame(maxWidth: compact ? nil : .infinity)
            .background(pressed ? tint : (kind == .primary ? tint.opacity(0.08) : Color.clear))
            .overlay(Rectangle().stroke(tint.opacity(kind == .plain ? 0.35 : 0.7), lineWidth: 1))
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

/// Input field with a mono caption and a hairline underline.
struct LabField: View {
    var caption: String
    @Binding var text: String
    var secure = false
    var placeholder = ""
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(caption).caps(9)
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                        .keyboardType(keyboard)
                }
            }
            .font(.readout(15))
            .foregroundStyle(Theme.text)
            .tint(Theme.acid)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            Rectangle().fill(text.isEmpty ? Theme.line : Theme.acid.opacity(0.7)).frame(height: 1)
        }
    }
}

/// Toggle drawn as a two-position switch block.
struct LabToggle: View {
    var title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        Button {
            isOn.toggle()
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body(14)).foregroundStyle(Theme.text)
                    if let detail { Text(detail).font(.body(11)).foregroundStyle(Theme.dim) }
                }
                Spacer()
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Rectangle().stroke(isOn ? Theme.acid : Theme.lineHi, lineWidth: 1)
                        .frame(width: 40, height: 18)
                    Rectangle().fill(isOn ? Theme.acid : Theme.faint)
                        .frame(width: 18, height: 14).padding(2)
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// App icon from disk, or a monogram tile when the bundle only has Assets.car.
struct AppIconView: View {
    var url: URL?
    var name: String
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let url, let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img).resizable().interpolation(.high)
            } else {
                ZStack {
                    Theme.panelHi
                    Text(String(name.prefix(1)).uppercased())
                        .font(.head(size * 0.55)).foregroundStyle(Theme.dim)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
}

/// Sheet chrome shared by every modal: header strip + content.
struct SheetFrame<Content: View>: View {
    var code: String
    var title: String
    var onClose: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            GridBackground()
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(code).font(.label(10)).foregroundStyle(Theme.bg)
                        .padding(.horizontal, 5).padding(.vertical, 2).background(Theme.acid)
                    Text(title).font(.head(26)).foregroundStyle(Theme.text).textCase(.uppercase)
                    Spacer()
                    if let onClose {
                        Button(action: onClose) {
                            Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Theme.dim).frame(width: 32, height: 32)
                                .overlay(Rectangle().stroke(Theme.line))
                        }
                    }
                }
                ScrollView { content().padding(.bottom, 30) }
                    .scrollIndicators(.hidden)
            }
            .padding(.horizontal, 18).padding(.top, 22)
        }
        .presentationBackground(Theme.bg)
        .presentationDragIndicator(.visible)
    }
}
