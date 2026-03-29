//
//  TrainNotificationManager.swift
//  myLatest
//
//  Manages scheduled local notifications for train status updates.
//  Notifications are only available when Victorian Transport is selected.
//
//  Strategy:
//  • Schedules non-repeating notifications for each upcoming day/time slot
//    over the next 7 days, populated with live train data fetched at scheduling time.
//  • Registers a BGAppRefreshTask to periodically re-fetch train data and
//    reschedule notifications with fresh content in the background.
//  • Also refreshes whenever the app comes to the foreground.
//

import Foundation
import UserNotifications
import BackgroundTasks

// MARK: - Notification Schedule Model

struct NotificationTimeEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var hour: Int       // 0-23
    var minute: Int     // 0-59

    var displayString: String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        let ampm = hour < 12 ? "AM" : "PM"
        return String(format: "%d:%02d %@", h, minute, ampm)
    }

    /// Date with just the time components set, for use with DatePicker.
    var asDate: Date {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components) ?? .now
    }

    static func from(date: Date) -> NotificationTimeEntry {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return NotificationTimeEntry(hour: comps.hour ?? 8, minute: comps.minute ?? 0)
    }
}

struct NotificationSchedule: Codable, Equatable {
    /// Days enabled: 1 = Sunday, 2 = Monday, ... 7 = Saturday (matching Calendar weekday)
    var enabledDays: Set<Int> = []
    var times: [NotificationTimeEntry] = []
    var isEnabled: Bool = false

    static let maxTimes = 5
}

// MARK: - Manager

@Observable
final class TrainNotificationManager {
    static let shared = TrainNotificationManager()

    static let backgroundTaskIdentifier = "org.nando.myLatest.trainStatusRefresh"

    var schedule: NotificationSchedule {
        didSet { save(); refreshNotifications() }
    }

    var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let storageKey = "trainNotificationSchedule"
    private let notificationPrefix = "train_status_"

    private init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(NotificationSchedule.self, from: data) {
            self.schedule = decoded
        } else {
            self.schedule = NotificationSchedule()
        }
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(schedule) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await MainActor.run {
                self.authorizationStatus = granted ? .authorized : .denied
            }
        } catch {
            await MainActor.run {
                self.authorizationStatus = .denied
            }
        }
    }

    func checkAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run {
            self.authorizationStatus = settings.authorizationStatus
        }
    }

    // MARK: - Background Task Registration

    /// Call once at app launch to register the background task handler.
    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundTaskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: true)
                return
            }
            TrainNotificationManager.shared.handleBackgroundRefresh(task: refreshTask)
        }
    }

    /// Schedule the next background refresh.
    func scheduleBackgroundRefresh() {
        guard schedule.isEnabled else { return }

        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskIdentifier)
        // Ask iOS to run it in ~30 minutes (iOS may delay further)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("⚠️ Failed to schedule background refresh: \(error)")
        }
    }

    /// Handle a background refresh: fetch live data, reschedule notifications.
    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        let fetchTask = Task {
            await fetchAndScheduleNotifications()
            scheduleBackgroundRefresh() // schedule the next one
        }

        task.expirationHandler = {
            fetchTask.cancel()
        }

        Task {
            _ = await fetchTask.result
            task.setTaskCompleted(success: true)
        }
    }

    // MARK: - Refresh Notifications (Main Entry Point)

    /// Fetches live train data and schedules notifications with real content.
    /// Called on app foreground, after manual fetch, and from background task.
    func refreshNotifications() {
        Task { await fetchAndScheduleNotifications() }
    }

    /// Schedules notifications using previously fetched train info (no network call).
    /// Use this right after a dashboard fetch to avoid a redundant API call.
    func scheduleWithTrainInfo(_ trainInfo: TrainInfo) async {
        removeAllTrainNotifications()

        guard schedule.isEnabled, !schedule.enabledDays.isEmpty, !schedule.times.isEmpty else { return }

        let upcomingDates = computeUpcomingFireDates()
        let content = buildNotificationContent(from: trainInfo)

        for fireDate in upcomingDates {
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let id = "\(notificationPrefix)\(fireDate.timeIntervalSince1970)"
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            try? await UNUserNotificationCenter.current().add(request)
        }

        scheduleBackgroundRefresh()
    }

    // MARK: - Private: Fetch + Schedule

    private func fetchAndScheduleNotifications() async {
        removeAllTrainNotifications()

        guard schedule.isEnabled, !schedule.enabledDays.isEmpty, !schedule.times.isEmpty else { return }

        // Read settings
        let lineName = UserDefaults.standard.string(forKey: "trainLineName") ?? ""
        let homeStation = UserDefaults.standard.string(forKey: "homeStation") ?? ""
        let cityStation = UserDefaults.standard.string(forKey: "cityStation") ?? "Flinders Street"
        let transportMode = UserDefaults.standard.string(forKey: "transportMode") ?? "victorian"

        guard transportMode == TransportMode.victorian.rawValue, !lineName.isEmpty else { return }

        // Fetch live train data
        let trainInfo: TrainInfo?
        do {
            trainInfo = try await TrainService.shared.fetchTrainInfo(
                lineName: lineName,
                homeStation: homeStation,
                cityStation: cityStation
            )
        } catch {
            print("⚠️ Notification fetch failed: \(error.localizedDescription)")
            trainInfo = nil
        }

        let content: UNMutableNotificationContent
        if let trainInfo {
            content = buildNotificationContent(from: trainInfo)
        } else {
            // Fallback if fetch fails — still provide useful content
            content = UNMutableNotificationContent()
            content.title = "🚆 \(lineName) Line"
            content.body = "Unable to fetch live status. Open the app to check."
            content.sound = .default
        }

        let upcomingDates = computeUpcomingFireDates()

        for fireDate in upcomingDates {
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let id = "\(notificationPrefix)\(fireDate.timeIntervalSince1970)"
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            try? await UNUserNotificationCenter.current().add(request)
        }

        scheduleBackgroundRefresh()
    }

    // MARK: - Build Notification Content

    private func buildNotificationContent(from trainInfo: TrainInfo) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "🚆 \(trainInfo.lineName) Line"
        content.sound = .default
        content.categoryIdentifier = "TRAIN_STATUS"

        if trainInfo.serviceIsGood {
            content.body = "✅ Good service"
        } else {
            var body = "⚠️ \(trainInfo.serviceStatusMessage)"
            for alert in trainInfo.alerts.prefix(2) {
                let text = alert.plainText.prefix(200)
                body += "\n• \(text)"
            }
            content.body = body
        }

        // Subtitle: next departure
        if let next = trainInfo.homeStationDepartures.first {
            let direction = next.isToCity ? "→ City" : "← Outbound"
            content.subtitle = "\(trainInfo.homeStationName): \(next.estimatedDepartureStr) \(direction)"
        }

        return content
    }

    // MARK: - Compute Fire Dates

    /// Compute the next 7 days' worth of fire dates matching the schedule.
    private func computeUpcomingFireDates() -> [Date] {
        let calendar = Calendar.current
        let now = Date()
        var dates: [Date] = []

        for dayOffset in 0..<7 {
            guard let baseDate = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            let weekday = calendar.component(.weekday, from: baseDate)
            guard schedule.enabledDays.contains(weekday) else { continue }

            for time in schedule.times {
                var components = calendar.dateComponents([.year, .month, .day], from: baseDate)
                components.hour = time.hour
                components.minute = time.minute
                components.second = 0

                guard let fireDate = calendar.date(from: components),
                      fireDate > now else { continue }

                dates.append(fireDate)
            }
        }

        // iOS limits to 64 pending notifications — keep within budget
        return Array(dates.prefix(60))
    }

    // MARK: - Cleanup

    private func removeAllTrainNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let trainIDs = requests
                .filter { $0.identifier.hasPrefix(self.notificationPrefix) }
                .map(\.identifier)
            center.removePendingNotificationRequests(withIdentifiers: trainIDs)
        }
    }

    func disableAllNotifications() {
        schedule.isEnabled = false
        removeAllTrainNotifications()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
    }

    // MARK: - Day Names

    static let dayNames: [(weekday: Int, short: String, full: String)] = [
        (2, "Mon", "Monday"),
        (3, "Tue", "Tuesday"),
        (4, "Wed", "Wednesday"),
        (5, "Thu", "Thursday"),
        (6, "Fri", "Friday"),
        (7, "Sat", "Saturday"),
        (1, "Sun", "Sunday"),
    ]
}
