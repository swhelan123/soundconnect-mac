import AVFoundation
import Foundation

/// Pulsed sine tone generator (AVAudioEngine) with click-free level ramps.
final class ToneGenerator: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode!
    private let lock = NSLock()
    private var frequency: Double = 1000
    private var targetAmp: Double = 0
    private var amp: Double = 0
    private var phase: Double = 0
    private var pulseClock: Double = 0
    private var sampleRate: Double = 48000

    /// Hard ceiling so a bug can never blast the user: -20 dBFS.
    static let maxDBFS = -20.0

    init() {
        let format = engine.outputNode.inputFormat(forBus: 0)
        sampleRate = format.sampleRate > 0 ? format.sampleRate : 48000
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        source = AVAudioSourceNode(format: mono) { [unowned self] _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            lock.lock()
            let f = frequency, target = targetAmp, sr = sampleRate
            lock.unlock()
            let ramp = 1.0 / (0.02 * sr) // 20 ms ramps
            for frame in 0..<Int(frameCount) {
                // 350 ms on / 250 ms off pulses are easier to pick out near threshold than a steady tone.
                pulseClock += 1 / sr
                if pulseClock >= 0.6 { pulseClock -= 0.6 }
                let gate = pulseClock < 0.35 ? target : 0
                amp += (gate - amp) * min(1, ramp * 6)
                let v = Float(sin(phase) * amp)
                phase += 2 * .pi * f / sr
                if phase > 2 * .pi { phase -= 2 * .pi }
                for b in buffers { b.mData?.assumingMemoryBound(to: Float.self)[frame] = v }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: mono)
        engine.mainMixerNode.outputVolume = 1
    }

    func start() throws { if !engine.isRunning { try engine.start() } }
    func stop() { set(dbfs: nil); engine.stop() }

    func set(frequency f: Double) { lock.withLock { frequency = f } }

    /// nil = silence.
    func set(dbfs: Double?) {
        let a = dbfs.map { pow(10, min($0, Self.maxDBFS) / 20) } ?? 0
        lock.withLock { targetAmp = a }
    }
}

/// Ascending-level threshold test at each EQ band. Uncalibrated (no SPL reference), so results are
/// interpreted *relative* to the listener's own 1 kHz threshold against a typical-hearing curve, and
/// only used to lift frequencies that look meaningfully less sensitive. Not a medical test.
@MainActor
final class HearingTest: ObservableObject {
    enum Phase: Equatable { case intro, testing, done }

    @Published private(set) var phase: Phase = .intro
    @Published private(set) var bandIndex = 0
    @Published private(set) var levelDBFS = HearingTest.startDBFS
    @Published private(set) var thresholds: [Double?]
    @Published var error: String?

    let frequencies: [Int]
    private let tone = ToneGenerator()
    private var timer: Timer?
    private var attempt = 0
    private var attempts: [Double] = []

    static let startDBFS = -90.0
    static let stepDB = 1.5
    static let stepInterval = 0.45

    /// Typical threshold of hearing relative to 1 kHz (ISO 226:2003, dB), for the shape comparison.
    private static let typicalRelative: [Int: Double] = [
        31: 57, 62: 35, 63: 35, 125: 20, 250: 9, 500: 2, 1000: 0, 2000: -4, 4000: -8, 8000: 10, 16000: 30,
    ]

    init(frequencies: [Int]) {
        self.frequencies = frequencies
        thresholds = Array(repeating: nil, count: frequencies.count)
    }

    var progress: Double { Double(bandIndex) / Double(max(frequencies.count, 1)) }

    func begin() {
        do { try tone.start() } catch { self.error = error.localizedDescription; return }
        phase = .testing
        bandIndex = 0
        startBand()
    }

    private func startBand() {
        attempt = 0
        attempts = []
        startAttempt()
    }

    private func startAttempt() {
        levelDBFS = Self.startDBFS - Double.random(in: 0...6) // jitter so the timing isn't learnable
        tone.set(frequency: Double(frequencies[bandIndex]))
        tone.set(dbfs: levelDBFS)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.stepInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.raise() }
        }
    }

    private func raise() {
        levelDBFS += Self.stepDB
        if levelDBFS > ToneGenerator.maxDBFS {
            // Never heard within the safe ceiling: record the ceiling and move on.
            heard(atCeiling: true)
            return
        }
        tone.set(dbfs: levelDBFS)
    }

    /// User pressed "I hear it".
    func heard(atCeiling: Bool = false) {
        guard phase == .testing else { return }
        timer?.invalidate()
        tone.set(dbfs: nil)
        attempts.append(min(levelDBFS, ToneGenerator.maxDBFS))
        attempt += 1
        if attempt < 2 && !atCeiling {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0.8...1.6)) { [weak self] in
                self?.startAttempt()
            }
            return
        }
        thresholds[bandIndex] = attempts.reduce(0, +) / Double(attempts.count)
        bandIndex += 1
        if bandIndex >= frequencies.count {
            finish()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.startBand() }
        }
    }

    func cancel() {
        timer?.invalidate()
        tone.stop()
        phase = .intro
    }

    private func finish() {
        timer?.invalidate()
        tone.stop()
        phase = .done
    }

    /// Lift for each band in dB (≥ 0): half of any loss beyond 6 dB relative to a typical hearing shape,
    /// only from 500 Hz up (low-frequency thresholds are dominated by room noise and headphone fit).
    func compensation(range: ClosedRange<Int>) -> [Int] {
        guard let refIdx = frequencies.firstIndex(of: 1000), let ref = thresholds[refIdx] else {
            return frequencies.map { _ in 0 }
        }
        return frequencies.enumerated().map { i, f in
            guard f >= 500, let t = thresholds[i], let typ = Self.typicalRelative[f] else { return 0 }
            let deviation = (t - ref) - typ
            guard deviation > 6 else { return 0 }
            return Int(((deviation - 6) * 0.5).rounded()).clamped(to: 0...range.upperBound)
        }
    }
}
