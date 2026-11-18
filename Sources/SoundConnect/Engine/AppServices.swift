import Foundation
import ServiceManagement
import UserNotifications
import os

enum Prefs {
    static let pauseOnRemove = "pauseOnRemove"
    static let resumeOnWear = "resumeOnWear"
    static let pauseOtherApps = "pauseOtherApps"
    static let lowBatteryAlerts = "lowBatteryAlerts"
    static let showBatteryInMenuBar = "showBatteryInMenuBar"
    static let breakReminderMinutes = "breakReminderMinutes"
    static let rememberLocation = "rememberLocation"
    static let autoEQStrength = "autoEQStrength"
    static let trackExposure = "trackExposure"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            pauseOnRemove: true,
            resumeOnWear: true,
            pauseOtherApps: true,
            lowBatteryAlerts: true,
            showBatteryInMenuBar: true,
            breakReminderMinutes: 0,
            rememberLocation: true,
            autoEQStrength: 0.7,
            trackExposure: true,
        ])
    }
}

/// Posts a notification when the headphone battery drops through 20% and again through 10%.
@MainActor
final class BatteryNotifier {
    private static let thresholds = [20, 10]
    private var lastLevel: Int?
    private var authorized = false

    init() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            Task { @MainActor in self.authorized = ok }
        }
    }

    func update(battery: Battery?, model: String) {
        guard let battery else { return }
        defer { lastLevel = battery.level }
        guard let last = lastLevel, !battery.charging,
              UserDefaults.standard.bool(forKey: Prefs.lowBatteryAlerts), authorized,
              let crossed = Self.thresholds.first(where: { last > $0 && battery.level <= $0 })
        else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(model.isEmpty ? "Headphones" : model) battery low"
        content.body = crossed <= 10
            ? "\(battery.level)% remaining. Charge soon to avoid losing noise cancelling."
            : "\(battery.level)% remaining."
        content.sound = .default
        let req = UNNotificationRequest(identifier: "battery-\(crossed)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("login item: \(error.localizedDescription, privacy: .public)")
        }
    }
}
