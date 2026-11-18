import AppKit
import ApplicationServices
import CoreAudio
import os

private let mediaLog = Logger(subsystem: "dev.soundconnect.mac", category: "media")

/// Pauses / resumes media playing *on this Mac* when the headphones come off.
///
/// The headphones' own auto-pause only reaches their current playback device over AVRCP, which with
/// multipoint is often the phone. MediaRemote is closed to third-party apps on current macOS, so:
///  1. Music / Spotify are queried and controlled precisely via AppleScript.
///  2. Anything else (browsers, etc.) gets the system play/pause media key, but only when audio is
///     actually flowing to the output device and the microphone is idle (so we can't start music
///     mid-call). Needs Accessibility permission; opt-in.
@MainActor
final class MediaController {
    private enum Paused { case script(String), mediaKey }
    private var paused: [Paused] = []

    private static let players: [(bundleID: String, name: String)] = [
        ("com.apple.Music", "Music"),
        ("com.spotify.client", "Spotify"),
    ]

    var hasPausedSomething: Bool { !paused.isEmpty }

    /// Pauses Music/Spotify immediately; other players get the play/pause key after a short delay,
    /// and only if audio is *still* flowing then (the headphones' own auto-pause may already have
    /// paused it via AVRCP, and toggling again would resume it) and the mic is idle (not on a call).
    func pauseIfPlaying(allowMediaKey: Bool) {
        paused.removeAll()
        for p in Self.players where isRunning(p.bundleID) {
            if run("tell application \"\(p.name)\" to get player state as string") == "playing" {
                _ = run("tell application \"\(p.name)\" to pause")
                paused.append(.script(p.name))
                mediaLog.info("paused \(p.name, privacy: .public)")
            }
        }
        guard paused.isEmpty, allowMediaKey else { return }
        guard Self.mediaKeyAllowed else {
            mediaLog.info("media key needs permission; requesting")
            Self.requestMediaKeyPermission()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.paused.isEmpty else { return }
            let out = Self.outputIsRunning(), mic = Self.inputIsRunning()
            guard out, !mic else {
                mediaLog.info("media key skipped (output running: \(out), mic in use: \(mic))")
                return
            }
            Self.postPlayPause()
            self.paused.append(.mediaKey)
            mediaLog.info("paused via media key")
        }
    }

    func resume() {
        for p in paused {
            switch p {
            case .script(let name): _ = run("tell application \"\(name)\" to play")
            case .mediaKey: Self.postPlayPause()
            }
        }
        if !paused.isEmpty { mediaLog.info("resumed \(self.paused.count) source(s)") }
        paused.removeAll()
    }

    func forget() { paused.removeAll() }

    // MARK: - Accessibility (for the media-key fallback)

    /// Posting the play/pause key needs the "control your computer" (post event) permission.
    static var mediaKeyAllowed: Bool { CGPreflightPostEventAccess() }

    static func requestMediaKeyPermission() {
        _ = CGRequestPostEventAccess()
    }

    // MARK: - Helpers

    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private func run(_ source: String) -> String? {
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err { mediaLog.error("applescript: \(String(describing: err), privacy: .public)") }
        return result?.stringValue
    }

    private static func postPlayPause() {
        let NX_KEYTYPE_PLAY: Int = 16
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = (NX_KEYTYPE_PLAY << 16) | ((down ? 0xa : 0xb) << 8)
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                        timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                        data1: data1, data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private static func deviceIsRunning(_ selector: AudioObjectPropertySelector) -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr
        else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    static func outputIsRunning() -> Bool { deviceIsRunning(kAudioHardwarePropertyDefaultOutputDevice) }
    static func inputIsRunning() -> Bool { deviceIsRunning(kAudioHardwarePropertyDefaultInputDevice) }
}
