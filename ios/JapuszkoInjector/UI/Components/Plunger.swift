import SwiftUI

/// Hold-to-inject control drawn as a syringe. Holding pushes the plunger;
/// once it bottoms out, `action` fires. While `progress` is set it shows the
/// running job instead (liquid drains as the install advances).
struct PlungerButton: View {
    var label: String = "Hold to inject"
    var enabled = true
    var progress: Double? = nil
    var stage: String? = nil
    var holdSeconds: Double = 1.1
    var action: () -> Void

    @State private var push: Double = 0      // 0…1 while holding
    @State private var holding = false

    private var running: Bool { progress != nil }
    private var drained: Double {
        if let p = progress { return min(max(p, 0), 1) }
        return push
    }
    private var caption: String { running ? (stage ?? "Working") : label }

    var body: some View {
        GeometryReader { g in
            SyringeDrawing(
                layout: SyringeLayout(size: g.size, drained: drained),
                tint: (enabled || running) ? Theme.acid : Theme.faint,
                holding: holding,
                caption: caption,
                percent: running ? Int(drained * 100) : nil
            )
        }
        .frame(height: 64)
        .contentShape(Rectangle())
        .opacity(enabled || running ? 1 : 0.45)
        .onLongPressGesture(minimumDuration: holdSeconds, maximumDistance: 60) {
            fire()
        } onPressingChanged: { pressing in
            pressingChanged(pressing)
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if enabled && progress == nil { action() } }
    }

    private func fire() {
        guard enabled, progress == nil else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        holding = false
        action()
        withAnimation(.easeOut(duration: 0.4).delay(0.25)) { push = 0 }
    }

    private func pressingChanged(_ pressing: Bool) {
        guard enabled, progress == nil else { return }
        holding = pressing
        if pressing {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.linear(duration: holdSeconds)) { push = 1 }
            startTicks()
        } else if push < 1 {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { push = 0 }
        }
    }

    /// Clicky haptics while the plunger travels.
    private func startTicks() {
        let steps = 6
        for i in 1...steps {
            let delay = holdSeconds * Double(i) / Double(steps + 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard holding else { return }
                let intensity = 0.35 + 0.1 * Double(i)
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: intensity)
            }
        }
    }
}

/// All syringe geometry, computed once.
struct SyringeLayout {
    let w: CGFloat
    let h: CGFloat
    let handleW: CGFloat = 12
    let needleW: CGFloat = 30
    let flangeW: CGFloat = 4
    let travel: CGFloat
    let barrelX: CGFloat
    let barrelW: CGFloat
    let barrelH: CGFloat
    let handleX: CGFloat
    let stopperX: CGFloat
    let liquidX: CGFloat
    let liquidW: CGFloat
    let drained: Double

    init(size: CGSize, drained: Double) {
        w = size.width
        h = size.height
        self.drained = drained
        let d = CGFloat(drained)
        let available = w - 12 - 30 - 4 - 10
        travel = max(40, available / 2)
        barrelX = 12 + travel + 4
        barrelW = travel + 10
        barrelH = h - 18
        handleX = travel * d
        stopperX = barrelX + 2 + travel * d
        liquidX = stopperX + 6
        liquidW = max(0, barrelX + barrelW - 2 - liquidX)
    }
}

private struct SyringeDrawing: View {
    let layout: SyringeLayout
    let tint: Color
    let holding: Bool
    let caption: String
    let percent: Int?

    var body: some View {
        ZStack(alignment: .topLeading) {
            NeedleView(layout: layout, tint: tint)
            BarrelView(layout: layout, tint: tint)
            PlungerRodView(layout: layout, tint: tint, holding: holding)
            CaptionView(layout: layout, caption: caption, percent: percent)
        }
    }
}

private struct NeedleView: View {
    let layout: SyringeLayout
    let tint: Color

    var body: some View {
        let l = layout
        let mid = l.h / 2
        let start = l.barrelX + l.barrelW
        ZStack(alignment: .topLeading) {
            Path { p in
                p.move(to: CGPoint(x: start, y: mid - 3))
                p.addLine(to: CGPoint(x: l.w - 9, y: mid - 1))
                p.addLine(to: CGPoint(x: l.w, y: mid))
                p.addLine(to: CGPoint(x: l.w - 9, y: mid + 1))
                p.addLine(to: CGPoint(x: start, y: mid + 3))
                p.closeSubpath()
            }
            .fill(Theme.dim)
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .shadow(color: tint, radius: 8)
                .opacity(l.drained > 0.05 ? l.drained : 0)
                .offset(x: l.w - 3, y: mid - 3)
        }
    }
}

private struct BarrelView: View {
    let layout: SyringeLayout
    let tint: Color

    var body: some View {
        let l = layout
        let gradient = LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.45)],
                                      startPoint: .top, endPoint: .bottom)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Theme.panelHi)
                .frame(width: l.barrelW, height: l.barrelH)
                .offset(x: l.barrelX, y: 9)
            Rectangle()
                .fill(gradient)
                .frame(width: l.liquidW, height: l.barrelH - 8)
                .offset(x: l.liquidX, y: 13)
            Canvas { ctx, _ in
                for i in 0...10 {
                    let x = l.barrelX + 6 + (l.barrelW - 12) * CGFloat(i) / 10
                    let len: CGFloat = i % 5 == 0 ? 10 : 5
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: 9))
                    p.addLine(to: CGPoint(x: x, y: 9 + len))
                    ctx.stroke(p, with: .color(.white.opacity(0.4)), lineWidth: 1)
                }
            }
            Rectangle()
                .stroke(Color.white.opacity(0.3), lineWidth: 1)
                .frame(width: l.barrelW, height: l.barrelH)
                .offset(x: l.barrelX, y: 9)
            Rectangle()
                .fill(Theme.lineHi)
                .frame(width: l.flangeW, height: l.h)
                .offset(x: l.barrelX - l.flangeW)
        }
    }
}

private struct PlungerRodView: View {
    let layout: SyringeLayout
    let tint: Color
    let holding: Bool

    var body: some View {
        let l = layout
        let rodW = max(0, l.stopperX - l.handleX - l.handleW)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Theme.dim)
                .frame(width: rodW, height: 5)
                .offset(x: l.handleX + l.handleW, y: l.h / 2 - 2.5)
            Rectangle()
                .fill(Theme.text)
                .frame(width: 6, height: l.barrelH - 6)
                .offset(x: l.stopperX, y: 12)
            Rectangle()
                .fill(holding ? tint : Theme.text)
                .frame(width: l.handleW, height: l.h - 8)
                .shadow(color: holding ? tint : .clear, radius: 6)
                .offset(x: l.handleX, y: 4)
        }
    }
}

private struct CaptionView: View {
    let layout: SyringeLayout
    let caption: String
    let percent: Int?

    var body: some View {
        VStack(spacing: 1) {
            Text(caption)
                .font(.label(10))
                .tracking(1.6)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let percent {
                Text("\(percent)%").font(.readout(10))
            }
        }
        .foregroundStyle(Theme.text)
        .shadow(color: .black.opacity(0.9), radius: 2)
        .frame(width: layout.barrelW - 8, height: layout.h)
        .offset(x: layout.barrelX + 4)
    }
}
