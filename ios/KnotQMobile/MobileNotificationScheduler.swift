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

    /// Coalesce a burst of reschedule requests (sync pulls, rapid edits) before
    /// touching the OS notification center again, so we don't constantly re-arm
    /// the same schedule. Leading-edge: the first request in an idle period
    /// applies immediately; further requests inside the window collapse into a
    /// single trailing apply. Background wakes bypass this via `rescheduleNow`
    /// (a suspended process never runs the trailing timer), and
    /// `flushPendingReschedule` drains a deferred apply before the app suspends.
    private static let rescheduleDebounce: TimeInterval = 12
    private var latestDesired: [PendingMobileNotification]?
    private var rescheduleCooldownActive = false
    private var rescheduleTrailingPending = false
    /// Serializes applies so two in-flight reconciles can't interleave their
    /// read/add/remove sequences against the notification center.
    private var applyChain: Task<Void, Never>?

    private override init() {
        super.init()
        iso.formatOptions = [.withInternetDateTime]
    }

    @MainActor
    func configure(model: AppModel) {
        self.model = model
        center.delegate = self
        registerCategories()
    }

    @MainActor
    func requestAuthorizationIfNeeded() {
        #if DEBUG
        guard !AppModel.screenshotFixtureRequested else { return }
        #endif
        center.getNotificationSettings { [center] settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
        }
    }

    @MainActor
    func reschedule(_ requests: [MobileNotificationRequest]) {
        latestDesired = desiredSet(requests)
        guard !rescheduleCooldownActive else {
            // Inside the debounce window — coalesce. The trailing apply picks up
            // this latest desired set when the cooldown ends.
            rescheduleTrailingPending = true
            return
        }
        applyLatestRescheduleAndStartCooldown()
    }

    /// Immediate, await-able reschedule for background wakes (silent push /
    /// BGAppRefreshTask): bypasses the debounce and returns only after the
    /// notification center has accepted the requests, so a background task that
    /// awaits this before reporting completion can't be suspended with the
    /// schedule half-armed.
    @MainActor
    func rescheduleNow(_ requests: [MobileNotificationRequest]) async {
        latestDesired = desiredSet(requests)
        rescheduleTrailingPending = false
        await enqueueApply().value
    }

    /// Drain a trailing apply the debounce deferred. Called as the app
    /// backgrounds: the trailing timer never fires in a suspended process, so
    /// without this a reschedule requested inside the cooldown window would be
    /// silently dropped until the next foreground.
    @MainActor
    func flushPendingReschedule() {
        guard rescheduleTrailingPending else { return }
        rescheduleTrailingPending = false
        enqueueApply()
    }

    private func desiredSet(_ requests: [MobileNotificationRequest]) -> [PendingMobileNotification] {
        Array(requests.compactMap(notificationRequest).prefix(64))
    }

    @MainActor
    private func applyLatestRescheduleAndStartCooldown() {
        rescheduleCooldownActive = true
        rescheduleTrailingPending = false
        enqueueApply()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rescheduleDebounce) { [weak self] in
            guard let self else { return }
            self.rescheduleCooldownActive = false
            if self.rescheduleTrailingPending {
                self.applyLatestRescheduleAndStartCooldown()
            }
        }
    }

    @MainActor
    @discardableResult
    private func enqueueApply() -> Task<Void, Never> {
        let previous = applyChain
        let next = Task { @MainActor [weak self] in
            await previous?.value
            await self?.applyLatestReschedule()
        }
        applyChain = next
        return next
    }

    @MainActor
    private func applyLatestReschedule() async {
        guard let desired = latestDesired else { return }
        let desiredByID = Dictionary(desired.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Notification ids are stable per occurrence (the fire time is not part of
        // the key), so a delivered banner whose id is in the *future* desired set
        // can only mean that occurrence was rescheduled — e.g. "remind me later"
        // chosen on another device and synced here. Clear that stale banner so the
        // rescheduled notification doesn't stack a second copy 10 minutes later.
        // A normally-delivered, still-relevant notification has already fired, so
        // its id never appears in `desired` and is left untouched.
        let desiredIDs = Array(desiredByID.keys)
        if !desiredIDs.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: desiredIDs)
        }

        // Reconcile only *pending* (not-yet-fired) requests, and ADD FIRST:
        // adding with an existing identifier atomically replaces it, so the
        // desired set is fully armed before anything is torn down. The previous
        // remove-everything-then-re-add ordering left a window where a
        // suspension wiped every armed notification with the rebuild never
        // running. Other delivered banners are intentionally left in
        // Notification Center so they persist until the user dismisses them or
        // picks an action; the core's `delivered_notifications_to_clear`
        // (completed occurrences / expired events) drives any other removals
        // via `clearDelivered`.
        let previouslyPending = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix("knotq-") }

        for request in desiredByID.values.sorted(by: { $0.fireAt < $1.fireAt }) {
            try? await center.add(request.notificationRequest)
        }

        let stale = previouslyPending.filter { desiredByID[$0] == nil }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }
    }

    /// Tear down delivered (and any still-pending) notifications the core has
    /// flagged as stale — an event whose end time has passed, or an occurrence
    /// that was completed. `reschedule` deliberately leaves delivered banners in
    /// place, so this is the path that removes them from Notification Center once
    /// they no longer apply.
    @MainActor
    func clearDelivered(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
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
            "expires_at": request.expiresAt ?? "",
            "end_at": request.endAt ?? ""
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
