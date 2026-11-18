import CMDR
import Foundation
import IOBluetooth
import SwiftUI
import os

let log = Logger(subsystem: "dev.soundconnect.mac", category: "store")

/// Main-actor façade the UI binds to. Forwards writes to the engine thread and
/// republishes the snapshots it produces.
@MainActor
final class HeadphoneStore: ObservableObject {
    enum Status: Equatable {
        case searching
        case connecting(String)
        case connected
        case failed(String)
    }

    @Published private(set) var status: Status = .searching
    @Published private(set) var device: SonyDevice?
    @Published private(set) var state: HeadphoneState?
    @Published var alert: String?
    let insights: Insights

    private let engine = MDREngine()
    private let isPreview: Bool
    private var retryTimer: Timer?
    private var connectNotification: IOBluetoothUserNotification?
    private let notifier = BatteryNotifier()
    private let media = MediaController()
    /// Set when we asked the headphones to pause their playback device, so we only resume what we paused.
    private var pausedViaDevice = false
    /// Consecutive failed connection attempts; the first few are retried quietly (e.g. the channel
    /// is still being released by a previous instance).
    private var failedAttempts = 0

    /// Static store for design previews (no Bluetooth).
    init(preview state: HeadphoneState?, status: Status, insights: Insights? = nil) {
        isPreview = true
        self.insights = insights ?? Insights(preview: HistoryFile())
        self.state = state
        self.status = status
        self.device = SonyDevice(name: "WH-1000XM6", address: "", serviceUUID: "", protocolVersion: 2)
    }

    private var insightsTimer: Timer?

    init() {
        isPreview = false
        insights = Insights()
        engine.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        engine.start()
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.connectIfNeeded() }
        }
        insightsTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.insights.tick(worn: self?.state?.worn) }
        }
        connectIfNeeded()
    }

    var isConnected: Bool { status == .connected && state != nil }

    // MARK: - Connection

    func connectIfNeeded() {
        guard !isPreview else { return }
        switch status {
        case .searching, .failed: break
        case .connecting, .connected: return
        }
        guard let d = DeviceFinder.findConnected() else {
            device = nil
            if case .failed = status {} else { status = .searching }
            return
        }
        device = d
        log.info("found \(d.name, privacy: .public) \(d.address, privacy: .public)")
        status = .connecting(d.name)
        engine.connect(address: d.address, serviceUUID: d.serviceUUID, protocolVersion: d.protocolVersion)
    }

    /// The headphones only measure listening level while their Safe Listening mode is on (otherwise the
    /// reply carries error cause 0x03 and level 0). It's the same switch Sony's app flips; measurement only.
    private func enableSafeListeningMeasurement() {
        guard UserDefaults.standard.bool(forKey: Prefs.trackExposure) else { return }
        perform({ hp in
            var cur = MDRSafeListening()
            guard mdrHeadphonesGetSafeListening(hp, MDRPropertyType(MDR_PROPERTY_DESIRED), &cur) == kOK,
                  cur.preview != MDR_TRUE else { return kOK }
            cur.preview = MDR_TRUE
            return mdrHeadphonesSetSafeListening(hp, &cur)
        }, "safeListeningOn")
    }

    @Published private(set) var resettingLink = false

    func resetConnection() {
        guard let d = device ?? DeviceFinder.findConnected() else { reconnect(); return }
        log.info("resetting Bluetooth link")
        resettingLink = true
        engine.disconnect()
        state = nil
        status = .connecting(d.name)
        DeviceFinder.resetLink(address: d.address) { [weak self] in
            guard let self else { return }
            self.resettingLink = false
            self.failedAttempts = 0
            self.status = .searching
            self.connectIfNeeded()
        }
    }

    func shutdown() {
        guard !isPreview else { return }
        engine.shutdown()
    }

    func reconnect() {
        failedAttempts = 0
        engine.disconnect()
        state = nil
        status = .searching
        connectIfNeeded()
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        // Give the headset a moment to bring up its profiles before we open RFCOMM.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connectIfNeeded() }
    }

    private func handle(_ event: MDREngine.Event) {
        switch event {
        case .phase(let p):
            log.info("phase \(String(describing: p), privacy: .public)")
            switch p {
            case .idle:
                if status == .connected { insights.disconnected() }
                if case .failed = status {} else { status = .searching }
                state = nil
                pausedViaDevice = false
                media.forget()
            case .connecting, .initializing:
                status = .connecting(device?.name ?? "Headphones")
            case .ready:
                status = .connected
                failedAttempts = 0
                insights.connected()
                enableSafeListeningMeasurement()
            }
        case .state(let s):
            let previous = state
            withAnimation(.snappy) { state = s }
            insights.record(s)
            // Use the playback status from *before* this snapshot: by the time the headphones report
            // removal, their own auto-pause may already have flipped it to paused.
            onWearingChange(from: previous?.worn, to: s.worn, playback: previous?.playback ?? s.playback)
            notifier.update(battery: s.primaryBattery, model: s.modelName)
        case .failed(let msg):
            log.error("failed: \(msg, privacy: .public)")
            state = nil
            failedAttempts += 1
            if failedAttempts < 3 {
                status = .searching
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connectIfNeeded() }
            } else {
                status = .failed(msg)
            }
        case .alert(let msg):
            alert = msg
        }
    }

    // MARK: - Off-head pause / resume

    /// Pause on removal / resume on wear.
    ///
    /// If the headphones' own auto-pause is on, they already pause *and* resume their playback device
    /// over AVRCP, and anything we add on top fights them (a play/pause toggle un-pauses it). So the app
    /// only acts as a fallback when that setting is off or unsupported:
    ///  - Music / Spotify: explicit AppleScript pause/play.
    ///  - Otherwise: explicit PAUSE/PLAY to the headphones if they accept playback commands, else the
    ///    play/pause key. "Was playing" comes from the Mac's output being active, because the XM6's own
    ///    playback status isn't reliable for browser audio.
    private func onWearingChange(from old: Bool?, to new: Bool?, playback: PlaybackState?) {
        guard let old, let new, old != new else { return }
        let deviceHandles = state?.power?.autoPause == true
        let d = UserDefaults.standard
        if !new {
            log.info("headphones removed (device auto-pause: \(deviceHandles))")
            guard !deviceHandles, d.bool(forKey: Prefs.pauseOnRemove) else { return }
            let wasPlaying = playback?.playing == true || MediaController.outputIsRunning()
            let canCommand = state?.supportsPlaybackControl == true
            media.pauseIfPlaying(allowMediaKey: !canCommand && d.bool(forKey: Prefs.pauseOtherApps))
            if canCommand, wasPlaying, !media.hasPausedSomething {
                pausedViaDevice = true
                sendPlayback(UInt32(MDR_PLAYBACK_PAUSE))
            }
        } else {
            log.info("headphones back on")
            if d.bool(forKey: Prefs.resumeOnWear) {
                media.resume()
                if pausedViaDevice { sendPlayback(UInt32(MDR_PLAYBACK_PLAY)) }
            } else {
                media.forget()
            }
            pausedViaDevice = false
        }
    }

    // MARK: - Writes
    // Each setter updates published state optimistically so controls feel instant; the engine's next
    // snapshot (read from DESIRED) confirms or corrects it.

    private func mutate(_ f: (inout HeadphoneState) -> Void) {
        guard var s = state else { return }
        f(&s)
        state = s
    }

    private func perform(_ body: @escaping (OpaquePointer) -> MDRResult, _ what: String) {
        log.debug("write \(what, privacy: .public)")
        engine.perform { hp in
            let r = body(hp)
            if r != kOK { log.error("\(what, privacy: .public) failed: \(String(cString: mdrResultString(r)), privacy: .public)") }
        }
    }

    private func writeNoise(_ edit: (inout MDRNoiseControl) -> Void) {
        guard var raw = state?.noise?.raw else { return }
        edit(&raw)
        let value = raw
        perform({ hp in withUnsafePointer(to: value) { mdrHeadphonesSetNoiseControl(hp, $0) } }, "noise")
    }

    func setNoiseMode(_ mode: NoiseMode) {
        mutate { $0.noise?.mode = mode }
        writeNoise { $0.mode = mode.rawValue }
    }

    func setAmbientLevel(_ level: Int) {
        mutate { $0.noise?.ambientLevel = level }
        writeNoise { $0.ambient_level = UInt32(level) }
    }

    func setFocusOnVoice(_ on: Bool) {
        mutate { $0.noise?.focusOnVoice = on }
        writeNoise { $0.focus_on_voice = on ? MDR_TRUE : MDR_FALSE }
    }

    func setAdaptiveAmbient(_ on: Bool) {
        mutate { $0.noise?.adaptiveAmbient = on }
        writeNoise { $0.adaptive_ambient = on ? MDR_TRUE : MDR_FALSE }
    }

    func setSpeakToChat(_ on: Bool) {
        guard var raw = state?.speakToChat?.raw else { return }
        mutate { $0.speakToChat?.enabled = on }
        raw.enabled = on ? MDR_TRUE : MDR_FALSE
        let value = raw
        perform({ hp in withUnsafePointer(to: value) { mdrHeadphonesSetSpeakToChat(hp, $0) } }, "speakToChat")
    }

    // Listening mode

    func setListeningMode(_ mode: ListeningMode) {
        // Don't send modes the device is currently refusing (e.g. during a call); the UI shows why.
        guard let l = state?.listening, l.mode != mode, l.blocked[mode] == nil else { return }
        guard var raw = state?.listening?.raw else { return }
        mutate { $0.listening?.mode = mode }
        raw.mode = mode.rawValue
        let value = raw
        perform({ hp in withUnsafePointer(to: value) { mdrHeadphonesSetListening(hp, $0) } }, "listening")
    }

    func setRoom(_ room: RoomSize) {
        guard state?.listening?.blocked[.backgroundMusic] == nil else { return }
        guard var raw = state?.listening?.raw else { return }
        mutate { $0.listening?.room = room; $0.listening?.mode = .backgroundMusic }
        raw.mode = ListeningMode.backgroundMusic.rawValue
        raw.background_room = room.rawValue
        let value = raw
        perform({ hp in withUnsafePointer(to: value) { mdrHeadphonesSetListening(hp, $0) } }, "room")
    }

    // Equalizer

    func setEQPreset(_ id: UInt32) {
        mutate { $0.equalizer?.preset = id }
        perform({ hp in mdrHeadphonesSetEqualizerPreset(hp, id) }, "eqPreset")
    }

    /// Band / Clear Bass edits only stick on Custom/User presets (the XM6 ignores them on Off and the
    /// built-ins), so switch to Custom first, like Sony's app does.
    private func ensureEditablePreset() {
        guard let p = state?.equalizer?.preset, !EQPreset.isEditable(p) else { return }
        let custom = state?.equalizer?.presets.first { EQPreset.isEditable($0.id) }?.id ?? EQPreset.custom
        setEQPreset(custom)
    }

    func setClearBass(_ v: Int) {
        ensureEditablePreset()
        mutate { $0.equalizer?.clearBass = v }
        perform({ hp in mdrHeadphonesSetEqualizerClearBass(hp, Int32(v)) }, "clearBass")
    }

    func setBands(_ bands: [Int]) {
        ensureEditablePreset()
        mutate { $0.equalizer?.bands = bands }
        let values = bands.map(Int32.init)
        perform({ hp in values.withUnsafeBufferPointer {
            mdrHeadphonesSetEqualizerBands(hp, $0.baseAddress, UInt32($0.count))
        } }, "bands")
    }

    /// XM6-style devices have no Clear Bass; emulate a bass control on the lowest three bands.
    func setBassBoost(_ v: Int) {
        guard var b = state?.equalizer?.bands, b.count >= 3 else { return }
        b[0] = v
        b[1] = v
        b[2] = Int((Double(v) * 0.5).rounded())
        setBands(b)
    }

    func setNoiseButton(_ mode: UInt32) {
        mutate { $0.noise?.buttonMode = mode }
        writeNoise { $0.button_mode = mode }
    }

    /// Write a full curve. With `preset`, it is stored in that slot (Custom / Custom 1 / Custom 2);
    /// otherwise it goes to Custom (switching there if needed).
    func applyCurve(_ bands: [Int], preset: UInt32? = nil) {
        if let preset, preset != state?.equalizer?.preset { setEQPreset(preset) }
        if preset == nil { ensureEditablePreset() }
        mutate { $0.equalizer?.bands = bands }
        let values = bands.map(Int32.init)
        perform({ hp in values.withUnsafeBufferPointer {
            mdrHeadphonesSetEqualizerBands(hp, $0.baseAddress, UInt32($0.count))
        } }, "curve")
    }

    /// Snapshot of what a tuning session changes, so it can be put back exactly.
    struct SoundSnapshot { var preset: UInt32; var bands: [Int]; var noise: NoiseMode }

    func soundSnapshot() -> SoundSnapshot? {
        guard let eq = state?.equalizer, let n = state?.noise else { return nil }
        return SoundSnapshot(preset: eq.preset, bands: eq.bands, noise: n.mode)
    }

    func restore(_ snap: SoundSnapshot) {
        if EQPreset.isEditable(snap.preset) {
            applyCurve(snap.bands, preset: snap.preset)
        } else {
            setEQPreset(snap.preset)
        }
        setNoiseMode(snap.noise)
    }

    func resetBands() {
        guard let n = state?.equalizer?.bands.count, n > 0 else { return }
        setBands(Array(repeating: 0, count: n))
        if state?.equalizer?.clearBass != nil { setClearBass(0) }
    }

    func setDSEE(_ on: Bool) {
        mutate { $0.equalizer?.dseeEnabled = on }
        perform({ hp in mdrHeadphonesSetDSEE(hp, on ? MDR_TRUE : MDR_FALSE) }, "dsee")
    }

    // Playback

    func sendPlayback(_ action: UInt32) {
        perform({ hp in
            var cmd = MDRPlaybackCommand(action: action)
            return mdrHeadphonesSendPlaybackCommand(hp, &cmd)
        }, "playback")
    }

    // Power & system

    private func writePower(_ edit: (inout MDRPower) -> Void) {
        guard var raw = state?.power?.raw else { return }
        edit(&raw)
        let value = raw
        perform({ hp in withUnsafePointer(to: value) { mdrHeadphonesSetPower(hp, $0) } }, "power")
    }

    func setAutoPowerOff(_ minutes: Int) {
        mutate { $0.power?.autoPowerOffMinutes = minutes }
        writePower { $0.auto_power_off_minutes = UInt32(minutes) }
    }

    func setPowerOffWhenRemoved(_ on: Bool) {
        mutate { $0.power?.powerOffWhenRemoved = on }
        writePower { $0.wearing_power = on ? MDR_WEARING_POWER_WHEN_REMOVED : MDR_WEARING_POWER_DISABLED }
    }

    func setDeviceAutoPause(_ on: Bool) {
        mutate { $0.power?.autoPause = on }
        writePower { $0.auto_pause = on ? MDR_TRUE : MDR_FALSE }
    }

    func setHeadGesture(_ on: Bool) {
        mutate { $0.power?.headGesture = on }
        writePower { $0.head_gesture = on ? MDR_TRUE : MDR_FALSE }
    }

    func powerOff() {
        writePower { $0.shutdown_requested = MDR_TRUE }
    }

    func setVoiceGuidance(enabled: Bool? = nil, volume: Int? = nil) {
        guard let vg = state?.voiceGuidance else { return }
        let e = enabled ?? vg.enabled
        let v = volume ?? vg.volume ?? 0
        mutate { $0.voiceGuidance?.enabled = e; if volume != nil { $0.voiceGuidance?.volume = v } }
        var raw = MDRVoiceGuidance(enabled: e ? MDR_TRUE : MDR_FALSE, volume: Int32(v))
        perform({ hp in mdrHeadphonesSetVoiceGuidance(hp, &raw) }, "voiceGuidance")
    }

    func setAssignable(location: UInt32, action: UInt32) {
        guard var keys = state?.assignableKeys, let i = keys.firstIndex(where: { $0.location == location }) else { return }
        keys[i].action = action
        mutate { $0.assignableKeys = keys }
        let controls = keys.map { MDRAssignableControl(location: $0.location, type: $0.type, action: $0.action) }
        perform({ hp in controls.withUnsafeBufferPointer {
            mdrHeadphonesSetAssignableControls(hp, $0.baseAddress, UInt32($0.count))
        } }, "assignable")
    }

    func setGeneral(_ setting: GeneralSetting, toggle: Bool? = nil, choice: Int? = nil) {
        var raw = MDRGeneralSetting()
        raw.index = setting.index
        switch setting.kind {
        case .toggle(let cur): raw.boolean_value = (toggle ?? cur) ? MDR_TRUE : MDR_FALSE
        case .choice(let cur, _): raw.list_value = UInt32(choice ?? cur)
        }
        mutate { s in
            guard let i = s.generalSettings.firstIndex(where: { $0.index == setting.index }) else { return }
            switch setting.kind {
            case .toggle(let cur): s.generalSettings[i].kind = .toggle(toggle ?? cur)
            case .choice(let cur, let opts): s.generalSettings[i].kind = .choice(choice ?? cur, opts)
            }
        }
        let value = raw
        perform({ hp in withUnsafePointer(to: value) { mdrHeadphonesSetGeneralSetting(hp, $0) } }, "general")
    }

    // Multipoint

    func pairedDevice(_ command: UInt32, mac: String) {
        perform({ hp in
            mac.withCString { id in
                var action = MDRPairedDeviceAction(command: command, device_id: id, device_id_size: UInt32(strlen(id)))
                return mdrHeadphonesSetPairedDevice(hp, &action)
            }
        }, "pairedDevice")
    }

    func setAutoSourceSwitch(_ on: Bool) {
        mutate { $0.autoSourceSwitch = on }
        perform({ hp in mdrHeadphonesSetSourceSwitchControl(hp, on ? MDR_TRUE : MDR_FALSE) }, "sourceSwitch")
    }

    func setPrioritizeQuality(_ on: Bool) {
        mutate { $0.prioritizeQuality = on }
        var mode = MDRConnectionMode(audio_priority: on ? MDR_AUDIO_PRIORITY_QUALITY : MDR_AUDIO_PRIORITY_STABILITY)
        perform({ hp in mdrHeadphonesSetConnectionMode(hp, &mode) }, "connectionMode")
    }

    func answerAlert(_ positive: Bool) {
        alert = nil
        perform({ hp in
            mdrHeadphonesSetAlertResponse(hp, positive ? MDR_ALERT_ACTION_POSITIVE : MDR_ALERT_ACTION_NEGATIVE)
        }, "alert")
    }
}
