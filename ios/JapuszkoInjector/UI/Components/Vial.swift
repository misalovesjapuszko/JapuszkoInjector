import SwiftUI

/// Test-tube silhouette: a cap lip and a body with a rounded bottom.
struct VialShape: Shape {
    var lip: CGFloat = 7
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addRect(CGRect(x: r.minX, y: r.minY, width: r.width, height: lip))
        p.addPath(VialBody(lip: lip).path(in: r))
        return p
    }
}

struct VialBody: Shape {
    var lip: CGFloat = 7
    func path(in r: CGRect) -> Path {
        let inset: CGFloat = 3
        let x0 = r.minX + inset, x1 = r.maxX - inset
        let top = r.minY + lip
        let radius = (x1 - x0) / 2
        var p = Path()
        p.move(to: CGPoint(x: x0, y: top))
        p.addLine(to: CGPoint(x: x0, y: r.maxY - radius))
        p.addArc(tangent1End: CGPoint(x: x0, y: r.maxY), tangent2End: CGPoint(x: x1, y: r.maxY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: x1, y: r.maxY), tangent2End: CGPoint(x: x1, y: top), radius: radius)
        p.addLine(to: CGPoint(x: x1, y: top))
        p.closeSubpath()
        return p
    }
}

/// Liquid with a moving surface. `level` 0…1 of the body height.
struct LiquidShape: Shape {
    var level: Double
    var phase: Double
    var amplitude: CGFloat = 2.2

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func path(in r: CGRect) -> Path {
        let surface = r.minY + r.height * (1 - level)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: surface))
        let steps = 24
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let x = r.minX + r.width * t
            let y = surface + amplitude * sin(t * .pi * 2 + phase)
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// One vial: liquid level = time left of the 7-day signature.
struct Vial: View {
    var fill: Double
    var width: CGFloat = 34
    var height: CGFloat = 118
    var live = true

    var body: some View {
        let color = Theme.level(fill)
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !live)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                VialBody().fill(Theme.glass)
                // liquid
                GeometryReader { g in
                    let rect = CGRect(x: 0, y: 7, width: g.size.width, height: g.size.height - 7)
                    ZStack {
                        LiquidShape(level: max(fill, 0.02), phase: t * 2.4, amplitude: fill > 0.02 ? 2.2 : 0)
                            .fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.55)],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: rect.width, height: rect.height)
                            .offset(y: rect.minY)
                        // back wave, slower and fainter
                        LiquidShape(level: max(fill, 0.02), phase: t * 1.3 + 1.7, amplitude: fill > 0.02 ? 3 : 0)
                            .fill(color.opacity(0.25))
                            .frame(width: rect.width, height: rect.height)
                            .offset(y: rect.minY)
                        Bubbles(color: color, fill: fill, t: t)
                            .frame(width: rect.width, height: rect.height)
                            .offset(y: rect.minY)
                    }
                    .frame(width: g.size.width, height: g.size.height, alignment: .top)
                }
                .clipShape(VialBody())
                // graduation ticks, one per day
                Canvas { ctx, size in
                    let top: CGFloat = 7, h = size.height - top - size.width / 2
                    for d in 1..<7 {
                        let y = top + h * (1 - CGFloat(d) / 7) + 4
                        var p = Path()
                        p.move(to: CGPoint(x: size.width - 3, y: y))
                        p.addLine(to: CGPoint(x: size.width - (d % 2 == 0 ? 11 : 7), y: y))
                        ctx.stroke(p, with: .color(.white.opacity(0.28)), lineWidth: 1)
                    }
                }
                // glass edge + highlight
                VialBody().stroke(Color.white.opacity(0.22), lineWidth: 1)
                Rectangle().fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom))
                    .frame(width: 2).padding(.top, 12).padding(.bottom, width * 0.6)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 7)
                // cap
                VStack {
                    Rectangle().fill(Theme.lineHi).frame(height: 7)
                        .overlay(Rectangle().fill(color).frame(height: 2), alignment: .bottom)
                    Spacer()
                }
            }
            .shadow(color: color.opacity(0.25), radius: 10)
        }
        .frame(width: width, height: height)
        .animation(.easeInOut(duration: 0.8), value: fill)
    }
}

private struct Bubbles: View {
    var color: Color
    var fill: Double
    var t: Double

    var body: some View {
        Canvas { ctx, size in
            guard fill > 0.05 else { return }
            let surface = size.height * (1 - fill)
            for i in 0..<5 {
                let speed = 0.18 + Double(i) * 0.05
                let prog = (t * speed + Double(i) * 0.37).truncatingRemainder(dividingBy: 1)
                let y = size.height - prog * (size.height - surface)
                let x = size.width * (0.25 + 0.5 * (0.5 + 0.5 * sin(Double(i) * 2.1 + t)))
                let r = 1.0 + Double(i % 3) * 0.6
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                         with: .color(.white.opacity(0.35 * (1 - prog))))
            }
        }
    }
}
