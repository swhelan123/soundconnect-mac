import CMDR
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case sound, insights, controls, devices, system, app, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sound: "Sound"
        case .insights: "Insights"
        case .controls: "Controls"
        case .devices: "Devices"
        case .system: "System"
        case .app: "App"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .sound: "slider.vertical.3"
        case .insights: "chart.bar.xaxis"
        case .controls: "hand.tap"
        case .devices: "laptopcomputer.and.iphone"
        case .system: "gearshape"
        case .app: "menubar.rectangle"
        case .about: "info.circle"
        }
    }

    var needsDevice: Bool { ![.app, .about, .insights].contains(self) }
}

/// Sidebar column (hosted in an NSSplitViewController sidebar item, see SettingsWindowController).
struct SettingsSidebar: View {
    @AppStorage("settingsPane") private var paneRaw = SettingsPane.sound.rawValue

    var body: some View {
        VStack(spacing: 0) {
            DeviceSidebarHeader()
            List(selection: Binding<SettingsPane?>(
                get: { SettingsPane(rawValue: paneRaw) ?? .sound },
                set: { paneRaw = ($0 ?? .sound).rawValue })) {
                ForEach(SettingsPane.allCases) { p in
                    Label(p.title, systemImage: p.symbol).tag(p)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }
}

/// Detail column for the selected pane.
struct SettingsDetail: View {
    @EnvironmentObject var store: HeadphoneStore
    @AppStorage("settingsPane") private var paneRaw = SettingsPane.sound.rawValue

    var body: some View {
        let p = SettingsPane(rawValue: paneRaw) ?? .sound
        VStack(alignment: .leading, spacing: 0) {
            Text(p.title)
                .font(.system(size: 22, weight: .bold))
                .padding(.horizontal, 30)
                .padding(.top, 6)
                .padding(.bottom, 2)
            Group {
            if p.needsDevice, let s = store.state, store.isConnected {
                switch p {
                case .sound: SoundPane(state: s)
                case .controls: ControlsPane(state: s)
                case .devices: DevicesPane(state: s)
                case .system: SystemPane(state: s)
                default: EmptyView()
                }
            } else if p == .insights {
                InsightsPane(insights: store.insights)
            } else if p == .app {
                AppPane()
            } else if p == .about {
                AboutPane()
            } else {
                ContentUnavailableView("Headphones Not Connected", systemImage: "headphones",
                                       description: Text("Connect your headphones to change their settings."))
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Both columns side by side; only used for offscreen design renders (the real window is AppKit).
struct SettingsView: View {
    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar()
                .frame(width: 220)
                .background(.regularMaterial)
            Divider()
            SettingsDetail()
        }
    }
}

private struct DeviceSidebarHeader: View {
    @EnvironmentObject var store: HeadphoneStore

    var body: some View {
        VStack(spacing: 8) {
            HeadphonesArt(finish: .init(colorName: store.state?.color ?? ""))
                .frame(width: 92, height: 92)
                .opacity(store.isConnected ? 1 : 0.45)
            Text(store.state?.modelName ?? store.device?.name ?? "No Headphones")
                .font(.headline)
            if let b = store.state?.primaryBattery, store.isConnected {
                BatteryPill(battery: b)
            } else {
                Text(store.isConnected ? "" : "Not connected").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

// MARK: - Sound

private struct SoundPane: View {
    @EnvironmentObject var store: HeadphoneStore
    var state: HeadphoneState

    var body: some View {
        Form {
            if let eq = state.equalizer {
                Section {
                    Picker("Preset", selection: Binding(get: { eq.preset }, set: { store.setEQPreset($0) })) {
                        ForEach(eq.presets) { Text($0.name).tag($0.id) }
                    }
                    if !eq.bands.isEmpty {
                        EQCurveEditor(bands: eq.bands, frequencies: eq.frequencies, range: eq.bandRange) {
                            store.setBands($0)
                        }
                        .padding(.vertical, 6)
                    }
                    if eq.clearBass == nil, eq.bands.count >= 3 {
                        LabeledContent("Bass") {
                            HStack {
                                Slider(value: Binding(get: { Double(eq.bands[0]) },
                                                      set: { v in
                                                          let i = Int(v.rounded())
                                                          if i != eq.bands[0] { store.setBassBoost(i) }
                                                      }),
                                       in: Double(eq.bandRange.lowerBound)...Double(eq.bandRange.upperBound))
                                Text(eq.bands[0] > 0 ? "+\(eq.bands[0])" : "\(eq.bands[0])")
                                    .monospacedDigit().frame(width: 28, alignment: .trailing)
                            }
                        }
                    }
                    if let cb = eq.clearBass {
                        LabeledContent("Clear Bass") {
                            HStack {
                                Slider(value: Binding(get: { Double(cb) },
                                                      set: { v in
                                                          let i = Int(v.rounded())
                                                          if i != cb { store.setClearBass(i) }
                                                      }),
                                       in: Double(eq.clearBassRange.lowerBound)...Double(eq.clearBassRange.upperBound))
                                Text(cb > 0 ? "+\(cb)" : "\(cb)").monospacedDigit().frame(width: 28, alignment: .trailing)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Equalizer")
                        Spacer()
                        Button("Reset") { store.resetBands() }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                } footer: {
                    if !EQPreset.isEditable(eq.preset) {
                        Text("Adjusting the curve switches to the Custom preset.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if eq.dseeAvailable {
                    Section {
                        Toggle(isOn: Binding(get: { eq.dseeEnabled }, set: { store.setDSEE($0) })) {
                            Text("DSEE Extreme")
                            Text("Upscales compressed music in real time.")
                        }
                    }
                }
            }
            if let eq = state.equalizer, !eq.bands.isEmpty {
                TuningSection(state: state, eq: eq)
            }
            if let l = state.listening {
                Section("Listening Mode") {
                    ListeningModePicker(listening: l)
                        .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Controls

private struct ControlsPane: View {
    @EnvironmentObject var store: HeadphoneStore
    var state: HeadphoneState

    var body: some View {
        Form {
            if !state.assignableKeys.isEmpty {
                Section("Buttons") {
                    ForEach(state.assignableKeys) { key in
                        Picker(Names.keyLocation(key.location, type: key.type),
                               selection: Binding(get: { key.action },
                                                  set: { store.setAssignable(location: key.location, action: $0) })) {
                            ForEach(key.options, id: \.self) { Text(Names.action($0)).tag($0) }
                        }
                    }
                }
            }
            if let n = state.noise, n.buttonMode != 0 {
                Section {
                    Picker("NC/AMB Button", selection: Binding(get: { n.buttonMode }, set: { store.setNoiseButton($0) })) {
                        Text("Noise Cancelling → Ambient → Off").tag(UInt32(MDR_NOISE_BUTTON_NOISE_AMBIENT_OFF))
                        Text("Noise Cancelling ↔ Ambient").tag(UInt32(MDR_NOISE_BUTTON_NOISE_AMBIENT))
                        Text("Noise Cancelling ↔ Off").tag(UInt32(MDR_NOISE_BUTTON_NOISE_OFF))
                        Text("Ambient ↔ Off").tag(UInt32(MDR_NOISE_BUTTON_AMBIENT_OFF))
                    }
                } footer: {
                    Text("What each press of the NC/AMB button cycles through.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let stc = state.speakToChat {
                Section {
                    Toggle(isOn: Binding(get: { stc.enabled }, set: { store.setSpeakToChat($0) })) {
                        Text("Speak-to-Chat")
                        Text("Pauses music and lets in ambient sound when you start talking.")
                    }
                }
            }
            let toggles = state.generalSettings
            if !toggles.isEmpty {
                Section("General") {
                    ForEach(toggles) { g in GeneralSettingRow(setting: g) }
                }
            }
            if let p = state.power, let g = p.headGesture {
                Section {
                    Toggle(isOn: Binding(get: { g }, set: { store.setHeadGesture($0) })) {
                        Text("Head Gestures")
                        Text("Nod or shake your head to answer or decline calls.")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralSettingRow: View {
    @EnvironmentObject var store: HeadphoneStore
    var setting: GeneralSetting

    var body: some View {
        switch setting.kind {
        case .toggle(let on):
            Toggle(isOn: Binding(get: { on }, set: { store.setGeneral(setting, toggle: $0) })) {
                Text(setting.title)
                if !setting.summary.isEmpty { Text(setting.summary) }
            }
            .disabled(!setting.writable)
        case .choice(let i, let opts):
            Picker(setting.title, selection: Binding(get: { i }, set: { store.setGeneral(setting, choice: $0) })) {
                ForEach(opts.indices, id: \.self) { Text(opts[$0]).tag($0) }
            }
            .disabled(!setting.writable)
        }
    }
}

// MARK: - Devices

private struct DevicesPane: View {
    @EnvironmentObject var store: HeadphoneStore
    var state: HeadphoneState

    var body: some View {
        Form {
            if let devices = state.pairedDevices {
                Section {
                    if devices.isEmpty {
                        Text("No paired devices reported.").foregroundStyle(.secondary)
                    }
                    ForEach(devices) { d in DeviceRow(device: d) }
                } header: {
                    Text("Paired Devices")
                } footer: {
                    Text("Your headphones can stay connected to two devices at once.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if state.autoSourceSwitch != nil || state.prioritizeQuality != nil {
                Section("Connection") {
                    if let a = state.autoSourceSwitch {
                        Toggle(isOn: Binding(get: { a }, set: { store.setAutoSourceSwitch($0) })) {
                            Text("Switch Automatically")
                            Text("Move playback to whichever device starts playing.")
                        }
                    }
                    if let q = state.prioritizeQuality {
                        Picker("Bluetooth Connection Quality",
                               selection: Binding(get: { q }, set: { store.setPrioritizeQuality($0) })) {
                            Text("Prioritize Sound Quality").tag(true)
                            Text("Prioritize Stable Connection").tag(false)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DeviceRow: View {
    @EnvironmentObject var store: HeadphoneStore
    var device: PairedDevice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Names.deviceSymbol(device.name))
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(device.connected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name.isEmpty ? device.mac : device.name)
                Text(device.isPlaybackSource ? "Playing" : device.connected ? "Connected" : "Not connected")
                    .font(.caption)
                    .foregroundStyle(device.isPlaybackSource ? Color.accentColor : .secondary)
            }
            Spacer()
            if device.connected {
                if !device.isPlaybackSource {
                    Button("Play Here") { store.pairedDevice(UInt32(MDR_PAIRED_DEVICE_SELECT_PLAYBACK), mac: device.mac) }
                }
                Button("Disconnect") { store.pairedDevice(UInt32(MDR_PAIRED_DEVICE_DISCONNECT), mac: device.mac) }
            } else {
                Button("Connect") { store.pairedDevice(UInt32(MDR_PAIRED_DEVICE_CONNECT), mac: device.mac) }
            }
        }
        .controlSize(.small)
        .contextMenu {
            Button("Forget Device", role: .destructive) {
                store.pairedDevice(UInt32(MDR_PAIRED_DEVICE_UNPAIR), mac: device.mac)
            }
        }
    }
}

// MARK: - System

private struct SystemPane: View {
    @EnvironmentObject var store: HeadphoneStore
    var state: HeadphoneState
    @AppStorage(Prefs.pauseOnRemove) private var pauseOnRemove = true
    @AppStorage(Prefs.resumeOnWear) private var resumeOnWear = true
    @AppStorage(Prefs.pauseOtherApps) private var pauseOtherApps = true
    @State private var confirmPowerOff = false
    @State private var axTrusted = MediaController.mediaKeyAllowed

    var body: some View {
        Form {
            Section {
                if let p = state.power, let ap = p.autoPause {
                    Toggle(isOn: Binding(get: { ap }, set: { store.setDeviceAutoPause($0) })) {
                        Text("Pause and Resume Automatically")
                        Text("Handled by the headphones' wear sensor: pauses whatever they're playing when you take them off and resumes when you put them back on.")
                    }
                }
                if state.power?.autoPause != true {
                    Toggle(isOn: $pauseOnRemove) {
                        Text(state.power?.autoPause == nil ? "Pause When Taken Off" : "Pause from SoundConnect Instead")
                        Text("Pauses Music, Spotify and other players on this Mac, and resumes them when you put your headphones back on.")
                    }
                    Toggle("Resume When Put Back On", isOn: $resumeOnWear)
                        .disabled(!pauseOnRemove)
                    if !state.supportsPlaybackControl {
                        Toggle(isOn: $pauseOtherApps) {
                            Text("Press Play/Pause for Other Apps")
                            Text("Like pressing F8, only while audio is playing and you're not on a call.")
                        }
                        .disabled(!pauseOnRemove)
                        .onChange(of: pauseOtherApps) { _, on in
                            if on, !MediaController.mediaKeyAllowed { MediaController.requestMediaKeyPermission() }
                        }
                        if pauseOtherApps, pauseOnRemove, !axTrusted {
                            HStack {
                                Label("SoundConnect needs permission to press play/pause.", systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                                Spacer()
                                Button("Allow…") {
                                    MediaController.requestMediaKeyPermission()
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("When You Take Your Headphones Off")
            }

            Section {
                if let p = state.power, let off = p.powerOffWhenRemoved {
                    Toggle(isOn: Binding(get: { off }, set: { store.setPowerOffWhenRemoved($0) })) {
                        Text("Power Off When Taken Off")
                        Text("Turns the headphones off a while after you take them off.")
                    }
                }
                if let p = state.power, p.autoPowerOffOptions.count > 1 {
                    Picker("Automatic Power Off",
                           selection: Binding(get: { p.autoPowerOffMinutes }, set: { store.setAutoPowerOff($0) })) {
                        ForEach(p.autoPowerOffOptions, id: \.self) { m in Text(Names.minutes(m)).tag(m) }
                    }
                }
            } header: {
                Text("Headphones")
            }

            if let vg = state.voiceGuidance {
                Section("Voice Guidance") {
                    Toggle("Voice Guidance", isOn: Binding(get: { vg.enabled },
                                                           set: { store.setVoiceGuidance(enabled: $0) }))
                    if let vol = vg.volume {
                        LabeledContent("Volume") {
                            Slider(value: Binding(get: { Double(vol) },
                                                  set: { v in
                                                      let i = Int(v.rounded())
                                                      if i != vol { store.setVoiceGuidance(volume: i) }
                                                  }),
                                   in: Double(vg.volumeRange.lowerBound)...Double(vg.volumeRange.upperBound)) {
                                EmptyView()
                            } minimumValueLabel: {
                                Image(systemName: "speaker.fill").font(.caption)
                            } maximumValueLabel: {
                                Image(systemName: "speaker.wave.3.fill").font(.caption)
                            }
                        }
                        .disabled(!vg.enabled)
                    }
                }
            }

            if state.supportsShutdown {
                Section {
                    Button("Turn Off Headphones…", role: .destructive) { confirmPowerOff = true }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axTrusted = MediaController.mediaKeyAllowed
        }
        .confirmationDialog("Turn off your headphones?", isPresented: $confirmPowerOff) {
            Button("Turn Off", role: .destructive) { store.powerOff() }
        }
    }
}

// MARK: - App

private struct AppPane: View {
    @AppStorage(Prefs.lowBatteryAlerts) private var lowBattery = true
    @AppStorage(Prefs.showBatteryInMenuBar) private var showBattery = true
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Open at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in LoginItem.set(v) }
                Toggle("Show Battery Level in Menu Bar", isOn: $showBattery)
            }
            Section {
                Toggle(isOn: $lowBattery) {
                    Text("Low Battery Notifications")
                    Text("Notify at 20% and 10%.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutPane: View {
    @EnvironmentObject var store: HeadphoneStore

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AppIconArt().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("SoundConnect").font(.title2.weight(.semibold))
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            if let s = store.state {
                Section("Headphones") {
                    LabeledContent("Model", value: s.modelName)
                    LabeledContent("Firmware", value: s.firmware)
                    if !s.color.isEmpty { LabeledContent("Colour", value: s.color.capitalized) }
                    if let d = store.device { LabeledContent("Address", value: d.address.uppercased()) }
                }
            }
            Section {
                Text("Protocol support by [SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient) (MIT). Not affiliated with Sony.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shared

/// Segmented listening mode control + BGM room picker. Used in the popover and Settings.
struct ListeningModePicker: View {
    @EnvironmentObject var store: HeadphoneStore
    var listening: ListeningState
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: Binding(get: { listening.mode }, set: { store.setListeningMode($0) })) {
                ForEach(listening.modes) { m in
                    Text(compact ? m.title : m.longTitle).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if listening.mode == .backgroundMusic {
                HStack(spacing: 6) {
                    ForEach(RoomSize.allCases) { r in
                        RoomTile(room: r, selected: listening.room == r) { store.setRoom(r) }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let reason = listening.modes.compactMap({ listening.blocked[$0] }).first {
                Label(reason, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.snappy(duration: 0.25), value: listening.mode)
    }
}

private struct RoomTile: View {
    var room: RoomSize
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: room.symbol).font(.system(size: 15, weight: .medium))
                Text(room.title).font(.system(size: 10.5, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Display names for raw libmdr enum values.
enum Names {
    static func action(_ a: UInt32) -> String {
        switch a {
        case MDR_ASSIGNABLE_NONE: "No Function"
        case MDR_ASSIGNABLE_PLAYBACK: "Playback Control"
        case MDR_ASSIGNABLE_NOISE_CONTROL: "Ambient Sound Control"
        case MDR_ASSIGNABLE_NOISE_CONTROL_QUICK_ACCESS, MDR_ASSIGNABLE_NOISE_CONTROL_QUICK_ACCESS_BT_CLASSIC_CAUTION:
            "Ambient Sound Control / Quick Access"
        case MDR_ASSIGNABLE_TRACK_CONTROL: "Track Control"
        case MDR_ASSIGNABLE_VOICE_RECOGNITION: "Voice Assistant"
        case MDR_ASSIGNABLE_GOOGLE_ASSISTANT, MDR_ASSIGNABLE_GOOGLE_ASSISTANT_BT_CLASSIC_CAUTION: "Google Assistant"
        case MDR_ASSIGNABLE_AMAZON_ALEXA, MDR_ASSIGNABLE_AMAZON_ALEXA_BT_CLASSIC_CAUTION: "Amazon Alexa"
        case MDR_ASSIGNABLE_TENCENT_XIAOWEI, MDR_ASSIGNABLE_TENCENT_XIAOWEI_BT_CLASSIC_CAUTION,
             MDR_ASSIGNABLE_TENCENT_XIAOWEI_Q_MSC, MDR_ASSIGNABLE_TENCENT_XIAOWEI_Q_MSC_BT_CLASSIC_CAUTION: "Tencent Xiaowei"
        case MDR_ASSIGNABLE_MICROSOFT_CORTANA: "Cortana"
        case MDR_ASSIGNABLE_QUICK_ACCESS, MDR_ASSIGNABLE_QUICK_ACCESS_BT_CLASSIC_CAUTION: "Quick Access"
        case MDR_ASSIGNABLE_VOLUME: "Volume Control"
        case MDR_ASSIGNABLE_PLAYBACK_VOICE_ASSISTANT_LIMITATION: "Playback Control"
        case MDR_ASSIGNABLE_TEAMS: "Microsoft Teams"
        case MDR_ASSIGNABLE_NOISE_CONTROL_MIC: "Ambient Sound Control / Mic"
        case MDR_ASSIGNABLE_LISTENING_MODE_QUICK_ACCESS: "Listening Mode / Quick Access"
        case MDR_ASSIGNABLE_NOISE_CONTROL_LISTENING_MODE: "Ambient Sound Control / Listening Mode"
        case MDR_ASSIGNABLE_CHAT_MIX: "Chat Mix"
        case MDR_ASSIGNABLE_CUSTOM1: "Custom 1"
        case MDR_ASSIGNABLE_CUSTOM2: "Custom 2"
        default: "Other"
        }
    }

    static func keyLocation(_ loc: UInt32, type: UInt32) -> String {
        let touch = type == MDR_ASSIGNABLE_ACTION_KEY_TYPE_TOUCH_SENSOR
        switch loc {
        case MDR_ASSIGNABLE_ACTION_KEY_LEFT: return touch ? "Left Touch Sensor" : "Left Button"
        case MDR_ASSIGNABLE_ACTION_KEY_RIGHT: return touch ? "Right Touch Sensor" : "Right Button"
        case MDR_ASSIGNABLE_ACTION_KEY_CUSTOM: return "Custom Button"
        case MDR_ASSIGNABLE_ACTION_KEY_C: return "C Button"
        case MDR_ASSIGNABLE_ACTION_KEY_NC_AMB, MDR_ASSIGNABLE_ACTION_KEY_NC_AMBIENT: return "NC/AMB Button"
        default: return touch ? "Touch Sensor" : "Button"
        }
    }

    static func minutes(_ m: Int) -> String {
        if m == 0 { return "Never" }
        if m % 60 == 0 { return m == 60 ? "1 hour" : "\(m / 60) hours" }
        return "\(m) minutes"
    }

    static func deviceSymbol(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("iphone") { return "iphone" }
        if n.contains("ipad") { return "ipad" }
        if n.contains("macbook") || n.contains("mac") { return "laptopcomputer" }
        if n.contains("pixel") || n.contains("galaxy") || n.contains("phone") { return "smartphone" }
        if n.contains("tv") { return "tv" }
        if n.contains("pc") || n.contains("desktop") || n.contains("windows") { return "desktopcomputer" }
        return "dot.radiowaves.left.and.right"
    }
}
