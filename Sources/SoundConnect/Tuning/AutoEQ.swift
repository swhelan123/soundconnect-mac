import Foundation

/// Harman-target correction for the WH-1000XM6, from AutoEq's fixed-band (31 Hz–16 kHz, Q 1.41) results:
/// https://github.com/jaakkopasanen/AutoEq — results/Kuulokenurkka and results/Super Review.
/// The two measurements agree below 8 kHz and contradict each other at 16 kHz (rig variance), so they're
/// averaged and 16 kHz is left alone.
enum AutoEQ {
    struct Source { var name: String; var gains: [Double] }

    static let frequencies = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    static let sources: [String: [Source]] = [
        "WH-1000XM6": [
            Source(name: "Kuulokenurkka", gains: [-4.9, -2.1, -3.2, -1.4, -1.0, 3.4, -1.5, -0.7, 5.3, -9.8]),
            Source(name: "Super Review", gains: [-9.2, -6.0, -5.0, -2.3, 2.3, 2.8, -3.1, 2.8, 3.2, 8.3]),
        ],
    ]

    /// Bands where the measurements are trustworthy enough to apply.
    private static let trusted: [Bool] = [true, true, true, true, true, true, true, true, true, false]

    static func supports(model: String) -> Bool { sources[model] != nil }

    /// Averaged correction in dB per band, before strength/clamping.
    static func correction(model: String) -> [Double]? {
        guard let s = sources[model], !s.isEmpty else { return nil }
        return (0..<frequencies.count).map { i in
            trusted[i] ? s.map { $0.gains[i] }.reduce(0, +) / Double(s.count) : 0
        }
    }

    /// Device band values at `strength` (0...1), rounded and clamped to the device range.
    /// Assumes one device step ≈ 1 dB, which matches the ±6 range Sony's app shows for the XM6.
    static func bands(model: String, strength: Double, bandCount: Int, range: ClosedRange<Int>) -> [Int]? {
        guard let c = correction(model: model), c.count == bandCount else { return nil }
        return c.map { Int(($0 * strength).rounded()).clamped(to: range) }
    }

    static var attribution: String {
        "Measurements by Kuulokenurkka and Super Review via AutoEq (MIT)."
    }
}

/// Shapes a 10-band curve from four perceptual controls. Shared by the A/B finder.
enum CurveShape {
    enum Param: Int, CaseIterable {
        case bass, warmth, presence, air
        var title: String {
            switch self {
            case .bass: "Bass"
            case .warmth: "Warmth"
            case .presence: "Presence"
            case .air: "Air"
            }
        }
    }

    // Per-band weight of each control (31 … 16k).
    private static let weights: [Param: [Double]] = [
        .bass:     [1.0, 1.0, 0.7, 0.3, 0, 0, 0, 0, 0, 0],
        .warmth:   [0, 0, 0.3, 0.8, 1.0, 0.4, 0, 0, 0, 0],
        .presence: [0, 0, 0, 0, 0, 0.5, 1.0, 0.8, 0.3, 0],
        .air:      [0, 0, 0, 0, 0, 0, 0, 0.3, 1.0, 1.0],
    ]

    static func bands(_ p: [Param: Double], count: Int, range: ClosedRange<Int>) -> [Int] {
        (0..<count).map { i in
            let v = Param.allCases.reduce(0.0) { acc, k in
                acc + (p[k] ?? 0) * ((weights[k] ?? [])[safe: i] ?? 0)
            }
            return Int(v.rounded()).clamped(to: range)
        }
    }
}

/// Blind pairwise "which sounds better?" search over CurveShape parameters.
/// Each round nudges one control up (one option) and down (the other), in random order. The pick
/// becomes the new baseline; the step halves after the first pass over all four controls.
@MainActor
final class ABFinder: ObservableObject {
    struct Round: Equatable {
        var param: CurveShape.Param
        var a: [CurveShape.Param: Double]
        var b: [CurveShape.Param: Double]
    }

    static let totalRounds = 8

    @Published private(set) var current: [CurveShape.Param: Double]
    @Published private(set) var round: Round?
    @Published private(set) var index = 0
    @Published var listening: Character?   // "A" or "B" while auditioning

    let start: [Int]

    init(startingFrom bands: [Int]) {
        start = bands
        current = [:]
        next()
    }

    var finished: Bool { index >= Self.totalRounds }

    private func step(for i: Int) -> Double { i < 4 ? 3 : 1.5 }

    private func next() {
        guard !finished else { round = nil; return }
        let order: [CurveShape.Param] = [.bass, .presence, .air, .warmth]
        let param = order[index % order.count]
        let s = step(for: index)
        var up = current, down = current
        up[param] = (current[param] ?? 0) + s
        down[param] = (current[param] ?? 0) - s
        round = Bool.random() ? Round(param: param, a: up, b: down) : Round(param: param, a: down, b: up)
        listening = nil
    }

    func choose(_ which: Character?) {
        guard let r = round else { return }
        if which == "A" { current = r.a } else if which == "B" { current = r.b }
        index += 1
        next()
    }

    /// Absolute bands = the curve the user started from + the shaped adjustment.
    func bands(for p: [CurveShape.Param: Double], range: ClosedRange<Int>) -> [Int] {
        let delta = CurveShape.bands(p, count: start.count, range: -12...12)
        return zip(start, delta).map { ($0 + $1).clamped(to: range) }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
