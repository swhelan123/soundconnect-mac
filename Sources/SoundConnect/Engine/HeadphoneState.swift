import CMDR
import Foundation

// MARK: - Swift-side models

enum NoiseMode: UInt32, CaseIterable, Identifiable {
    case cancelling = 1   // MDR_NOISE_MODE_CANCELLING
    case ambient = 2      // MDR_NOISE_MODE_AMBIENT
    case off = 0          // MDR_NOISE_MODE_OFF
    case wind = 3         // MDR_NOISE_MODE_WIND_NOISE_REDUCTION

    var id: UInt32 { rawValue }

    var title: String {
        switch self {
        case .cancelling: "Noise Cancelling"
        case .ambient: "Ambient Sound"
        case .off: "Off"
        case .wind: "Wind Reduction"
        }
    }

    var shortTitle: String {
        switch self {
        case .cancelling: "Cancelling"
        case .ambient: "Ambient"
        case .off: "Off"
        case .wind: "Wind"
        }
    }

    var symbol: String {
        switch self {
        case .cancelling: "waveform.slash"
        case .ambient: "ear.and.waveform"
        case .off: "circle.slash"
        case .wind: "wind"
        }
    }
}

struct Battery: Equatable, Identifiable {
    enum Part: UInt32 { case main = 0, left, right, `case` }
    var part: Part
    var level: Int
    var charging: Bool
    var id: UInt32 { part.rawValue }

    var label: String {
        switch part {
        case .main: "Headphones"
        case .left: "Left"
        case .right: "Right"
        case .case: "Case"
        }
    }
}

struct NoiseState: Equatable {
    var mode: NoiseMode = .off
    var ambientLevel: Int = 10
    var focusOnVoice = false
    var adaptiveAmbient = false
    var buttonMode: UInt32 = 0
    /// Untouched raw struct so writes preserve fields we don't surface.
    var raw = MDRNoiseControl()

    static func == (a: NoiseState, b: NoiseState) -> Bool {
        a.mode == b.mode && a.ambientLevel == b.ambientLevel && a.focusOnVoice == b.focusOnVoice
            && a.adaptiveAmbient == b.adaptiveAmbient && a.buttonMode == b.buttonMode
    }
}

struct EQPreset: Equatable, Identifiable, Hashable {
    var id: UInt32
    var name: String

    // Indexed by MDREqualizerPreset (MDR_EQ_*). Devices usually don't send names for built-in presets.
    private static let names = [
        "Off", "Rock", "Pop", "Jazz", "Dance", "EDM", "R&B / Hip-Hop", "Acoustic", "Bright", "Excited",
        "Mellow", "Relaxed", "Vocal", "Treble", "Bass", "Speech", "Heavy", "Clear", "Hard", "Soft",
        "Gaming", "FPS 1", "FPS 2", "FPS 3", "Custom", "Custom 1", "Custom 2", "Custom 3", "Custom 4", "Custom 5",
    ]

    static func defaultName(_ id: UInt32) -> String {
        id < names.count ? names[Int(id)] : "Preset \(id)"
    }

    static let custom: UInt32 = 24 // MDR_EQ_CUSTOM
    /// Presets whose band values the user may edit. Everything else is switched to Custom first.
    static func isEditable(_ id: UInt32) -> Bool { (24...29).contains(id) }
}

struct EqualizerState: Equatable {
    var preset: UInt32
    var presets: [EQPreset]
    var bands: [Int]
    var frequencies: [Int]
    var bandRange: ClosedRange<Int>
    var clearBass: Int?
    var clearBassRange: ClosedRange<Int>
    var dseeAvailable: Bool
    var dseeEnabled: Bool
}

struct SpeakToChatState: Equatable {
    var enabled: Bool
    var raw: MDRSpeakToChat
    static func == (a: Self, b: Self) -> Bool { a.enabled == b.enabled }
}

enum ListeningMode: UInt32, CaseIterable, Identifiable {
    case standard = 0     // MDR_LISTENING_STANDARD
    case backgroundMusic  // MDR_LISTENING_BACKGROUND_MUSIC
    case cinema           // MDR_LISTENING_CINEMA

    var id: UInt32 { rawValue }
    var title: String {
        switch self {
        case .standard: "Standard"
        case .backgroundMusic: "BGM"
        case .cinema: "Cinema"
        }
    }
    var longTitle: String {
        switch self {
        case .standard: "Standard"
        case .backgroundMusic: "Background Music"
        case .cinema: "Cinema"
        }
    }
    var symbol: String {
        switch self {
        case .standard: "music.note"
        case .backgroundMusic: "sofa"
        case .cinema: "film"
        }
    }
}

enum RoomSize: UInt32, CaseIterable, Identifiable {
    case small = 1, medium, large  // MDR_ROOM_*
    var id: UInt32 { rawValue }
    var title: String {
        switch self {
        case .small: "My Room"
        case .medium: "Living Room"
        case .large: "Café"
        }
    }
    var symbol: String {
        switch self {
        case .small: "bed.double"
        case .medium: "sofa"
        case .large: "cup.and.saucer"
        }
    }
}

struct ListeningState: Equatable {
    var mode: ListeningMode
    var room: RoomSize
    /// Modes the device supports, mapped to a reason string when currently refused.
    var modes: [ListeningMode]
    var blocked: [ListeningMode: String]
    var raw: MDRListening

    static func == (a: Self, b: Self) -> Bool {
        a.mode == b.mode && a.room == b.room && a.modes == b.modes && a.blocked == b.blocked
    }
}

struct PlaybackState: Equatable {
    var playing: Bool
    var title: String
    var artist: String
    var volume: Int
}

struct PowerState: Equatable {
    var autoPowerOffMinutes: Int
    var autoPowerOffOptions: [Int]
    var powerOffWhenRemoved: Bool?
    var autoPause: Bool?
    var headGesture: Bool?
    var raw: MDRPower

    static func == (a: Self, b: Self) -> Bool {
        a.autoPowerOffMinutes == b.autoPowerOffMinutes && a.autoPowerOffOptions == b.autoPowerOffOptions
            && a.powerOffWhenRemoved == b.powerOffWhenRemoved && a.autoPause == b.autoPause
            && a.headGesture == b.headGesture
    }
}

struct VoiceGuidanceState: Equatable {
    var enabled: Bool
    var volume: Int?
    var volumeRange: ClosedRange<Int>
}

struct AssignableKey: Equatable, Identifiable {
    var location: UInt32
    var type: UInt32
    var action: UInt32
    var options: [UInt32]
    var id: UInt32 { location }
}

struct PairedDevice: Equatable, Identifiable {
    var mac: String
    var name: String
    var connected: Bool
    var isPlaybackSource: Bool
    var id: String { mac }
}

struct GeneralSetting: Equatable, Identifiable {
    enum Kind: Equatable { case toggle(Bool), choice(Int, [String]) }
    var index: UInt32
    var title: String
    var summary: String
    var writable: Bool
    var kind: Kind
    var id: UInt32 { index }
}

struct HeadphoneState: Equatable {
    var modelName = ""
    var firmware = ""
    var color = ""
    var batteries: [Battery] = []

    var supportsNoiseCancelling = false
    var supportsAmbient = false
    var supportsAdaptiveAmbient = false
    var supportsWind = false
    var noise: NoiseState?
    var ambientRange: ClosedRange<Int> = 0...20

    var speakToChat: SpeakToChatState?
    var listening: ListeningState?
    var equalizer: EqualizerState?
    var playback: PlaybackState?
    var supportsPlaybackControl = false
    var worn: Bool?

    var power: PowerState?
    var voiceGuidance: VoiceGuidanceState?
    var assignableKeys: [AssignableKey] = []
    var pairedDevices: [PairedDevice]?
    var autoSourceSwitch: Bool?
    var prioritizeQuality: Bool?
    var generalSettings: [GeneralSetting] = []
    var supportsShutdown = false
    /// Current listening level in dB as measured by the headphones; nil when nothing is playing.
    var soundPressure: Int?

    var availableModes: [NoiseMode] {
        var m: [NoiseMode] = []
        if supportsNoiseCancelling { m.append(.cancelling) }
        if supportsAmbient { m.append(.ambient) }
        if supportsWind { m.append(.wind) }
        m.append(.off)
        return m
    }

    var primaryBattery: Battery? {
        batteries.first { $0.part == .main } ?? batteries.filter { $0.part != .case }.min { $0.level < $1.level }
    }
}

// MARK: - Reading from libmdr (worker thread only)

struct Reader {
    let hp: OpaquePointer
    init(_ hp: OpaquePointer) { self.hp = hp }

    func has(_ feature: UInt32) -> Bool {
        var a: MDRFeatureAvailability = 0
        return mdrHeadphonesGetFeature(hp, MDRFeature(feature), &a) == kOK && a == MDR_AVAILABILITY_AVAILABLE
    }

    func text(_ t: MDRText, _ index: UInt32 = 0) -> String {
        var size: UInt32 = 1024
        var buf = [CChar](repeating: 0, count: Int(size))
        guard mdrHeadphonesGetText(hp, t, index, &buf, &size) == kOK else { return "" }
        buf[buf.count - 1] = 0
        return String(cString: buf)
    }

    func value(_ v: UInt32, _ index: UInt32 = 0) -> Int? {
        var out: Int32 = 0
        return mdrHeadphonesGetValue(hp, MDRValue(v), index, &out) == kOK ? Int(out) : nil
    }

    func range(_ lo: UInt32, _ hi: UInt32, _ index: UInt32 = 0) -> ClosedRange<Int>? {
        guard let a = value(lo, index), let b = value(hi, index), a < b else { return nil }
        return a...b
    }

    /// Read a variable-length list through an `(buffer, inout count)` C API.
    func list<T>(capacity: Int = 32, empty: T, _ fn: (UnsafeMutablePointer<T>, UnsafeMutablePointer<UInt32>) -> MDRResult) -> [T]? {
        var n = UInt32(capacity)
        var buf = [T](repeating: empty, count: capacity)
        guard fn(&buf, &n) == kOK else { return nil }
        return Array(buf.prefix(Int(n)))
    }
}

/// Fixed-size C `char[N]` tuple -> String.
func cString<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        let bytes = raw.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension HeadphoneState {
    static func read(from hp: OpaquePointer) -> HeadphoneState {
        let r = Reader(hp)
        let desired = MDRPropertyType(MDR_PROPERTY_DESIRED)
        var s = HeadphoneState()

        s.modelName = r.text(MDRText(MDR_TEXT_MODEL_NAME))
        s.firmware = r.text(MDRText(MDR_TEXT_FIRMWARE_VERSION))
        s.color = r.text(MDRText(MDR_TEXT_MODEL_COLOR))

        // Batteries
        if let batts = r.list(capacity: 4, empty: MDRBattery(), { mdrHeadphonesGetBatteries(hp, $0, $1) }) {
            s.batteries = batts.compactMap { b in
                guard let part = Battery.Part(rawValue: b.part) else { return nil }
                return Battery(part: part, level: Int(b.level_percent), charging: b.charging == MDR_CHARGING_YES)
            }
        }

        // Noise control
        s.supportsNoiseCancelling = r.has(MDR_FEATURE_NOISE_CANCELLING)
        s.supportsAmbient = r.has(MDR_FEATURE_AMBIENT_SOUND)
        s.supportsAdaptiveAmbient = r.has(MDR_FEATURE_ADAPTIVE_AMBIENT_SOUND)
        s.supportsWind = r.has(MDR_FEATURE_WIND_NOISE_REDUCTION)
        var nc = MDRNoiseControl()
        if mdrHeadphonesGetNoiseControl(hp, desired, &nc) == kOK {
            s.noise = NoiseState(mode: NoiseMode(rawValue: nc.mode) ?? .off,
                                 ambientLevel: Int(nc.ambient_level),
                                 focusOnVoice: nc.focus_on_voice == MDR_TRUE,
                                 adaptiveAmbient: nc.adaptive_ambient == MDR_TRUE,
                                 buttonMode: r.has(MDR_FEATURE_NOISE_CONTROL_BUTTON) ? nc.button_mode : 0,
                                 raw: nc)
        }
        if let rg = r.range(MDR_VALUE_AMBIENT_LEVEL_MIN, MDR_VALUE_AMBIENT_LEVEL_MAX) { s.ambientRange = rg }

        // Speak to chat
        if r.has(MDR_FEATURE_SPEAK_TO_CHAT) {
            var stc = MDRSpeakToChat()
            if mdrHeadphonesGetSpeakToChat(hp, desired, &stc) == kOK {
                s.speakToChat = SpeakToChatState(enabled: stc.enabled == MDR_TRUE, raw: stc)
            }
        }

        s.listening = readListening(r)
        s.equalizer = readEqualizer(r)

        // Playback
        s.supportsPlaybackControl = r.has(MDR_FEATURE_PLAYBACK_CONTROL)
        if r.has(MDR_FEATURE_PLAYBACK_METADATA) || s.supportsPlaybackControl {
            var pb = MDRPlayback()
            if mdrHeadphonesGetPlayback(hp, desired, &pb) == kOK {
                s.playback = PlaybackState(playing: pb.status == MDR_PLAYBACK_PLAYING,
                                           title: r.text(MDRText(MDR_TEXT_TRACK_TITLE)),
                                           artist: r.text(MDRText(MDR_TEXT_TRACK_ARTIST)),
                                           volume: Int(pb.volume))
            }
        }

        // Wearing
        if r.has(MDR_FEATURE_WEARING_STATUS) {
            var w: MDRWearingStatus = 0
            if mdrHeadphonesGetWearingStatus(hp, &w) == kOK, w != MDR_WEARING_STATUS_UNKNOWN {
                s.worn = w == MDR_WEARING_STATUS_WORN
            }
        }

        s.power = readPower(r)

        if r.has(MDR_FEATURE_VOICE_GUIDANCE) {
            var vg = MDRVoiceGuidance()
            if mdrHeadphonesGetVoiceGuidance(hp, desired, &vg) == kOK {
                let range = r.range(MDR_VALUE_VOICE_GUIDANCE_VOLUME_MIN, MDR_VALUE_VOICE_GUIDANCE_VOLUME_MAX)
                s.voiceGuidance = VoiceGuidanceState(
                    enabled: vg.enabled == MDR_TRUE,
                    volume: r.has(MDR_FEATURE_VOICE_GUIDANCE_VOLUME) && range != nil ? Int(vg.volume) : nil,
                    volumeRange: range ?? -2...2)
            }
        }

        if r.has(MDR_FEATURE_ASSIGNABLE_CONTROLS),
           let keys = r.list(capacity: 8, empty: MDRAssignableControl(), {
               mdrHeadphonesGetAssignableControls(hp, desired, $0, $1)
           }) {
            s.assignableKeys = keys.map { k in
                let opts = r.list(capacity: 32, empty: MDRAssignableAction(0)) {
                    mdrHeadphonesGetAssignableControlActions(hp, k.location, $0, $1)
                } ?? []
                return AssignableKey(location: k.location, type: k.type, action: k.action, options: opts)
            }
        }

        if r.has(MDR_FEATURE_PAIRED_DEVICE_MANAGEMENT),
           let devs = r.list(capacity: 16, empty: MDRPairedDevice(), { mdrHeadphonesGetPairedDevices(hp, $0, $1) }) {
            s.pairedDevices = devs.map {
                PairedDevice(mac: cString($0.macAddress), name: cString($0.name),
                             connected: $0.connected == MDR_TRUE, isPlaybackSource: $0.playback_device == MDR_TRUE)
            }
        }
        if r.has(MDR_FEATURE_SOURCE_SWITCH_CONTROL) {
            var b: MDRBoolean = 0
            if mdrHeadphonesGetSourceSwitchControl(hp, desired, &b) == kOK { s.autoSourceSwitch = b == MDR_TRUE }
        }
        if r.has(MDR_FEATURE_CONNECTION_MODE) {
            var cm = MDRConnectionMode()
            if mdrHeadphonesGetConnectionMode(hp, desired, &cm) == kOK, cm.audio_priority != MDR_AUDIO_PRIORITY_UNKNOWN {
                s.prioritizeQuality = cm.audio_priority == MDR_AUDIO_PRIORITY_QUALITY
            }
        }

        s.generalSettings = readGeneralSettings(r)
        s.supportsShutdown = r.has(MDR_FEATURE_SHUTDOWN)
        if r.has(MDR_FEATURE_SAFE_LISTENING) {
            var safe = MDRSafeListening()
            if mdrHeadphonesGetSafeListening(hp, MDRPropertyType(MDR_PROPERTY_CURRENT), &safe) == kOK,
               safe.sound_pressure != 0xff, safe.sound_pressure > 0 {
                s.soundPressure = Int(safe.sound_pressure)
            }
        }
        return s
    }

    private static func readListening(_ r: Reader) -> ListeningState? {
        guard r.has(MDR_FEATURE_LISTENING_MODE) else { return nil }
        var l = MDRListening()
        guard mdrHeadphonesGetListening(r.hp, MDRPropertyType(MDR_PROPERTY_DESIRED), &l) == kOK else { return nil }
        var modes: [ListeningMode] = [.standard]
        if r.has(MDR_FEATURE_LISTENING_BACKGROUND_MUSIC) { modes.append(.backgroundMusic) }
        if r.has(MDR_FEATURE_LISTENING_CINEMA) { modes.append(.cinema) }
        guard modes.count > 1 else { return nil }
        var blocked: [ListeningMode: String] = [:]
        for m in modes where m != .standard {
            var st = MDRListeningStatus()
            if mdrHeadphonesGetListeningStatus(r.hp, m.rawValue, &st) == kOK, st.available != MDR_TRUE {
                blocked[m] = blockerText(st.blockers)
            }
        }
        return ListeningState(mode: ListeningMode(rawValue: l.mode) ?? .standard,
                              room: RoomSize(rawValue: l.background_room) ?? .small,
                              modes: modes, blocked: blocked, raw: l)
    }

    private static func blockerText(_ b: MDRListeningBlocker) -> String {
        if b & (1 << 0) != 0 { return "Unavailable during calls" }
        if b & (1 << 1) != 0 { return "Unavailable with LE Audio" }
        if b & (1 << 2) != 0 { return "Unavailable while Voice Control is on" }
        if b & (1 << 3) != 0 { return "Turn off the other listening mode first" }
        return "Currently unavailable"
    }

    private static func readEqualizer(_ r: Reader) -> EqualizerState? {
        guard r.has(MDR_FEATURE_EQUALIZER) else { return nil }
        let desired = MDRPropertyType(MDR_PROPERTY_DESIRED)
        var eq = MDREqualizer()
        guard mdrHeadphonesGetEqualizer(r.hp, desired, &eq) == kOK, eq.available == MDR_TRUE else { return nil }
        let presetIDs = r.list(capacity: 64, empty: MDREqualizerPreset(0)) {
            mdrHeadphonesGetEqualizerPresets(r.hp, $0, $1)
        } ?? []
        let presets = presetIDs.enumerated().compactMap { (i, p) -> EQPreset? in
            guard p != MDR_EQ_UNKNOWN else { return nil }
            let name = r.text(MDRText(MDR_TEXT_EQUALIZER_PRESET_NAME), UInt32(i))
            return EQPreset(id: p, name: name.isEmpty ? EQPreset.defaultName(p) : name)
        }
        let bands = (r.list(capacity: 16, empty: Int32(0)) { mdrHeadphonesGetEqualizerBands(r.hp, desired, $0, $1) } ?? [])
            .map(Int.init)
        let n = UInt32(bands.count)
        let freqs = (0..<n).map { r.value(MDR_VALUE_EQUALIZER_BAND_FREQUENCY, $0) ?? 0 }
        // Clear Bass only exists in some band layouts; the value range query fails when it doesn't.
        let cbRange = r.range(MDR_VALUE_EQUALIZER_CLEAR_BASS_MIN, MDR_VALUE_EQUALIZER_CLEAR_BASS_MAX)
        return EqualizerState(
            preset: eq.preset, presets: presets, bands: bands, frequencies: freqs,
            bandRange: r.range(MDR_VALUE_EQUALIZER_BAND_MIN, MDR_VALUE_EQUALIZER_BAND_MAX, n) ?? -10...10,
            clearBass: cbRange != nil ? Int(eq.clear_bass) : nil,
            clearBassRange: cbRange ?? -10...10,
            dseeAvailable: eq.dsee_available == MDR_TRUE, dseeEnabled: eq.dsee_enabled == MDR_TRUE)
    }

    private static func readPower(_ r: Reader) -> PowerState? {
        var p = MDRPower()
        guard mdrHeadphonesGetPower(r.hp, MDRPropertyType(MDR_PROPERTY_DESIRED), &p) == kOK else { return nil }
        let count = r.value(MDR_VALUE_AUTO_POWER_OFF_OPTION_COUNT) ?? 0
        let options = (0..<UInt32(max(count, 0))).compactMap { r.value(MDR_VALUE_AUTO_POWER_OFF_OPTION, $0) }
        return PowerState(
            autoPowerOffMinutes: Int(p.auto_power_off_minutes),
            autoPowerOffOptions: r.has(MDR_FEATURE_AUTO_POWER_OFF) ? options : [],
            powerOffWhenRemoved: p.wearing_power == MDR_WEARING_POWER_UNAVAILABLE ? nil
                : p.wearing_power == MDR_WEARING_POWER_WHEN_REMOVED,
            autoPause: r.has(MDR_FEATURE_AUTO_PAUSE) ? p.auto_pause == MDR_TRUE : nil,
            headGesture: r.has(MDR_FEATURE_HEAD_GESTURE) ? p.head_gesture == MDR_TRUE : nil,
            raw: p)
    }

    private static func readGeneralSettings(_ r: Reader) -> [GeneralSetting] {
        guard r.has(MDR_FEATURE_GENERAL_SETTINGS),
              let infos = r.list(capacity: 32, empty: MDRGeneralSettingInfo(), {
                  mdrHeadphonesGetGeneralSettingInfo(r.hp, $0, $1)
              }) else { return [] }
        return infos.compactMap { info in
            var v = MDRGeneralSetting()
            guard mdrHeadphonesGetGeneralSetting(r.hp, MDRPropertyType(MDR_PROPERTY_DESIRED), info.index, &v) == kOK
            else { return nil }
            let isKey = info.text_is_key == MDR_TRUE
            let title = SettingText.display(r.text(MDRText(MDR_TEXT_GENERAL_SETTING_SUBJECT), info.index), isKey: isKey)
            let summary = SettingText.summary(r.text(MDRText(MDR_TEXT_GENERAL_SETTING_SUMMARY), info.index), isKey: isKey)
            let kind: GeneralSetting.Kind
            switch info.type {
            case MDRGeneralSettingType(MDR_GENERAL_SETTING_BOOLEAN):
                kind = .toggle(v.boolean_value == MDR_TRUE)
            case MDRGeneralSettingType(MDR_GENERAL_SETTING_LIST):
                let opts = (0..<info.option_count).map { o -> String in
                    let idx = (o << 8) | (info.index & 0xff) // MDR_GENERAL_SETTING_OPTION_INDEX
                    let optKey = r.value(MDR_VALUE_GENERAL_SETTING_OPTION_TEXT_IS_KEY, idx) == 1
                    return SettingText.display(r.text(MDRText(MDR_TEXT_GENERAL_SETTING_OPTION_SUBJECT), idx), isKey: optKey)
                }
                kind = .choice(Int(v.list_value), opts)
            default:
                return nil
            }
            return GeneralSetting(index: info.index, title: title, summary: summary,
                                  writable: info.writable == MDR_TRUE, kind: kind)
        }
    }
}

/// Device-sent identifier keys (e.g. "SIDETONE_SETTING") -> display text.
enum SettingText {
    private static let known: [String: String] = [
        "SIDETONE_SETTING": "Capture Voice During a Phone Call",
        "MULTIPOINT_SETTING": "Connect to 2 Devices Simultaneously",
        "TOUCH_SENSOR_SETTING": "Touch Sensor Control Panel",
        "TOUCH_PANEL_SETTING": "Touch Sensor Control Panel",
    ]
    private static let knownSummaries: [String: String] = [
        "SIDETONE_SETTING_SUMMARY": "Hear your own voice through the headphones during calls.",
        "MULTIPOINT_SETTING_SUMMARY": "Stay connected to two devices at once.",
        "MULTIPOINT_SETTING_SUMMARY_LDAC_AVAILABLE": "Stay connected to two devices at once. LDAC remains available.",
    ]

    /// Summaries that are untranslated identifiers would read as noise, so unknown ones are dropped.
    static func summary(_ text: String, isKey: Bool) -> String {
        guard isKey else { return text }
        return knownSummaries[text] ?? ""
    }

    static func display(_ text: String, isKey: Bool) -> String {
        guard isKey, !text.isEmpty else { return text }
        if let k = known[text] { return k }
        let words = text.replacingOccurrences(of: "_SETTING", with: "")
            .split(separator: "_").map { $0.lowercased() }
        guard let first = words.first else { return text }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }
}
