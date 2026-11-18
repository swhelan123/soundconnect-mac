import AppKit
import SwiftUI

/// Design/asset tooling, no Bluetooth involved:
///   SoundConnect --render <dir>         popover + settings panes, light & dark, sample data -> PNGs
///   SoundConnect --render-icon <dir>    AppIcon.iconset PNGs (feed to `iconutil -c icns`)
@MainActor
enum PreviewRenderer {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-dmg-background"), i + 1 < args.count {
            _ = NSApplication.shared
            renderDMGBackground(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
            _ = NSApplication.shared
            renderIcon(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        guard let i = args.firstIndex(of: "--render"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let suffix = appearance == .darkAqua ? "dark" : "light"
            for (name, store) in popoverSamples() {
                render(PopoverView().environmentObject(store).background(VisualEffect()),
                       appearance: appearance, to: dir.appendingPathComponent("\(name)-\(suffix).png"))
            }
            let store = HeadphoneStore(preview: sample(), status: .connected, insights: Insights(preview: sampleHistory()))
            for pane in SettingsPane.allCases {
                UserDefaults.standard.set(pane.rawValue, forKey: "settingsPane")
                render(SettingsView().environmentObject(store).frame(width: 820, height: 640)
                        .background(Color(nsColor: .windowBackgroundColor)),
                       appearance: appearance, to: dir.appendingPathComponent("settings-\(pane.rawValue)-\(suffix).png"))
            }
        }
        exit(0)
    }

    static func sample(mode: NoiseMode = .cancelling, listening: ListeningMode = .standard) -> HeadphoneState {
        var s = HeadphoneState()
        s.modelName = "WH-1000XM6"
        s.firmware = "3.1.5"
        s.color = "BLACK"
        s.batteries = [Battery(part: .main, level: 82, charging: false)]
        s.supportsNoiseCancelling = true
        s.supportsAmbient = true
        s.supportsAdaptiveAmbient = true
        s.noise = NoiseState(mode: mode, ambientLevel: 14, focusOnVoice: true, adaptiveAmbient: false)
        s.speakToChat = SpeakToChatState(enabled: false, raw: .init())
        s.listening = ListeningState(mode: listening, room: .medium, modes: [.standard, .backgroundMusic, .cinema],
                                     blocked: [:], raw: .init())
        s.equalizer = EqualizerState(
            preset: 24,
            presets: [0, 16, 17, 18, 19, 24, 25, 26].map { EQPreset(id: $0, name: EQPreset.defaultName($0)) },
            bands: [4, 3, 1, 0, -1, 0, 1, 2, 3, 2],
            frequencies: [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000],
            bandRange: -10...10, clearBass: nil, clearBassRange: -10...10,
            dseeAvailable: true, dseeEnabled: true)
        s.playback = PlaybackState(playing: true, title: "Midnight City", artist: "M83", volume: 12)
        s.supportsPlaybackControl = true
        s.worn = true
        s.power = PowerState(autoPowerOffMinutes: 0, autoPowerOffOptions: [0, 5, 30, 60, 180],
                             powerOffWhenRemoved: false, autoPause: true, headGesture: nil, raw: .init())
        s.voiceGuidance = VoiceGuidanceState(enabled: true, volume: 0, volumeRange: -2...2)
        s.assignableKeys = [AssignableKey(location: 5, type: 2, action: 2, options: [2, 10, 0])]
        s.pairedDevices = [
            PairedDevice(mac: "AA:BB:CC:DD:EE:01", name: "MacBook Pro", connected: true, isPlaybackSource: true),
            PairedDevice(mac: "AA:BB:CC:DD:EE:02", name: "iPhone", connected: true, isPlaybackSource: false),
            PairedDevice(mac: "AA:BB:CC:DD:EE:03", name: "iPad", connected: false, isPlaybackSource: false),
        ]
        s.autoSourceSwitch = true
        s.prioritizeQuality = true
        s.generalSettings = [
            GeneralSetting(index: 0, title: "Capture Voice During a Phone Call", summary: "", writable: true, kind: .toggle(true)),
            GeneralSetting(index: 1, title: "Touch Sensor Control Panel", summary: "", writable: true, kind: .toggle(true)),
        ]
        s.supportsShutdown = true
        s.soundPressure = 74
        return s
    }

    static func sampleHistory() -> HistoryFile {
        var h = HistoryFile()
        let now = Date()
        for i in 0..<40 {
            let t = now.addingTimeInterval(Double(-40 + i) * 3600)
            let level = i < 18 ? 100 - i * 4 : i < 21 ? 40 + (i - 18) * 20 : 100 - (i - 21) * 3
            h.battery.append(BatterySample(t: t, level: max(level, 5), charging: (18..<21).contains(i), noise: 1))
        }
        let cal = Calendar.current
        for (i, (dose, worn)) in [(0.08, 3.1), (0.12, 4.5), (0.05, 2.0), (0.2, 6.2), (0.1, 3.8), (0.15, 5.0), (0.07, 2.4)].enumerated() {
            let d = cal.date(byAdding: .day, value: -6 + i, to: now)!
            var s = DayStats()
            s.weeklyDose = dose
            s.wornSeconds = worn * 3600
            s.listeningSeconds = worn * 3000
            s.energySum = pow(10, 7.4) * s.listeningSeconds
            s.peakDB = 88
            h.days[Insights.dayKey(d)] = s
        }
        h.lastSeen = LastSeen(date: now.addingTimeInterval(-7200), latitude: 53.3438, longitude: -6.2546, place: "Trinity College, Dublin")
        return h
    }

    static func popoverSamples() -> [(String, HeadphoneStore)] {
        [
            ("nc", HeadphoneStore(preview: sample(), status: .connected)),
            ("ambient-bgm", HeadphoneStore(preview: sample(mode: .ambient, listening: .backgroundMusic), status: .connected)),
            ("searching", HeadphoneStore(preview: nil, status: .searching)),
            ("failed", HeadphoneStore(preview: nil, status: .failed("Timed out connecting to headphones"))),
        ]
    }

    static func render<V: View>(_ view: V, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// DMG window background (660x400 pt) at 1x and 2x. Icon centres are at (165,190) and (495,190);
    /// keep in sync with scripts/dmg-settings.py.
    static func renderDMGBackground(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] {
            let renderer = ImageRenderer(content: DMGBackground().frame(width: 660, height: 400))
            renderer.scale = scale
            guard let cg = renderer.cgImage else { continue }
            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent(name))
        }
    }

    static func renderIcon(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                // macOS icon grid: artwork occupies ~80% of the canvas with transparent margin.
                let view = AppIconArt()
                    .frame(width: CGFloat(px) * 0.805, height: CGFloat(px) * 0.805)
                    .frame(width: CGFloat(px), height: CGFloat(px))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                guard let cg = renderer.cgImage else { continue }
                let rep = NSBitmapImageRep(cgImage: cg)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
            }
        }
    }
}

/// Stand-in for the menu bar window's material when rendering offscreen.
private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.state = .active
        v.blendingMode = .behindWindow
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Install-window artwork for the DMG.
private struct DMGBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.97, green: 0.97, blue: 1.0), Color(red: 0.89, green: 0.90, blue: 0.98)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.98).opacity(0.10), .clear],
                           center: UnitPoint(x: 0.5, y: 0.45), startRadius: 0, endRadius: 320)
            VStack(spacing: 4) {
                Text("SoundConnect")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.16, green: 0.17, blue: 0.40))
                Text("Drag the app to Applications to install")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(red: 0.35, green: 0.37, blue: 0.55))
            }
            .position(x: 330, y: 56)
            // Arrow from the app icon to the Applications folder.
            Canvas { ctx, _ in
                var line = Path()
                line.move(to: CGPoint(x: 252, y: 190))
                line.addLine(to: CGPoint(x: 400, y: 190))
                ctx.stroke(line, with: .color(Color(red: 0.36, green: 0.42, blue: 0.98).opacity(0.75)),
                           style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [0.1, 13]))
                var head = Path()
                head.move(to: CGPoint(x: 398, y: 176))
                head.addLine(to: CGPoint(x: 414, y: 190))
                head.addLine(to: CGPoint(x: 398, y: 204))
                ctx.stroke(head, with: .color(Color(red: 0.36, green: 0.42, blue: 0.98).opacity(0.85)),
                           style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            Text("First launch: System Settings → Privacy & Security → Open Anyway")
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.40, green: 0.42, blue: 0.58))
                .position(x: 330, y: 362)
        }
        .frame(width: 660, height: 400)
    }
}
