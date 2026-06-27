import StoreKit
import SwiftUI
import UIKit

@main
struct KnotQMobileApp: App {
    @UIApplicationDelegateAdaptor(KnotQAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(model.preferredColorScheme)
                .onAppear {
                    MobileReviewPrompt.maybeRequestReview()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // Re-check the sync entitlement + subscription lifecycle whenever
                        // the app returns to the foreground, so a subscription bought (or
                        // changed) while it was backgrounded shows up without waiting for
                        // the access token to expire. Cold launch and sign-in are covered
                        // by startSyncPolling's own refresh.
                        Task { await model.refreshSubscriptionStatus() }
                        MobileReviewPrompt.maybeRequestReview()
                        // Re-open the sync socket on return to the foreground.
                        model.startWsSync()
                    case .background:
                        // Push a still-debounced edit before we suspend, so editing then
                        // backgrounding doesn't strand the change until the ~3 h refresh.
                        model.flushPendingEditSync()
                        // Tear the socket down while suspended (FCM + the 3h refresh
                        // cover background wakeups).
                        model.stopWsSync()
                    default:
                        break
                    }
                }
        }
    }
}

private enum MobileReviewPrompt {
    private static let firstLaunchAtKey = "knotq.mobile.reviewFirstLaunchAt.v1"
    private static let promptedKey = "knotq.mobile.reviewPrompted.v1"
    private static let onboardingCompletedKey = "knotq.mobile.onboardingCompleted.v1"
    private static let minimumUsageInterval: TimeInterval = 14 * 24 * 60 * 60

    @MainActor
    static func maybeRequestReview() {
        #if DEBUG
        guard !AppModel.screenshotFixtureRequested else { return }
        #endif

        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        let firstLaunchAt = usageStartAt(defaults: defaults, now: now)

        guard defaults.bool(forKey: onboardingCompletedKey) else { return }
        guard !defaults.bool(forKey: promptedKey) else { return }
        guard now - firstLaunchAt >= minimumUsageInterval else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else {
            return
        }

        defaults.set(true, forKey: promptedKey)
        SKStoreReviewController.requestReview(in: scene)
    }

    private static func usageStartAt(defaults: UserDefaults, now: TimeInterval) -> TimeInterval {
        let stored = defaults.double(forKey: firstLaunchAtKey)
        guard stored <= 0 else { return stored }

        let inferred = inferredInstallDate()?.timeIntervalSince1970 ?? now
        defaults.set(inferred, forKey: firstLaunchAtKey)
        return inferred
    }

    private static func inferredInstallDate() -> Date? {
        let manager = FileManager.default
        let directories: [FileManager.SearchPathDirectory] = [
            .documentDirectory,
            .applicationSupportDirectory,
        ]

        return directories
            .compactMap { manager.urls(for: $0, in: .userDomainMask).first }
            .compactMap { url in
                try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
            }
            .min()
    }
}
