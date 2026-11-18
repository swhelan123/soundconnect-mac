import Combine
import CoreLocation
import Foundation
import UserNotifications
import os

private let insightsLog = Logger(subsystem: "dev.soundconnect.mac", category: "insights")

// MARK: - Persisted model

struct BatterySample: Codable, Equatable {
    var t: Date
    var level: Int
    var charging: Bool
    /// NoiseMode raw value at the time (NC drains faster).
    var noise: UInt32?
}

struct DayStats: Codable, Equatable {
    /// Fraction of the WHO weekly allowance used this day (1.0 = a full week's safe dose).
    var weeklyDose: Double = 0
    var listeningSeconds: Double = 0
    /// Energy-average numerator, so avgDB can be recovered: 10*log10(sum(10^(L/10)*dt)/dt).
    var energySum: Double = 0
    var peakDB: Int = 0
    var wornSeconds: Double = 0

    var averageDB: Double? {
        listeningSeconds > 0 ? 10 * log10(energySum / listeningSeconds) : nil
    }
}

struct LastSeen: Codable, Equatable {
    var date: Date
    var latitude: Double?
    var longitude: Double?
    var place: String?
}

struct HistoryFile: Codable {
    var battery: [BatterySample] = []
    var days: [String: DayStats] = [:]   // key: yyyy-MM-dd (local)
    var lastSeen: LastSeen?
}

// MARK: - Insights

/// Records battery, sound-exposure and wear history from device snapshots, and derives forecasts.
/// Everything stays on this Mac (Application Support/SoundConnect/history.json).
@MainActor
final class Insights: ObservableObject {
    @Published private(set) var file = HistoryFile()

    private let url: URL
    private var saveWork: DispatchWorkItem?
    private var lastExposureSample: Date?
    private var lastWearTick: Date?
    private var wornSince: Date?
    private var lastBreakReminder: Date?
    private let location = LocationProvider()

    /// WHO / ITU-T H.870: 80 dB(A) for 40 h a week is 100% of the safe weekly dose; every +3 dB halves the time.
    static let referenceDB = 80.0
    static let weeklyAllowanceSeconds = 40.0 * 3600

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SoundConnect", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: url),
           let f = try? JSONDecoder.iso.decode(HistoryFile.self, from: data) {
            file = f
        }
    }

    /// In-memory instance for design previews.
    init(preview: HistoryFile) {
        url = URL(fileURLWithPath: "/dev/null")
        file = preview
    }

    // MARK: Ingest

    func record(_ s: HeadphoneState) {
        let now = Date()
        recordBattery(s, now: now)
        recordExposure(s, now: now)
        recordWear(s, now: now)
    }

    func connected() {
        location.refresh()
    }

    /// Called when the headphones disconnect: remember when and where.
    func disconnected() {
        lastExposureSample = nil
        endWear(at: Date())
        let now = Date()
        var seen = LastSeen(date: now)
        if let loc = location.latest {
            seen.latitude = loc.coordinate.latitude
            seen.longitude = loc.coordinate.longitude
            seen.place = location.latestPlace
        }
        file.lastSeen = seen
        scheduleSave()
        // A fresher fix may arrive shortly; patch it in.
        location.refresh { [weak self] loc, place in
            guard let self, var ls = self.file.lastSeen, ls.date == now else { return }
            ls.latitude = loc.coordinate.latitude
            ls.longitude = loc.coordinate.longitude
            ls.place = place
            self.file.lastSeen = ls
            self.scheduleSave()
        }
    }

    private func recordBattery(_ s: HeadphoneState, now: Date) {
        guard let b = s.primaryBattery, b.level > 0 else { return }
        if let last = file.battery.last, last.level == b.level, last.charging == b.charging,
           last.noise == s.noise?.mode.rawValue { return }
        file.battery.append(BatterySample(t: now, level: b.level, charging: b.charging, noise: s.noise?.mode.rawValue))
        let cutoff = now.addingTimeInterval(-30 * 86400)
        file.battery.removeAll { $0.t < cutoff }
        scheduleSave()
    }

    private func recordExposure(_ s: HeadphoneState, now: Date) {
        defer { lastExposureSample = now }
        guard let db = s.soundPressure, let last = lastExposureSample else { return }
        // Snapshots arrive irregularly; cap the interval credited to one reading.
        let dt = min(now.timeIntervalSince(last), 30)
        guard dt > 0 else { return }
        let key = Self.dayKey(now)
        var d = file.days[key] ?? DayStats()
        d.listeningSeconds += dt
        d.energySum += pow(10, Double(db) / 10) * dt
        d.peakDB = max(d.peakDB, db)
        d.weeklyDose += dt / Self.weeklyAllowanceSeconds * pow(2, (Double(db) - Self.referenceDB) / 3)
        file.days[key] = d
        scheduleSave()
    }

    private func recordWear(_ s: HeadphoneState, now: Date) {
        guard let worn = s.worn else { return }
        if worn {
            if wornSince == nil { wornSince = now; lastWearTick = now }
            if let tick = lastWearTick {
                addWorn(now.timeIntervalSince(tick), at: now)
            }
            lastWearTick = now
            checkBreakReminder(now: now)
        } else {
            endWear(at: now)
        }
    }

    private func endWear(at now: Date) {
        if let tick = lastWearTick, wornSince != nil { addWorn(now.timeIntervalSince(tick), at: now) }
        wornSince = nil
        lastWearTick = nil
        lastBreakReminder = nil
    }

    private func addWorn(_ seconds: Double, at now: Date) {
        guard seconds > 0, seconds < 3600 else { return }
        let key = Self.dayKey(now)
        file.days[key, default: DayStats()].wornSeconds += seconds
        scheduleSave()
    }

    /// Snapshots only arrive on change; call periodically so wear time and reminders advance.
    func tick(worn: Bool?) {
        guard worn == true, let tick = lastWearTick else { return }
        let now = Date()
        addWorn(now.timeIntervalSince(tick), at: now)
        lastWearTick = now
        checkBreakReminder(now: now)
    }

    private func checkBreakReminder(now: Date) {
        let minutes = UserDefaults.standard.integer(forKey: Prefs.breakReminderMinutes)
        guard minutes > 0, let since = wornSince else { return }
        let interval = TimeInterval(minutes * 60)
        let anchor = lastBreakReminder ?? since
        guard now.timeIntervalSince(anchor) >= interval else { return }
        lastBreakReminder = now
        let content = UNMutableNotificationContent()
        content.title = "Time for a listening break"
        content.body = "You've had your headphones on for \(Self.duration(now.timeIntervalSince(since))). "
            + "A few minutes off helps your ears recover."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "break", content: content, trigger: nil))
    }

    // MARK: Derived: exposure

    var today: DayStats { file.days[Self.dayKey(Date())] ?? DayStats() }

    /// Last `n` days, oldest first.
    func recentDays(_ n: Int) -> [(date: Date, stats: DayStats)] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        return (0..<n).reversed().compactMap { i in
            guard let d = cal.date(byAdding: .day, value: -i, to: start) else { return nil }
            return (d, file.days[Self.dayKey(d)] ?? DayStats())
        }
    }

    /// Share of the weekly allowance used over the last 7 days.
    var weeklyDose: Double { recentDays(7).map(\.stats.weeklyDose).reduce(0, +) }

    // MARK: Derived: battery

    struct Forecast: Equatable {
        var hoursLeft: Double
        var learned: Bool          // from your history rather than Sony's spec
        var ratePerHour: Double    // % per hour
    }

    /// Spec drain rates (XM6: ~30 h with NC, ~40 h without) used until enough history exists.
    private static func specRate(noise: UInt32?) -> Double {
        noise == NoiseMode.cancelling.rawValue || noise == NoiseMode.wind.rawValue ? 100.0 / 30 : 100.0 / 40
    }

    func forecast(level: Int, charging: Bool, noise: UInt32?) -> Forecast? {
        guard !charging, level > 0 else { return nil }
        let isNC = noise == NoiseMode.cancelling.rawValue || noise == NoiseMode.wind.rawValue
        // Learned rate: sum of % dropped over time elapsed across discharge steps in the same mode family.
        var drop = 0.0, time = 0.0
        let samples = file.battery
        for (a, b) in zip(samples, samples.dropFirst()) {
            guard !a.charging, !b.charging, b.level < a.level else { continue }
            let dt = b.t.timeIntervalSince(a.t)
            guard dt > 60, dt < 6 * 3600 else { continue } // skip gaps while disconnected
            let aNC = a.noise == NoiseMode.cancelling.rawValue || a.noise == NoiseMode.wind.rawValue
            guard aNC == isNC else { continue }
            drop += Double(a.level - b.level)
            time += dt / 3600
        }
        if drop >= 8, time >= 1 {
            let rate = drop / time
            return Forecast(hoursLeft: Double(level) / rate, learned: true, ratePerHour: rate)
        }
        let rate = Self.specRate(noise: noise)
        return Forecast(hoursLeft: Double(level) / rate, learned: false, ratePerHour: rate)
    }

    /// Battery level over the last `hours`, for the sparkline.
    func batteryHistory(hours: Double) -> [BatterySample] {
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        return file.battery.filter { $0.t >= cutoff }
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = file
        let url = self.url
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder.iso.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: Helpers

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func duration(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        if m < 60 { return "\(m) min" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h) h" : "\(h) h \(r) min"
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}

// MARK: - Location

/// Coarse location for "last seen". Refreshed on connect and disconnect only.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var latest: CLLocation?
    private(set) var latestPlace: String?
    private var waiters: [(CLLocation, String?) -> Void] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var enabled: Bool { UserDefaults.standard.bool(forKey: Prefs.rememberLocation) }

    func refresh(_ completion: ((CLLocation, String?) -> Void)? = nil) {
        guard enabled else { return }
        if let completion { waiters.append(completion) }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: waiters.removeAll()
        default: manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in
            if m.authorizationStatus == .authorized || m.authorizationStatus == .authorizedAlways {
                m.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.latest = loc
            let place = await Self.placeName(loc)
            self.latestPlace = place
            let w = self.waiters
            self.waiters.removeAll()
            w.forEach { $0(loc, place) }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        insightsLog.error("location: \(error.localizedDescription, privacy: .public)")
    }

    private static func placeName(_ loc: CLLocation) async -> String? {
        guard let p = try? await CLGeocoder().reverseGeocodeLocation(loc).first else { return nil }
        return [p.name, p.locality].compactMap { $0 }.removingDuplicates().joined(separator: ", ")
    }
}

extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
