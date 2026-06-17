import Foundation
@preconcurrency import UserNotifications

final class MobileNotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    @MainActor static let shared = MobileNotificationScheduler()

    private static let categoryID = "knotq-reminder"
    static let actionMarkDone = "knotq.mark_done"
    static let actionSnooze10Minutes = "knotq.snooze.10m"
    static let actionSnooze1Hour = "knotq.snooze.1h"
    static let actionSnooze2Hours = "knotq.snooze.2h"
    static let actionSnooze6Hours = "knotq.snooze.6h"
    static let actionSnooze24Hours = "knotq.snooze.1d"
    static let actionSnoozeTomorrowMorning = "knotq.snooze.tomorrow_morning"
    private static let snoozeActions: [(id: String, title: String)] = [
        (actionSnooze10Minutes, "Snooze 10m"),
        (actionSnooze1Hour, "Snooze 1h"),
        (actionSnooze2Hours, "Snooze 2h"),
        (actionSnooze6Hours, "Snooze 6h"),
        (actionSnooze24Hours, "Snooze 24h"),
        (actionSnoozeTomorrowMorning, "Tomorrow Morning")
    ]

    @MainActor weak var model: AppModel?

    private let center = UNUserNotificationCenter.current()
    private let iso = ISO8601DateFormatter()

    private override init() {
        super.init()
        iso.formatOptions = [.withInternetDateTime]
    }

    @MainActor
    func configure(model: AppModel) {
        self.model = model
        center.delegate = self
        registerCategories()
        #if DEBUG
        guard !AppModel.screenshotFixtureRequested else { return }
        #endif
        center.requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    @MainActor
    func reschedule(_ requests: [MobileNotificationRequest]) {
        let desired = requests
            .compactMap(notificationRequest)
            .prefix(64)
        let desiredByID = Dictionary(uniqueKeysWithValues: desired.map { ($0.id, $0) })

        // Reconcile only *pending* (not-yet-fired) requests. Delivered
        // notifications are intentionally left in Notification Center so they
        // persist until the user dismisses them or picks an action (Mark Done /
        // Snooze) — iOS clears a delivered notification automatically when an
        // action is chosen. Previously we also removed any delivered
        // notification that wasn't in the desired set, but `desired` only ever
        // contains *future* requests, so every notification that had already
        // fired was treated as stale and wiped on the next refresh.
        center.getPendingNotificationRequests { [center, desiredByID] pending in
            let managedPending = pending
                .map(\.identifier)
                .filter { $0.hasPrefix("knotq-") }
            if !managedPending.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: managedPending)
            }

            for request in desiredByID.values.sorted(by: { $0.fireAt < $1.fireAt }) {
                center.add(request.notificationRequest)
            }
        }
    }

    /// Set the app icon badge to the current overdue count. `0` clears it.
    @MainActor
    func updateBadgeCount(_ count: Int) {
        center.setBadgeCount(max(0, count)) { _ in }
    }

    private func notificationRequest(_ request: MobileNotificationRequest) -> PendingMobileNotification? {
        guard let fireAt = iso.date(from: request.fireAt) else { return nil }
        guard fireAt > Date() else { return nil }
        let interval = max(1, fireAt.timeIntervalSinceNow)
        let content = UNMutableNotificationContent()
        content.title = request.title.isEmpty ? "KnotQ" : request.title
        content.body = request.body.isEmpty ? "Scheduled item" : request.body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = Self.categoryID
        content.threadIdentifier = request.schemeId
        content.userInfo = [
            "notification_key": request.notificationKey,
            "scheme_id": request.schemeId,
            "item_id": request.itemId,
            "occurrence_json": request.occurrenceJson,
            "trigger_at": request.triggerAt,
            "kind": request.kind,
            "expires_at": request.expiresAt ?? ""
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        return PendingMobileNotification(
            id: request.id,
            fireAt: request.fireAt,
            notificationRequest: UNNotificationRequest(
                identifier: request.id,
                content: content,
                trigger: trigger
            )
        )
    }

    private func registerCategories() {
        let snoozeActions = Self.snoozeActions.map { action in
            UNNotificationAction(identifier: action.id, title: action.title, options: [])
        }
        let markDone = UNNotificationAction(
            identifier: Self.actionMarkDone,
            title: "Mark Done",
            options: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryID,
                actions: snoozeActions + [markDone],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Include `.list` so a notification that fires while the app is in the
        // foreground is also added to Notification Center and persists there,
        // matching how it behaves when delivered in the background. Without it
        // foreground notifications only flash a banner and leave no trace.
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        guard actionID == Self.actionMarkDone
            || Self.snoozeActions.contains(where: { $0.id == actionID })
        else {
            completionHandler()
            return
        }
        let info = response.notification.request.content.userInfo
        guard let schemeID = info["scheme_id"] as? String,
              let itemID = info["item_id"] as? String,
              let occurrenceJSON = info["occurrence_json"] as? String,
              let triggerAt = info["trigger_at"] as? String
        else {
            completionHandler()
            return
        }

        let request = MobileNotificationActionRequest(
            actionID: actionID,
            schemeID: schemeID,
            itemID: itemID,
            occurrenceJSON: occurrenceJSON,
            triggerAt: triggerAt
        )
        Task { @MainActor in
            MobileNotificationScheduler.shared.model?.handleNotificationAction(request)
        }
        completionHandler()
    }
}

private struct PendingMobileNotification: @unchecked Sendable {
    let id: String
    let fireAt: String
    let notificationRequest: UNNotificationRequest
}
