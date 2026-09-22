import BackgroundTasks
import FirebaseCore
import FirebaseMessaging
import os
import UIKit

final class KnotQAppDelegate: NSObject, UIApplicationDelegate, MessagingDelegate {
    private static let log = Logger(subsystem: "com.enigmadux.knotq", category: "push-registration")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        CoreTiming.launch("didFinishLaunching entered", since: CoreTiming.sinceProcessStart())
        FirebaseApp.configure()
        CoreTiming.launch("firebase configured", since: CoreTiming.sinceProcessStart())
        BackgroundSyncCoordinator.shared.register()
        Task { @MainActor in
            MobileNotificationScheduler.shared.prepareForLaunch()
        }
        configureFirebaseMessaging(application)
        CoreTiming.launch("didFinishLaunching done", since: CoreTiming.sinceProcessStart())
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        let model = AppModel.shared
        BackgroundSyncCoordinator.shared.scheduleIfEligible(model.backgroundRefreshEligible)
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Messaging.messaging().apnsToken = deviceToken
        // Awaited rather than given a completion closure. `UIApplicationDelegate`
        // is main-actor isolated, so a closure literal written here inherits that
        // isolation while Firebase delivers the token on one of its own queues —
        // and Swift 6's dynamic isolation check traps the process when it does.
        // See `MobileNotificationScheduler.updateBadgeCount`, where the same
        // shape crashed the app on every core write.
        Task { @MainActor in
            do {
                let token = try await Messaging.messaging().token()
                AppModel.shared.setPushToken(token, environment: Self.pushEnvironment)
            } catch {
                Self.log.error("FCM token fetch failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Self.log.error("APNs registration failed: \(String(describing: error), privacy: .public)")
        AppModel.shared.setPushToken("")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Messaging.messaging().appDidReceiveMessage(userInfo)
        BackgroundSyncCoordinator.shared.handleRemoteNotification(
            userInfo: userInfo,
            completionHandler: completionHandler
        )
    }

    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken, !fcmToken.isEmpty else {
            Task { @MainActor in
                Self.log.error("FCM registration callback returned no token")
            }
            return
        }
        Task { @MainActor in
            AppModel.shared.setPushToken(fcmToken, environment: Self.pushEnvironment)
        }
    }

    private func configureFirebaseMessaging(_ application: UIApplication) {
        Messaging.messaging().delegate = self
        application.registerForRemoteNotifications()
    }

    private static var pushEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }
}

@MainActor
final class BackgroundSyncCoordinator {
    static let shared = BackgroundSyncCoordinator()

    static let taskIdentifier = "com.enigmadux.knotq.background-sync"
    private static let refreshInterval: TimeInterval = 3 * 60 * 60
    private static let log = Logger(subsystem: "com.enigmadux.knotq", category: "background-sync")

    private var registered = false
    private var requestScheduled = false
    private var lastScheduleFailureAt: Date?

    private init() {}

    @MainActor
    func register() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handle(refreshTask)
        }
        if !registered {
            Self.log.error("background task registration failed")
        }
    }

    @MainActor
    func scheduleIfEligible(_ eligible: Bool) {
        guard eligible else {
            cancel()
            return
        }
        guard !requestScheduled else { return }
        // Replace our prior request. Repeated auth refreshes, foreground
        // transitions, and push wakes are coalesced so the scheduler does not
        // churn or reject a burst for exceeding its pending-request quota.
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.refreshInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
            requestScheduled = true
            lastScheduleFailureAt = nil
        } catch {
            // The simulator commonly returns `notPermitted`; keep the failure
            // observable without flooding logs when lifecycle callbacks repeat.
            let now = Date()
            if lastScheduleFailureAt.map({ now.timeIntervalSince($0) >= 15 * 60 }) ?? true {
                lastScheduleFailureAt = now
                Self.log.error("background task scheduling failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        requestScheduled = false
    }

    func handleRemoteNotification(
        userInfo: [AnyHashable: Any],
        completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            guard Self.isKnotQBackgroundPush(userInfo) else {
                completionHandler(.noData)
                return
            }
            let model = AppModel.shared
            scheduleIfEligible(model.backgroundRefreshEligible)
            // This wake means a peer pushed — tell the core so the sync can't be
            // coalesced away as idle.
            model.noteRemoteChanged()
            // Keep the assertion across the pull and notification re-arm so iOS
            // cannot suspend the process between those two durable effects.
            let changed = await model.withBackgroundAssertion("knotq.background-push") {
                await model.runBackgroundSync()
            }
            completionHandler(changed ? .newData : .noData)
        }
    }

    private func handle(_ task: BGAppRefreshTask) {
        let completion = BackgroundTaskCompletion(task: task)
        requestScheduled = false
        let operation = Task { @MainActor in
            let model = AppModel.shared
            scheduleIfEligible(model.backgroundRefreshEligible)
            let success = await model.withBackgroundAssertion("knotq.background-refresh") {
                await model.runBackgroundMaintenance()
            }
            completion.finish(success: success)
        }
        task.expirationHandler = {
            operation.cancel()
            completion.finish(success: false)
        }
    }

    static func isKnotQBackgroundPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let type = userInfo["type"] as? String else { return false }
        return type == "notification_schedule_changed"
    }
}

private final class BackgroundTaskCompletion {
    private let lock = NSLock()
    private var completed = false
    private weak var task: BGTask?

    init(task: BGTask) {
        self.task = task
    }

    func finish(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }
        completed = true
        task?.setTaskCompleted(success: success)
    }
}
