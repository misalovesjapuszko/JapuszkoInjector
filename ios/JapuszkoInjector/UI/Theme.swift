import SwiftUI

/// Lab-instrument look: near-black panels, hairlines, one acid accent.
enum Theme {
    static let bg = Color(hex: 0x090B0A)
    static let panel = Color(hex: 0x101412)
    static let panelHi = Color(hex: 0x161B18)
    static let line = Color(hex: 0x242B27)
    static let lineHi = Color(hex: 0x36403A)
    static let text = Color(hex: 0xE4EAE5)
    static let dim = Color(hex: 0x7B8881)
    static let faint = Color(hex: 0x434D47)
    static let acid = Color(hex: 0xB6FF3B)
    static let amber = Color(hex: 0xFFB020)
    static let red = Color(hex: 0xFF4D3D)
    static let glass = Color.white.opacity(0.06)

    /// Liquid colour for a 0…1 fill level.
    static func level(_ fill: Double) -> Color {
        fill > 0.4 ? acid : (fill > 0.15 ? amber : red)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

extension Font {
    /// Small stencil-ish labels: "LINK", "ACCT", "IDS".
    static func label(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .semibold, design: .monospaced)
    }
    /// Condensed heavy headings.
    static func head(_ size: CGFloat) -> Font {
        .system(size: size, weight: .black).width(.condensed)
    }
    /// Numbers and readouts.
    static func readout(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .monospaced)
    }
    static func body(_ size: CGFloat = 14) -> Font {
        .system(size: size, weight: .regular)
    }
}

extension View {
    /// Letter-spaced uppercase label.
    func caps(_ size: CGFloat = 10, _ color: Color = Theme.dim) -> some View {
        self.font(.label(size)).tracking(1.6).textCase(.uppercase).foregroundStyle(color)
    }
}

extension Date {
    var stamp: String {
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm"
        return f.string(from: self)
    }
}
