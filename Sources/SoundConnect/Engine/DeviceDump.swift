import CMDR
import Foundation
import os

private let dumpLog = Logger(subsystem: "dev.soundconnect.mac", category: "dump")

/// Logs everything the device reports once per connection. Diagnostic only (worker thread).
enum DeviceDump {
    static func run(_ hp: OpaquePointer) {
        let r = Reader(hp)
        let cur = MDRPropertyType(MDR_PROPERTY_CURRENT)
        var lines: [String] = []
        func add(_ s: String) { lines.append(s) }

        let featureNames: [(UInt32, String)] = [
            (MDR_FEATURE_EQUALIZER, "EQ"), (MDR_FEATURE_DSEE, "DSEE"), (MDR_FEATURE_LISTENING_MODE, "LISTENING"),
            (MDR_FEATURE_LISTENING_BACKGROUND_MUSIC, "BGM"), (MDR_FEATURE_LISTENING_CINEMA, "CINEMA"),
            (MDR_FEATURE_AUTO_PAUSE, "AUTO_PAUSE"), (MDR_FEATURE_WEARING_DETECTION, "WEAR_DET"),
            (MDR_FEATURE_AUTO_POWER_OFF, "AUTO_POWER_OFF"), (MDR_FEATURE_HEAD_GESTURE, "HEAD_GESTURE"),
            (MDR_FEATURE_VOICE_GUIDANCE, "VG"), (MDR_FEATURE_VOICE_GUIDANCE_VOLUME, "VG_VOL"),
            (MDR_FEATURE_ASSIGNABLE_CONTROLS, "ASSIGNABLE"), (MDR_FEATURE_NOISE_CONTROL_BUTTON, "NC_BUTTON"),
            (MDR_FEATURE_PAIRED_DEVICE_MANAGEMENT, "PAIRED"), (MDR_FEATURE_SOURCE_SWITCH_CONTROL, "SRC_SWITCH"),
            (MDR_FEATURE_CONNECTION_MODE, "CONN_MODE"), (MDR_FEATURE_GENERAL_SETTINGS, "GENERAL"),
            (MDR_FEATURE_WEARING_STATUS, "WEARING"), (MDR_FEATURE_SAFE_LISTENING, "SAFE"),
            (MDR_FEATURE_SHUTDOWN, "SHUTDOWN"), (MDR_FEATURE_PLAYBACK_CONTROL, "PB_CTRL"),
        ]
        add("features: " + featureNames.filter { r.has($0.0) }.map(\.1).joined(separator: ","))
        add("color=\(r.text(MDRText(MDR_TEXT_MODEL_COLOR))) series=\(r.text(MDRText(MDR_TEXT_MODEL_SERIES)))")

        var eq = MDREqualizer()
        if mdrHeadphonesGetEqualizer(hp, cur, &eq) == kOK {
            add("eq preset=\(eq.preset) clearBass=\(eq.clear_bass) bands=\(eq.band_count) avail=\(eq.available) dsee=\(eq.dsee_enabled)/\(eq.dsee_available) type=\(eq.dsee_type)")
        }
        var n: UInt32 = 16
        var bands = [Int32](repeating: 0, count: 16)
        if mdrHeadphonesGetEqualizerBands(hp, cur, &bands, &n) == kOK {
            let freqs = (0..<n).map { r.value(MDR_VALUE_EQUALIZER_BAND_FREQUENCY, $0) ?? -1 }
            add("eq bands=\(bands.prefix(Int(n))) freqs=\(freqs) range=\(String(describing: r.value(MDR_VALUE_EQUALIZER_BAND_MIN, n)))...\(String(describing: r.value(MDR_VALUE_EQUALIZER_BAND_MAX, n)))")
        }
        add("clearBass min=\(String(describing: r.value(MDR_VALUE_EQUALIZER_CLEAR_BASS_MIN)))")

        var l = MDRListening()
        if mdrHeadphonesGetListening(hp, cur, &l) == kOK { add("listening mode=\(l.mode) room=\(l.background_room)") }
        for m in [MDR_LISTENING_STANDARD, MDR_LISTENING_BACKGROUND_MUSIC, MDR_LISTENING_CINEMA] {
            var st = MDRListeningStatus()
            if mdrHeadphonesGetListeningStatus(hp, MDRListeningMode(m), &st) == kOK {
                add("listening status \(m): avail=\(st.available) blockers=\(st.blockers)")
            }
        }

        var p = MDRPower()
        if mdrHeadphonesGetPower(hp, cur, &p) == kOK {
            let opts = (0..<UInt32(r.value(MDR_VALUE_AUTO_POWER_OFF_OPTION_COUNT) ?? 0)).map {
                r.value(MDR_VALUE_AUTO_POWER_OFF_OPTION, $0) ?? -1
            }
            add("power apo=\(p.auto_power_off_minutes) opts=\(opts) wearing=\(p.wearing_power) autoPause=\(p.auto_pause) gesture=\(p.head_gesture)")
        }
        var vg = MDRVoiceGuidance()
        if mdrHeadphonesGetVoiceGuidance(hp, cur, &vg) == kOK { add("vg enabled=\(vg.enabled) vol=\(vg.volume)") }
        var cm = MDRConnectionMode()
        if mdrHeadphonesGetConnectionMode(hp, cur, &cm) == kOK { add("connMode priority=\(cm.audio_priority)") }

        var gn: UInt32 = 32
        var gs = [MDRGeneralSettingInfo](repeating: .init(), count: 32)
        if mdrHeadphonesGetGeneralSettingInfo(hp, &gs, &gn) == kOK {
            for g in gs.prefix(Int(gn)) {
                var v = MDRGeneralSetting()
                _ = mdrHeadphonesGetGeneralSetting(hp, cur, g.index, &v)
                add("general[\(g.index)] type=\(g.type) w=\(g.writable) opts=\(g.option_count) key=\(g.text_is_key) subj=\(r.text(MDRText(MDR_TEXT_GENERAL_SETTING_SUBJECT), g.index)) sum=\(r.text(MDRText(MDR_TEXT_GENERAL_SETTING_SUMMARY), g.index)) val=\(v.boolean_value)/\(v.list_value)")
            }
        }

        var an: UInt32 = 8
        var ac = [MDRAssignableControl](repeating: .init(), count: 8)
        if mdrHeadphonesGetAssignableControls(hp, cur, &ac, &an) == kOK {
            for c in ac.prefix(Int(an)) {
                var on: UInt32 = 32
                var opts = [MDRAssignableAction](repeating: 0, count: 32)
                _ = mdrHeadphonesGetAssignableControlActions(hp, c.location, &opts, &on)
                add("assignable loc=\(c.location) type=\(c.type) action=\(c.action) options=\(opts.prefix(Int(on)))")
            }
        }

        var pn: UInt32 = 16
        var pd = [MDRPairedDevice](repeating: .init(), count: 16)
        if mdrHeadphonesGetPairedDevices(hp, &pd, &pn) == kOK {
            for (i, d) in pd.prefix(Int(pn)).enumerated() {
                add("paired[\(i)] name=\(r.text(MDRText(MDR_TEXT_PAIRED_DEVICE_NAME), UInt32(i))) connected=\(d.connected) playback=\(d.playback_device)")
            }
        }
        var ss: MDRBoolean = 0
        if mdrHeadphonesGetSourceSwitchControl(hp, cur, &ss) == kOK { add("sourceSwitch=\(ss)") }

        for line in lines { dumpLog.info("\(line, privacy: .public)") }
    }
}
