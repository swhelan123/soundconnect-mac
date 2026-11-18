import SwiftUI

/// Draggable multi-band EQ with a smooth response curve.
struct EQCurveEditor: View {
    var bands: [Int]
    var frequencies: [Int]
    var range: ClosedRange<Int>
    var onChange: ([Int]) -> Void

    @State private var dragging: Int?
    @State private var hovered: Int?
    @State private var working: [Int]?

    private var values: [Int] { working ?? bands }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let pts = points(w: w, h: h)
                ZStack {
                    grid(w: w, h: h)
                    let curve = smoothPath(pts)
                    // Fill between curve and the 0 dB line
                    var fill = curve
                    let _ = {
                        fill.addLine(to: CGPoint(x: pts.last?.x ?? w, y: y(for: 0, h: h)))
                        fill.addLine(to: CGPoint(x: pts.first?.x ?? 0, y: y(for: 0, h: h)))
                        fill.closeSubpath()
                    }()
                    fill.fill(LinearGradient(colors: [.accentColor.opacity(0.35), .accentColor.opacity(0.05)],
                                             startPoint: .top, endPoint: .bottom))
                    curve.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    ForEach(pts.indices, id: \.self) { i in
                        knob(i: i, at: pts[i])
                    }
                }
                .contentShape(Rectangle())
                .gesture(drag(w: w, h: h))
                .onContinuousHover { phase in
                    if case .active(let loc) = phase { hovered = nearest(loc.x, w: w) } else { hovered = nil }
                }
            }
            .frame(height: 170)

            HStack(spacing: 0) {
                ForEach(frequencies.indices, id: \.self) { i in
                    Text(Self.label(hz: frequencies[i]))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(dragging == i ? Color.accentColor : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: - Geometry

    private func x(for i: Int, w: CGFloat) -> CGFloat {
        guard values.count > 1 else { return w / 2 }
        // Equal-width columns so frequency labels line up under knobs.
        let col = w / CGFloat(values.count)
        return col * (CGFloat(i) + 0.5)
    }

    private func y(for v: Int, h: CGFloat) -> CGFloat {
        let lo = CGFloat(range.lowerBound), hi = CGFloat(range.upperBound)
        let t = (CGFloat(v) - lo) / max(hi - lo, 1)
        return 10 + (1 - t) * (h - 20)
    }

    private func value(atY py: CGFloat, h: CGFloat) -> Int {
        let lo = CGFloat(range.lowerBound), hi = CGFloat(range.upperBound)
        let t = 1 - (py - 10) / max(h - 20, 1)
        return Int((lo + t * (hi - lo)).rounded()).clamped(to: range)
    }

    private func points(w: CGFloat, h: CGFloat) -> [CGPoint] {
        values.indices.map { CGPoint(x: x(for: $0, w: w), y: y(for: values[$0], h: h)) }
    }

    private func nearest(_ px: CGFloat, w: CGFloat) -> Int? {
        guard !values.isEmpty else { return nil }
        let col = w / CGFloat(values.count)
        return Int(px / col).clamped(to: 0...(values.count - 1))
    }

    // MARK: - Drawing

    private func grid(w: CGFloat, h: CGFloat) -> some View {
        Canvas { ctx, size in
            let lo = range.lowerBound, hi = range.upperBound
            for v in [lo, lo / 2, 0, hi / 2, hi] {
                var p = Path()
                let yy = y(for: v, h: size.height)
                p.move(to: CGPoint(x: 0, y: yy))
                p.addLine(to: CGPoint(x: size.width, y: yy))
                ctx.stroke(p, with: .color(.primary.opacity(v == 0 ? 0.18 : 0.07)),
                           style: StrokeStyle(lineWidth: 1, dash: v == 0 ? [] : [3, 4]))
            }
            for i in values.indices {
                var p = Path()
                let xx = x(for: i, w: size.width)
                p.move(to: CGPoint(x: xx, y: 6))
                p.addLine(to: CGPoint(x: xx, y: size.height - 6))
                ctx.stroke(p, with: .color(.primary.opacity(0.05)), lineWidth: 1)
            }
        }
    }

    private func knob(i: Int, at pt: CGPoint) -> some View {
        let active = dragging == i || (dragging == nil && hovered == i)
        return ZStack {
            Circle()
                .fill(.background)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: active ? 3 : 2))
                .frame(width: active ? 15 : 12, height: active ? 15 : 12)
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            if active {
                Text(values[i] > 0 ? "+\(values[i])" : "\(values[i])")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
                    .offset(y: pt.y < 34 ? 20 : -20)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .position(pt)
        .animation(.snappy(duration: 0.15), value: active)
    }

    /// Catmull-Rom spline through the points, as cubic Béziers.
    private func smoothPath(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count > 1 else { return path }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    // MARK: - Interaction

    private func drag(w: CGFloat, h: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if dragging == nil { dragging = nearest(g.startLocation.x, w: w); working = bands }
                guard let i = dragging, var vals = working else { return }
                let v = value(atY: g.location.y, h: h)
                if vals[i] != v {
                    vals[i] = v
                    working = vals
                    onChange(vals)
                }
            }
            .onEnded { _ in
                dragging = nil
                // Keep showing our values until the device snapshot catches up.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { working = nil }
            }
    }

    static func label(hz: Int) -> String {
        if hz <= 0 { return "" }
        if hz >= 1000 {
            let k = Double(hz) / 1000
            return k == k.rounded() ? "\(Int(k))k" : String(format: "%.1fk", k)
        }
        return "\(hz)"
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
