import SwiftUI

/// "Tuning" section of the Sound pane: Harman correction, hearing test, A/B finder.
struct TuningSection: View {
    @EnvironmentObject var store: HeadphoneStore
    var state: HeadphoneState
    var eq: EqualizerState
    @AppStorage(Prefs.autoEQStrength) private var strength = 0.7
    @State private var showHearing = false
    @State private var showAB = false
    @State private var target: UInt32 = EQPreset.custom

    private var slots: [EQPreset] { eq.presets.filter { EQPreset.isEditable($0.id) } }

    var body: some View {
        Section {
            if AutoEQ.supports(model: state.modelName),
               let preview = AutoEQ.bands(model: state.modelName, strength: strength,
                                          bandCount: eq.bands.count, range: eq.bandRange) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Harman Target")
                            Text("Corrects the \(state.modelName)'s measured response toward the Harman curve most listeners prefer. Mostly tames the XM6's extra bass.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Apply") { store.applyCurve(preview, preset: target) }
                    }
                    HStack(spacing: 10) {
                        Text("Strength").font(.callout).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { strength }, set: { strength = ($0 * 20).rounded() / 20 }), in: 0.25...1)
                        Text("\(Int(strength * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                    MiniBands(bands: preview, range: eq.bandRange)
                        .frame(height: 34)
                    Text(AutoEQ.attribution).font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hearing Test")
                    Text("2-minute tone test that lifts frequencies you hear less well. Not a medical test.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Start…") { showHearing = true }
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Find My Sound")
                    Text("Play music you know, then pick A or B eight times. No sliders, just your ears.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Start…") { showAB = true }
            }
            if slots.count > 1 {
                Picker("Save results to", selection: $target) {
                    ForEach(slots) { Text($0.name).tag($0.id) }
                }
            }
        } header: {
            Text("Tuning")
        }
        .sheet(isPresented: $showHearing) {
            HearingTestSheet(eq: eq, target: target).environmentObject(store)
        }
        .sheet(isPresented: $showAB) {
            ABFinderSheet(eq: eq, target: target).environmentObject(store)
        }
    }
}

/// Compact bar rendering of a band curve.
struct MiniBands: View {
    var bands: [Int]
    var range: ClosedRange<Int>

    var body: some View {
        GeometryReader { g in
            let maxAbs = CGFloat(max(abs(range.lowerBound), range.upperBound, 1))
            let mid = g.size.height / 2
            HStack(alignment: .center, spacing: 4) {
                ForEach(bands.indices, id: \.self) { i in
                    let v = CGFloat(bands[i])
                    let h = abs(v) / maxAbs * mid
                    ZStack {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(v >= 0 ? Color.accentColor : Color.orange.opacity(0.8))
                            .frame(height: max(h, 1.5))
                            .offset(y: v >= 0 ? -h / 2 : h / 2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .overlay(Rectangle().fill(.primary.opacity(0.15)).frame(height: 1).position(x: g.size.width / 2, y: mid))
        }
    }
}

// MARK: - Hearing test

struct HearingTestSheet: View {
    @EnvironmentObject var store: HeadphoneStore
    @Environment(\.dismiss) private var dismiss
    var eq: EqualizerState
    var target: UInt32
    @StateObject private var test: HearingTest
    @State private var snapshot: HeadphoneStore.SoundSnapshot?

    init(eq: EqualizerState, target: UInt32) {
        self.eq = eq
        self.target = target
        _test = StateObject(wrappedValue: HearingTest(frequencies: eq.frequencies))
    }

    var body: some View {
        VStack(spacing: 18) {
            switch test.phase {
            case .intro: intro
            case .testing: testing
            case .done: results
            }
        }
        .padding(28)
        .frame(width: 480)
        .onDisappear { finishSession(apply: false) }
    }

    private var intro: some View {
        VStack(spacing: 14) {
            Image(systemName: "ear.badge.waveform").font(.system(size: 40)).foregroundStyle(Color.accentColor)
            Text("Hearing Test").font(.title2.bold())
            VStack(alignment: .leading, spacing: 8) {
                Label("Pause any music and find a quiet spot.", systemImage: "pause.circle")
                Label("Set your Mac's volume to about half.", systemImage: "speaker.wave.2")
                Label("You'll hear soft beeps getting slowly louder. Press the button (or Space) as soon as you hear one.", systemImage: "hand.tap")
                Label("Noise cancelling turns on and EQ turns off during the test, then both go back.", systemImage: "arrow.uturn.backward")
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let e = test.error { Text(e).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Begin") {
                    snapshot = store.soundSnapshot()
                    store.setEQPreset(0)
                    store.setNoiseMode(.cancelling)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { test.begin() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var testing: some View {
        VStack(spacing: 20) {
            Text("\(EQCurveEditor.label(hz: test.frequencies[min(test.bandIndex, test.frequencies.count - 1)])) Hz")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
            ProgressView(value: test.progress)
            Button {
                test.heard()
            } label: {
                Text("I hear it")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.space, modifiers: [])
            Button("Stop Test") { test.cancel(); dismiss() }
                .buttonStyle(.link)
        }
    }

    private var results: some View {
        let comp = test.compensation(range: eq.bandRange)
        let lifted = comp.contains { $0 > 0 }
        return VStack(spacing: 14) {
            Image(systemName: lifted ? "slider.horizontal.3" : "checkmark.seal.fill")
                .font(.system(size: 36))
                .foregroundStyle(lifted ? Color.accentColor : .green)
            Text(lifted ? "Your Personal Curve" : "No Adjustment Needed").font(.title2.bold())
            Text(lifted
                 ? "These bands get a lift to balance what you hear less well. It's added on top of your current curve."
                 : "Your relative sensitivity looks typical across the range, so there's nothing to compensate.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if lifted {
                MiniBands(bands: comp, range: eq.bandRange).frame(height: 44)
                HStack(spacing: 0) {
                    ForEach(test.frequencies, id: \.self) {
                        Text(EQCurveEditor.label(hz: $0)).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                }
            }
            HStack {
                Button("Done") { dismiss() }
                Spacer()
                if lifted {
                    Button("Apply to \(EQPreset.defaultName(target))") {
                        let base = snapshot.map { EQPreset.isEditable($0.preset) ? $0.bands : eq.bands.map { _ in 0 } }
                            ?? eq.bands
                        let combined = zip(base, comp).map { ($0 + $1).clamped(to: eq.bandRange) }
                        finishSession(apply: false)
                        store.applyCurve(combined, preset: target)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func finishSession(apply: Bool) {
        test.cancel()
        if let s = snapshot {
            snapshot = nil
            store.restore(s)
        }
    }
}

// MARK: - A/B finder

struct ABFinderSheet: View {
    @EnvironmentObject var store: HeadphoneStore
    @Environment(\.dismiss) private var dismiss
    var eq: EqualizerState
    var target: UInt32
    @StateObject private var finder: ABFinder
    @State private var snapshot: HeadphoneStore.SoundSnapshot?
    @State private var applied = false

    init(eq: EqualizerState, target: UInt32) {
        self.eq = eq
        self.target = target
        // Start from the current curve if it's an editable one, otherwise flat.
        let start = EQPreset.isEditable(eq.preset) ? eq.bands : eq.bands.map { _ in 0 }
        _finder = StateObject(wrappedValue: ABFinder(startingFrom: start))
    }

    var body: some View {
        VStack(spacing: 18) {
            if let round = finder.round {
                Text("Round \(finder.index + 1) of \(ABFinder.totalRounds)").font(.headline)
                ProgressView(value: Double(finder.index), total: Double(ABFinder.totalRounds))
                Text("Switch between A and B while your music plays, then pick the one you prefer.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack(spacing: 14) {
                    auditionButton("A", params: round.a, key: "a")
                    auditionButton("B", params: round.b, key: "b")
                }
                HStack(spacing: 10) {
                    Button("Prefer A") { finder.choose("A") }
                        .disabled(finder.listening == nil)
                    Button("Can't tell") { finder.choose(nil) }
                    Button("Prefer B") { finder.choose("B") }
                        .disabled(finder.listening == nil)
                }
                .controlSize(.large)
            } else {
                Image(systemName: "sparkles").font(.system(size: 36)).foregroundStyle(Color.accentColor)
                Text("Your Sound").font(.title2.bold())
                let result = finder.bands(for: finder.current, range: eq.bandRange)
                MiniBands(bands: result, range: eq.bandRange).frame(height: 44)
                Text(summary).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button("Discard") { dismiss() }
                    Spacer()
                    Button("Save to \(EQPreset.defaultName(target))") {
                        applied = true
                        snapshot = nil
                        store.applyCurve(result, preset: target)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 460)
        .onAppear { snapshot = store.soundSnapshot() }
        .onDisappear { if !applied, let s = snapshot { store.restore(s) } }
        .onChange(of: finder.index) { _, _ in finder.listening = nil }
    }

    private func auditionButton(_ label: Character, params: [CurveShape.Param: Double], key: KeyEquivalent) -> some View {
        let active = finder.listening == label
        return Button {
            finder.listening = label
            store.applyCurve(finder.bands(for: params, range: eq.bandRange), preset: target)
        } label: {
            Text(String(label))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .frame(width: 110, height: 80)
                .foregroundStyle(active ? .white : .primary)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(active ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.quaternary)))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: [])
    }

    private var summary: String {
        let parts = CurveShape.Param.allCases.compactMap { p -> String? in
            guard let v = finder.current[p], abs(v) >= 1 else { return nil }
            return "\(v > 0 ? "more" : "less") \(p.title.lowercased())"
        }
        return parts.isEmpty ? "You preferred it close to where you started." : "You prefer " + parts.joined(separator: ", ") + "."
    }
}
