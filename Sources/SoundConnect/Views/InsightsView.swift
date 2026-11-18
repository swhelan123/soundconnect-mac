import Charts
import MapKit
import SwiftUI

struct InsightsPane: View {
    @EnvironmentObject var store: HeadphoneStore
    @ObservedObject var insights: Insights
    @AppStorage(Prefs.breakReminderMinutes) private var breakMinutes = 0
    @AppStorage(Prefs.rememberLocation) private var rememberLocation = true

    var body: some View {
        Form {
            batterySection
            exposureSection
            wearSection
            lastSeenSection
        }
        .formStyle(.grouped)
    }

    // MARK: Battery

    @ViewBuilder private var batterySection: some View {
        Section("Battery") {
            if let s = store.state, let b = s.primaryBattery, store.isConnected {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        if b.charging {
                            Text("Charging").font(.title2.weight(.semibold))
                            Text("\(b.level)%").foregroundStyle(.secondary)
                        } else if let f = insights.forecast(level: b.level, charging: b.charging, noise: s.noise?.mode.rawValue) {
                            Text("≈ \(Self.hours(f.hoursLeft)) left").font(.title2.weight(.semibold))
                            Text("\(b.level)% · \(f.learned ? "based on your usage" : "estimated from Sony's rating until it learns your usage")"
                                 + " · \(s.noise?.mode == .cancelling ? "with noise cancelling" : "without noise cancelling")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    BatteryPill(battery: b)
                }
            } else {
                Text("Connect your headphones to see a forecast.").foregroundStyle(.secondary)
            }
            let history = insights.batteryHistory(hours: 48)
            if history.count > 1 {
                Chart(history, id: \.t) { s in
                    LineMark(x: .value("Time", s.t), y: .value("Battery", s.level))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(Color.accentColor)
                    AreaMark(x: .value("Time", s.t), y: .value("Battery", s.level))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(LinearGradient(colors: [.accentColor.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(values: [0, 50, 100]) { value in AxisGridLine(); AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)%") } } } }
                .frame(height: 110)
            }
        }
    }

    // MARK: Exposure

    @ViewBuilder private var exposureSection: some View {
        Section {
            let weekly = insights.weeklyDose
            HStack(spacing: 18) {
                Gauge(value: min(weekly, 1.5), in: 0...1.5) {
                    EmptyView()
                } currentValueLabel: {
                    Text("\(Int((weekly * 100).rounded()))%").font(.system(.title3, design: .rounded).weight(.semibold))
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(Self.doseColor(weekly))
                .scaleEffect(1.25)
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(weekly < 0.8 ? "Your ears are fine this week" : weekly < 1 ? "Approaching your weekly limit" : "Over your weekly limit")
                        .font(.headline)
                    Text("Share of the WHO safe weekly dose (80 dB for 40 h) used in the last 7 days.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let live = store.state?.soundPressure {
                        Label("Now: \(live) dB", systemImage: "waveform").font(.caption.weight(.medium))
                            .foregroundStyle(Self.dbColor(Double(live)))
                    }
                }
            }
            .padding(.vertical, 4)

            let days = insights.recentDays(7)
            Chart(days, id: \.date) { d in
                BarMark(x: .value("Day", d.date, unit: .day), y: .value("Dose", d.stats.weeklyDose * 100))
                    .foregroundStyle(Self.doseColor(d.stats.weeklyDose * 7).gradient)
                    .cornerRadius(4)
                RuleMark(y: .value("Daily share", 100.0 / 7))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .chartXAxis { AxisMarks(values: .stride(by: .day)) { AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
            .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))%") } } } }
            .frame(height: 110)

            let t = insights.today
            if t.listeningSeconds > 0, let avg = t.averageDB {
                LabeledContent("Today", value: "\(Insights.duration(t.listeningSeconds)) at \(Int(avg.rounded())) dB avg · peak \(t.peakDB) dB")
            }
        } header: {
            Text("Sound Exposure")
        } footer: {
            Text("Measured by your headphones while audio plays. The dashed line is a seventh of the weekly allowance.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Wear

    @ViewBuilder private var wearSection: some View {
        Section("Wear Time") {
            let days = insights.recentDays(7)
            LabeledContent("Today", value: Insights.duration(insights.today.wornSeconds))
            Chart(days, id: \.date) { d in
                BarMark(x: .value("Day", d.date, unit: .day), y: .value("Hours", d.stats.wornSeconds / 3600))
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(4)
            }
            .chartXAxis { AxisMarks(values: .stride(by: .day)) { AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
            .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))h") } } } }
            .frame(height: 100)
            Picker("Break Reminder", selection: $breakMinutes) {
                Text("Off").tag(0)
                Text("Every 45 min").tag(45)
                Text("Every hour").tag(60)
                Text("Every 90 min").tag(90)
                Text("Every 2 hours").tag(120)
            }
        }
    }

    // MARK: Last seen

    @ViewBuilder private var lastSeenSection: some View {
        Section {
            Toggle("Remember Where Headphones Disconnect", isOn: $rememberLocation)
            if let ls = insights.file.lastSeen {
                LabeledContent("Last Disconnected") {
                    Text(ls.date, format: .relative(presentation: .named))
                }
                if let place = ls.place { LabeledContent("Near", value: place) }
                if let lat = ls.latitude, let lon = ls.longitude {
                    let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    Map(initialPosition: .region(MKCoordinateRegion(center: coord, latitudinalMeters: 600, longitudinalMeters: 600))) {
                        Marker(store.state?.modelName ?? "Headphones", systemImage: "headphones", coordinate: coord)
                    }
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            } else {
                Text("Nothing recorded yet. SoundConnect notes the time\(rememberLocation ? " and place" : "") whenever your headphones disconnect from this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Last Seen")
        } footer: {
            Text("Stored only on this Mac.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Helpers

    static func hours(_ h: Double) -> String {
        if h < 1 { return "\(Int(h * 60)) min" }
        let whole = Int(h), mins = Int((h - Double(whole)) * 60 / 15) * 15
        return mins == 0 ? "\(whole) h" : "\(whole) h \(mins) min"
    }

    static func doseColor(_ d: Double) -> Color {
        d < 0.8 ? .green : d < 1 ? .orange : .red
    }

    static func dbColor(_ db: Double) -> Color {
        db < 80 ? .green : db < 90 ? .orange : .red
    }
}
