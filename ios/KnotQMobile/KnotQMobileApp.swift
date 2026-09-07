import StoreKit
import SwiftUI
import UIKit

@main
struct KnotQMobileApp: App {
    @UIApplicationDelegateAdaptor(KnotQAppDelegate.self) private var appDelegate
    // Localizes core-produced strings (sync status, daily labels). Declared before
    // `model` so its default-value initializer runs first (stored property
    // defaults run in declaration order before any other property's), i.e.
    // before `AppModel.shared` takes the first workspace/settings snapshot.
    private let localeConfigured: Bool = {
        setLocale(tag: Locale.preferredLanguages.first ?? "en")
        return true
    }()
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(model.preferredColorScheme)
                .onAppear {
                    MobileReviewPrompt.maybeRequestReview()
                    // Build the system keyboard while the app is idle, so the
                    // first tap into a scheme or the daily gets the same
                    // keyboard presentation as every tap after it.
                    KeyboardWarmup.warmSoon()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // Advance the daily/home "today" if the day rolled over while
                        // the app was backgrounded, so it isn't stuck on yesterday.
                        model.handleDayRolloverIfNeeded()
                        // Re-read the core on every return to the foreground. The
                        // snapshot on screen was built when the app was last active and
                        // the core buckets occurrences against *that* moment, so coming
                        // back hours later leaves items that are now overdue sitting
                        // under Upcoming until some unrelated edit triggers a refresh.
                        // This republishes the widget and badge too. Safe while typing:
                        // the editor's `loadDocument` refuses to reload a dirty
                        // controller, so unflushed keystrokes are never overwritten.
                        model.refresh()
                        // Re-check the sync entitlement + subscription lifecycle whenever
                        // the app returns to the foreground, so a subscription bought (or
                        // changed) while it was backgrounded shows up without waiting for
                        // the access token to expire. Cold launch and sign-in are covered
                        // by startSyncPolling's own refresh.
                        #if ACCOUNTS_ENABLED
                        Task { await model.resumeForegroundSync() }
                        #endif
                        MobileReviewPrompt.maybeRequestReview()
                    case .inactive:
                        // Blur: the app just lost focus but the socket is still alive.
                        // Push a still-debounced edit over it right away so a quick
                        // edit-then-switch reaches peers immediately, rather than
                        // waiting for the debounce/poll or the slower background flush.
                        // The socket stays up (the app may return to active at once).
                        model.flushPendingEditSyncOverWebSocket()
                    case .background:
                        // Flush any still-pending edit over the live socket, THEN tear
                        // the socket down (order matters — the push must ride the open
                        // socket, not a fresh HTTP handshake). Usually `.inactive`
                        // already flushed, so this is mostly the teardown.
                        model.flushPendingEditSyncAndTeardown()
                        // Apply a reschedule the debounce deferred — its trailing timer
                        // never fires once we're suspended.
                        MobileNotificationScheduler.shared.flushPendingReschedule()
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
