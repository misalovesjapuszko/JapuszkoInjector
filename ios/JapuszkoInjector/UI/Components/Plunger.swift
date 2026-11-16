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

    var body: some View {
        let running = progress != nil
        let drained = running ? min(max(progress ?? 0, 0), 1) : push
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let handleW: CGFloat = 12, needleW: CGFloat = 30, flangeW: CGFloat = 4
            // Plunger travel; the rod sticking out is as long as the barrel.
            let travel = max(40, (w - handleW - needleW - flangeW - 10) / 2)
            let barrelX = handleW + travel + flangeW
            let barrelW = travel + 10
            let handleX = travel * drained
            let stopperX = barrelX + 2 + travel * drained
            let liquidX = stopperX + 6
            let liquidW = max(0, barrelX + barrelW - 2 - liquidX)
            let tint = (enabled || running) ? Theme.acid : Theme.faint
            let barrelH = h - 18

            ZStack(alignment: .topLeading) {
              Group {
                // needle + drop
                Path { p in
                    let nx = barrelX + barrelW
                    p.move(to: CGPoint(x: nx, y: h / 2 - 3))
                    p.addLine(to: CGPoint(x: w - 9, y: h / 2 - 1))
                    p.addLine(to: CGPoint(x: w, y: h / 2))
                    p.addLine(to: CGPoint(x: w - 9, y: h / 2 + 1))
                    p.addLine(to: CGPoint(x: nx, y: h / 2 + 3))
                    p.closeSubpath()
                }
                .fill(Theme.dim)
                Circle().fill(tint).frame(width: 6, height: 6)
                    .shadow(color: tint, radius: 8)
                    .opacity(drained > 0.05 ? drained : 0)
                    .offset(x: w - 3, y: h / 2 - 3)

                // barrel glass
                Rectangle().fill(Theme.panelHi)
                    .frame(width: barrelW, height: barrelH)
                    .offset(x: barrelX, y: 9)
                // dose
                Rectangle()
                    .fill(LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.45)], startPoint: .top, endPoint: .bottom))
                    .frame(width: liquidW, height: barrelH - 8)
                    .offset(x: liquidX, y: 13)
                // graduations
                Canvas { ctx, _ in
                    for i in 0...10 {
                        let x = barrelX + 6 + (barrelW - 12) * CGFloat(i) / 10
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: 9))
                        p.addLine(to: CGPoint(x: x, y: 9 + (i % 5 == 0 ? 10 : 5)))
                        ctx.stroke(p, with: .color(.white.opacity(0.4)), lineWidth: 1)
                    }
                }
                Rectangle().stroke(Color.white.opacity(0.3), lineWidth: 1)
                    .frame(width: barrelW, height: barrelH)
                    .offset(x: barrelX, y: 9)
                // finger flange
                Rectangle().fill(Theme.lineHi)
                    .frame(width: flangeW, height: h)
                    .offset(x: barrelX - flangeW)
              }

                // rod, stopper, thumb rest
                Rectangle().fill(Theme.dim)
                    .frame(width: max(0, stopperX - handleX - handleW), height: 5)
                    .offset(x: handleX + handleW, y: h / 2 - 2.5)
                Rectangle().fill(Theme.text)
                    .frame(width: 6, height: barrelH - 6)
                    .offset(x: stopperX, y: 12)
                Rectangle().fill(holding ? tint : Theme.text)
                    .frame(width: handleW, height: h - 8)
                    .offset(x: handleX, y: 4)
                    .shadow(color: holding ? tint : .clear, radius: 6)

                // caption
                VStack(spacing: 1) {
                    Text(running ? (stage ?? "Working") : label)
                        .font(.label(10)).tracking(1.6).textCase(.uppercase)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if running {
                        Text("\(Int(drained * 100))%").font(.readout(10))
                    }
                }
                .foregroundStyle(Theme.text)
                .shadow(color: .black.opacity(0.9), radius: 2)
                .frame(width: barrelW - 8, height: h)
                .offset(x: barrelX + 4)
            }
        }
        .frame(height: 64)
        .contentShape(Rectangle())
        .opacity(enabled || running ? 1 : 0.45)
        .onLongPressGesture(minimumDuration: holdSeconds, maximumDistance: 60) {
            guard enabled, progress == nil else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            holding = false
            action()
            withAnimation(.easeOut(duration: 0.4).delay(0.25)) { push = 0 }
        } onPressingChanged: { pressing in
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
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if enabled && progress == nil { action() } }
    }

    /// Clicky haptics while the plunger travels.
    private func startTicks() {
        let steps = 6
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + holdSeconds * Double(i) / Double(steps + 1)) {
                guard holding else { return }
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.35 + 0.1 * Double(i))
            }
        }
    }
}
