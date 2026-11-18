import CMDR
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var store: HeadphoneStore

    var body: some View {
        VStack(spacing: 10) {
            if let s = store.state, store.isConnected {
                ConnectedView(state: s)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                StatusView()
                    .transition(.opacity)
            }
            Footer()
        }
        .padding(12)
        .frame(width: 340)
        .animation(.snappy(duration: 0.28), value: store.isConnected)
    }
}

/// Opens the Settings window, optionally on a specific pane. Injected by StatusBarController.
struct OpenSettingsAction {
    var handler: (SettingsPane?) -> Void = { _ in }
    func callAsFunction(_ pane: SettingsPane? = nil) { handler(pane) }
}

private struct OpenSettingsKey: EnvironmentKey {
    static let defaultValue = OpenSettingsAction()
}

extension EnvironmentValues {
    var openSettings: OpenSettingsAction {
        get { self[OpenSettingsKey.self] }
        set { self[OpenSettingsKey.self] = newValue }
    }
}

// MARK: - Connected

private struct ConnectedView: View {
    @EnvironmentObject var store: HeadphoneStore
    var state: HeadphoneState

    var body: some View {
        VStack(spacing: 10) {
            Header(state: state)
            if let noise = state.noise {
                NoiseCard(state: state, noise: noise)
            }
            if let l = state.listening {
                Card(title: "Listening Mode") {
                    ListeningModePicker(listening: l, compact: true)
                }
            }
            if let stc = state.speakToChat {
                Card {
                    ToggleRow(title: "Speak-to-Chat",
                              subtitle: "Pause music when you start talking",
                              symbol: "bubble.left.and.text.bubble.right",
                              isOn: Binding(get: { stc.enabled }, set: { store.setSpeakToChat($0) }))
                }
            }
            if let eq = state.equalizer, !eq.presets.isEmpty {
                EQCard(eq: eq)
            }
            if let pb = state.playback, !pb.title.isEmpty {
                NowPlayingCard(playback: pb)
            }
        }
    }
}

private struct Header: View {
    var state: HeadphoneState
    @EnvironmentObject var store: HeadphoneStore

    var body: some View {
        HStack(spacing: 10) {
            HeadphonesArt(finish: .init(colorName: state.color))
                .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 2) {
                Text(state.modelName.isEmpty ? (store.device?.name ?? "Headphones") : state.modelName)
                    .font(.system(size: 15, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                ForEach(state.batteries) { b in
                    BatteryPill(battery: b, showLabel: state.batteries.count > 1)
                }
                if let b = state.primaryBattery,
                   let f = store.insights.forecast(level: b.level, charging: b.charging, noise: state.noise?.mode.rawValue) {
                    Text("≈ \(InsightsPane.hours(f.hoursLeft)) left")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(f.learned ? "Based on your recent usage" : "Estimated from Sony's rating until SoundConnect learns your usage")
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private var subtitle: String {
        var parts = ["Connected"]
        if let worn = state.worn { parts.append(worn ? "On head" : "Off head") }
        return parts.joined(separator: " · ")
    }
}

private struct NoiseCard: View {
    @EnvironmentObject var store: HeadphoneStore
    var state: HeadphoneState
    var noise: NoiseState
    @Namespace private var ns
    @State private var dragLevel: Double?

    var body: some View {
        Card(title: "Noise Control") {
            HStack(spacing: 4) {
                ForEach(state.availableModes) { m in
                    ModeTile(mode: m, selected: noise.mode == m, namespace: ns) {
                        withAnimation(.snappy(duration: 0.3)) { store.setNoiseMode(m) }
                    }
                }
            }
            .padding(3)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            if noise.mode == .ambient {
                VStack(alignment: .leading, spacing: 10) {
                    if state.supportsAdaptiveAmbient {
                        ToggleRow(title: "Auto Ambient", subtitle: "Adjust to your surroundings",
                                  symbol: "sparkles",
                                  isOn: Binding(get: { noise.adaptiveAmbient },
                                                set: { store.setAdaptiveAmbient($0) }))
                    }
                    if !(state.supportsAdaptiveAmbient && noise.adaptiveAmbient) {
                        levelSlider
                    }
                    ToggleRow(title: "Focus on Voice", subtitle: nil, symbol: "person.wave.2",
                              isOn: Binding(get: { noise.focusOnVoice }, set: { store.setFocusOnVoice($0) }))
                }
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy(duration: 0.28), value: noise.mode)
        .animation(.snappy(duration: 0.28), value: noise.adaptiveAmbient)
    }

    private var levelSlider: some View {
        let range = state.ambientRange
        let value = dragLevel ?? Double(noise.ambientLevel)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Ambient Level").font(.system(size: 13))
                Spacer()
                Text("\(Int(value.rounded()))")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(.tertiary)
                Slider(
                    value: Binding(
                        get: { value },
                        set: { v in
                            dragLevel = v
                            let i = Int(v.rounded())
                            if i != noise.ambientLevel { store.setAmbientLevel(i) }
                        }),
                    in: Double(range.lowerBound)...Double(range.upperBound),
                    onEditingChanged: { editing in if !editing { dragLevel = nil } }
                )
                .controlSize(.small)
                Image(systemName: "speaker.wave.3.fill").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct EQCard: View {
    @EnvironmentObject var store: HeadphoneStore
    @Environment(\.openSettings) private var openSettings
    var eq: EqualizerState

    var body: some View {
        Card {
            HStack {
                Text("EQUALIZER")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    openSettings(.sound)
                } label: {
                    HStack(spacing: 2) {
                        Text("Customize")
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            if !eq.bands.isEmpty {
                MiniCurve(bands: eq.bands, range: eq.bandRange)
                    .frame(height: 30)
            }
            FlowLayout(spacing: 6) {
                ForEach(eq.presets) { p in
                    Chip(title: p.name, selected: eq.preset == p.id) {
                        withAnimation(.snappy) { store.setEQPreset(p.id) }
                    }
                }
            }
            if let cb = eq.clearBass {
                BassSlider(title: "Clear Bass", value: cb, range: eq.clearBassRange) { store.setClearBass($0) }
            } else if eq.bands.count >= 3 {
                // No Clear Bass on 10-band devices (e.g. XM6): drive the low bands instead.
                BassSlider(title: "Bass", value: eq.bands[0], range: eq.bandRange) { store.setBassBoost($0) }
            }
        }
    }
}

private struct BassSlider: View {
    var title: String
    var value: Int
    var range: ClosedRange<Int>
    var onChange: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                Text(value > 0 ? "+\(value)" : "\(value)")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            HStack(spacing: 8) {
                Image(systemName: "minus").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                Slider(value: Binding(get: { Double(value) },
                                      set: { v in
                                          let i = Int(v.rounded())
                                          if i != value { onChange(i) }
                                      }),
                       in: Double(range.lowerBound)...Double(range.upperBound))
                    .controlSize(.small)
                Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Read-only sparkline of the current EQ curve.
private struct MiniCurve: View {
    var bands: [Int]
    var range: ClosedRange<Int>

    var body: some View {
        Canvas { ctx, size in
            guard bands.count > 1 else { return }
            let lo = CGFloat(range.lowerBound), hi = CGFloat(range.upperBound)
            func yy(_ v: CGFloat) -> CGFloat { 3 + (1 - (v - lo) / max(hi - lo, 1)) * (size.height - 6) }
            let pts = bands.enumerated().map { i, v in
                CGPoint(x: size.width * CGFloat(i) / CGFloat(bands.count - 1), y: yy(CGFloat(v)))
            }
            var mid = Path()
            mid.move(to: CGPoint(x: 0, y: yy(0)))
            mid.addLine(to: CGPoint(x: size.width, y: yy(0)))
            ctx.stroke(mid, with: .color(.primary.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            var p = Path()
            p.move(to: pts[0])
            for i in 0..<(pts.count - 1) {
                let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
                p.addCurve(to: p2,
                           control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                           control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
            }
            ctx.stroke(p, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        }
    }
}

private struct NowPlayingCard: View {
    @EnvironmentObject var store: HeadphoneStore
    var playback: PlaybackState

    var body: some View {
        Card {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(0.08))
                    .frame(width: 36, height: 36)
                    .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(playback.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    if !playback.artist.isEmpty {
                        Text(playback.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                IconButton(symbol: "backward.fill", size: 11, help: "Previous") {
                    store.sendPlayback(UInt32(MDR_PLAYBACK_PREVIOUS))
                }
                IconButton(symbol: playback.playing ? "pause.fill" : "play.fill", size: 14,
                           help: playback.playing ? "Pause" : "Play") {
                    store.sendPlayback(UInt32(playback.playing ? MDR_PLAYBACK_PAUSE : MDR_PLAYBACK_PLAY))
                }
                IconButton(symbol: "forward.fill", size: 11, help: "Next") {
                    store.sendPlayback(UInt32(MDR_PLAYBACK_NEXT))
                }
            }
        }
    }
}

// MARK: - Not connected

private struct StatusView: View {
    @EnvironmentObject var store: HeadphoneStore

    var body: some View {
        VStack(spacing: 12) {
            HeadphonesArt(finish: .graphite)
                .frame(width: 70, height: 70)
                .opacity(isBusy ? 0.85 : 0.5)
                .animation(isBusy ? .easeInOut(duration: 0.9).repeatForever() : .default, value: isBusy)
            VStack(spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.status == .searching, let ls = store.insights.file.lastSeen {
                HStack(spacing: 4) {
                    Image(systemName: "mappin.and.ellipse")
                    Text("Last connected ") + Text(ls.date, format: .relative(presentation: .named))
                        + Text(ls.place.map { " · near \($0)" } ?? "")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            }
            if case .failed = store.status {
                HStack(spacing: 8) {
                    Button("Try Again") { store.reconnect() }
                    Button("Reset Connection") { store.resetConnection() }
                        .buttonStyle(.borderedProminent)
                        .help("Reconnects the headphones' Bluetooth link. Audio drops out for a few seconds.")
                }
                .controlSize(.small)
                Text("If this keeps happening, Reset Connection reconnects the headphones (audio drops out briefly).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            } else if isBusy {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    private var isBusy: Bool {
        if case .connecting = store.status { return true }
        return false
    }

    private var title: String {
        switch store.status {
        case .searching: "No Headphones Connected"
        case .connecting(let n): "Connecting to \(n)…"
        case .connected: "Loading…"
        case .failed: "Couldn't Connect"
        }
    }

    private var detail: String {
        switch store.status {
        case .searching: "Connect your Sony headphones in Bluetooth settings. SoundConnect will pick them up automatically."
        case .connecting: "Reading settings from your headphones."
        case .connected: ""
        case .failed(let m): m
        }
    }
}

// MARK: - Footer

private struct Footer: View {
    @EnvironmentObject var store: HeadphoneStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 2) {
            if let fw = store.state?.firmware, !fw.isEmpty {
                Text("Firmware \(fw)").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            IconButton(symbol: "arrow.clockwise", help: "Reconnect") { store.reconnect() }
            IconButton(symbol: "gearshape", help: "Settings…") { openSettings() }
            IconButton(symbol: "power", help: "Quit SoundConnect") { NSApp.terminate(nil) }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }
}
