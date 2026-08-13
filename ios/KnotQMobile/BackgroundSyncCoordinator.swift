import BackgroundTasks
import FirebaseCore
import FirebaseMessaging
import UIKit

final class KnotQAppDelegate: NSObject, UIApplicationDelegate, MessagingDelegate {
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
        Messaging.messaging().token { token, _ in
            guard let token else { return }
            Task { @MainActor in
                AppModel.shared.setPushToken(token, environment: Self.pushEnvironment)
            }
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
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
        guard let fcmToken, !fcmToken.isEmpty else { return }
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

    private var registered = false

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
    }

    @MainActor
    func scheduleIfEligible(_ eligible: Bool) {
        guard eligible else {
            cancel()
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.refreshInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            return
        }
    }

    func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
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
            let changed = await model.runBackgroundSync()
            completionHandler(changed ? .newData : .noData)
        }
    }

    private func handle(_ task: BGAppRefreshTask) {
        let completion = BackgroundTaskCompletion(task: task)
        let operation = Task { @MainActor in
            let model = AppModel.shared
            scheduleIfEligible(model.backgroundRefreshEligible)
            let success = await model.runBackgroundMaintenance()
            completion.finish(success: success)
        }
        task.expirationHandler = {
            operation.cancel()
            completion.finish(success: false)
        }
    }

    private static func isKnotQBackgroundPush(_ userInfo: [AnyHashable: Any]) -> Bool {
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
