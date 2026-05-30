import Foundation
@preconcurrency import UserNotifications

final class MobileNotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    @MainActor static let shared = MobileNotificationScheduler()

    private static let categoryID = "knotq-reminder"
    static let actionMarkDone = "knotq.mark_done"
    static let actionSnooze10Minutes = "knotq.snooze.10m"
    static let actionSnooze1Hour = "knotq.snooze.1h"

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
        center.requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    @MainActor
    func reschedule(_ requests: [MobileNotificationRequest]) {
        let desired = requests
            .compactMap(notificationRequest)
            .prefix(64)
        let desiredByID = Dictionary(uniqueKeysWithValues: desired.map { ($0.id, $0) })

        center.getPendingNotificationRequests { [center, desiredByID] pending in
            let managedPending = pending
                .map(\.identifier)
                .filter { $0.hasPrefix("knotq-") }
            if !managedPending.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: managedPending)
            }

            center.getDeliveredNotifications { [center, desiredByID] delivered in
                let staleDelivered = delivered
                    .map(\.request.identifier)
                    .filter { $0.hasPrefix("knotq-") && desiredByID[$0] == nil }
                if !staleDelivered.isEmpty {
                    center.removeDeliveredNotifications(withIdentifiers: staleDelivered)
                }

                for request in desiredByID.values.sorted(by: { $0.fireAt < $1.fireAt }) {
                    center.add(request.notificationRequest)
                }
            }
        }
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
        let snooze10 = UNNotificationAction(
            identifier: Self.actionSnooze10Minutes,
            title: "Snooze 10m",
            options: []
        )
        let snooze1h = UNNotificationAction(
            identifier: Self.actionSnooze1Hour,
            title: "Snooze 1h",
            options: []
        )
        let markDone = UNNotificationAction(
            identifier: Self.actionMarkDone,
            title: "Mark Done",
            options: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryID,
                actions: [snooze10, snooze1h, markDone],
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
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        guard [
            Self.actionMarkDone,
            Self.actionSnooze10Minutes,
            Self.actionSnooze1Hour
        ].contains(actionID) else {
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
