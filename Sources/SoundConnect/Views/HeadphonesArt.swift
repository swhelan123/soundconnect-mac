import SwiftUI

/// Vector illustration of over-ear headphones, tinted to roughly match the device's reported colour.
struct HeadphonesArt: View {
    var finish: Finish = .graphite

    enum Finish {
        case black, silver, midnight, graphite, white

        init(colorName: String) {
            let c = colorName.lowercased()
            if c.contains("silver") || c.contains("platinum") || c.contains("grey") || c.contains("gray") { self = .silver }
            else if c.contains("blue") || c.contains("midnight") { self = .midnight }
            else if c.contains("white") || c.contains("cream") || c.contains("sand") { self = .white }
            else if c.contains("black") { self = .black }
            else { self = .graphite }
        }

        var body: (Color, Color) {
            switch self {
            case .black: (Color(red: 0.25, green: 0.25, blue: 0.27), Color(red: 0.10, green: 0.10, blue: 0.11))
            case .silver: (Color(red: 0.93, green: 0.92, blue: 0.89), Color(red: 0.72, green: 0.70, blue: 0.66))
            case .midnight: (Color(red: 0.25, green: 0.32, blue: 0.48), Color(red: 0.11, green: 0.15, blue: 0.25))
            case .graphite: (Color(red: 0.42, green: 0.43, blue: 0.46), Color(red: 0.20, green: 0.21, blue: 0.23))
            case .white: (Color(red: 0.98, green: 0.97, blue: 0.95), Color(red: 0.82, green: 0.80, blue: 0.77))
            }
        }

        var cushion: Color {
            switch self {
            case .silver, .white: Color(red: 0.55, green: 0.53, blue: 0.50)
            default: Color.black.opacity(0.85)
            }
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height)
            let ox = (size.width - s) / 2, oy = (size.height - s) / 2
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
            let (light, dark) = finish.body
            let bodyShading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [light, dark]), startPoint: p(0.5, 0.05), endPoint: p(0.5, 0.95))

            // Headband
            var band = Path()
            band.addArc(center: p(0.5, 0.55), radius: 0.37 * s,
                        startAngle: .degrees(196), endAngle: .degrees(344), clockwise: false)
            ctx.stroke(band, with: bodyShading, style: StrokeStyle(lineWidth: 0.085 * s, lineCap: .round))
            // Soft inner padding line
            var pad = Path()
            pad.addArc(center: p(0.5, 0.55), radius: 0.335 * s,
                       startAngle: .degrees(222), endAngle: .degrees(318), clockwise: false)
            ctx.stroke(pad, with: .color(finish.cushion.opacity(0.55)),
                       style: StrokeStyle(lineWidth: 0.03 * s, lineCap: .round))

            // Sliders
            for x in [0.155, 0.845] {
                let r = CGRect(x: ox + (x - 0.025) * s, y: oy + 0.42 * s, width: 0.05 * s, height: 0.14 * s)
                ctx.fill(Path(roundedRect: r, cornerRadius: 0.02 * s), with: .color(dark))
            }

            // Ear cups (inner cushion faces the centre)
            for (x, inward) in [(0.16, 1.0), (0.84, -1.0)] {
                let cup = CGRect(x: ox + (x - 0.12) * s, y: oy + 0.5 * s, width: 0.24 * s, height: 0.4 * s)
                let cupPath = Path(roundedRect: cup, cornerRadius: 0.11 * s, style: .continuous)
                ctx.drawLayer { l in
                    l.addFilter(.shadow(color: .black.opacity(0.35), radius: 0.03 * s, y: 0.015 * s))
                    l.fill(cupPath, with: bodyShading)
                }
                let cushion = CGRect(x: cup.midX + inward * 0.06 * s - 0.045 * s, y: cup.minY + 0.035 * s,
                                     width: 0.09 * s, height: cup.height - 0.07 * s)
                ctx.fill(Path(roundedRect: cushion, cornerRadius: 0.045 * s, style: .continuous),
                         with: .color(finish.cushion))
                // Specular highlight on the outer shell
                let hl = CGRect(x: cup.midX - inward * 0.055 * s - 0.018 * s, y: cup.minY + 0.06 * s,
                                width: 0.036 * s, height: cup.height * 0.42)
                ctx.fill(Path(roundedRect: hl, cornerRadius: 0.018 * s),
                         with: .color(.white.opacity(finish == .silver || finish == .white ? 0.6 : 0.18)))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// App icon artwork: headphones on a rounded-square gradient tile.
struct AppIconArt: View {
    var body: some View {
        GeometryReader { g in
            let s = g.size.width
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.225, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.98),
                                                  Color(red: 0.15, green: 0.16, blue: 0.52)],
                                         startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: s * 0.225, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: s * 0.006)
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.25), .clear],
                                         center: .center, startRadius: 0, endRadius: s * 0.4))
                    .frame(width: s * 0.8)
                    .offset(y: -s * 0.12)
                HeadphonesArt(finish: .silver)
                    .frame(width: s * 0.66)
                    .offset(y: -s * 0.02)
                    .shadow(color: .black.opacity(0.35), radius: s * 0.03, y: s * 0.02)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
