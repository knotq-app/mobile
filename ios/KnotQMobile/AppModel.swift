import AuthenticationServices
import CryptoKit
import Foundation
import StoreKit
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    // Shared instance so the SwiftUI App and the UIApplicationDelegate (background
    // tasks, push handling) operate on the same model + Rust core.
    static let shared = AppModel()

    @Published var snapshot: MobileSnapshot?
    @Published var searchHits: [MobileSearchHit] = []
    @Published var errorMessage: String?
    @Published var selectedDate = Date()
    @Published var weekOffset = 0
    @Published var syncSession: LocalSyncSession?
    @Published var syncAuthInProgress = false
    // True while a destructive account action, such as cancelling a subscription,
    // is in flight, so Settings can disable its buttons.
    @Published var syncAccountActionInProgress = false
    // Set once step 1 of account deletion (re-auth) succeeds and the one-time code
    // is emailed; cleared on completion or cancel. Drives the OTP entry step.
    @Published var pendingDeletionChallengeId: String?
    // Set from /v1/auth/account/status: the subscription is cancelled (won't renew)
    // but sync stays active until the period ends, so Settings offers to re-enable.
    @Published var subscriptionCancelled = false
    // The provider backing the current subscription ("apple"/"google"/"web"), used to
    // route the re-enable action to the store or our backend.
    @Published var subscriptionProvider: String?
    // Set from /v1/auth/account/status: whether the account email is confirmed.
    // `nil` = not checked yet. Subscribing is gated on a confirmed email, so the
    // Sync card disables the purchase button and prompts to verify when this is false.
    @Published var emailVerified: Bool?
    @Published var resendVerificationInProgress = false
    // Frontend cooldown (seconds remaining) for the resend button, a soft limit on
    // top of the backend's own rate limit. Driven by `resendCooldownTask`.
    @Published var resendVerificationCooldown = 0
    @Published var syncInProgress = false
    @Published var syncOffline = false
    @Published var googleAuthInProgress = false
    @Published var googleSyncInProgress = false
    @Published var googleCalendarStatus: String?
    // Available StoreKit subscription products (empty until loaded / if unconfigured).
    @Published var syncProducts: [Product] = []
    @Published var purchaseInProgress = false
    @Published var dailyHistoryLoadAnchorDate: String?
    @Published var dailyHistoryLoadInProgress = false

    // App Store Connect product id(s) for the sync subscription.
    static let syncProductIDs: Set<String> = ["com.enigmadux.knotq.sync.monthly"]
    static let minimumDailyHistoryDays = 3
    /// Days of daily history loaded on first open. Kept small — most sessions
    /// only touch the last few days — so the initial snapshot builds fast; older
    /// days page in (a month at a time) as the feed scrolls up.
    static let initialDailyHistoryWindowDays = 7
    static let dailyHistoryPageDays = 31
    static let maxDailyHistoryDays = 3650
    static let foregroundGoogleSyncIntervalNanos: UInt64 = 120_000_000_000
    static let backgroundGoogleSyncInterval: TimeInterval = 6 * 60 * 60
    // Debounce for the push that follows a local edit: a short leading window so
    // a burst of edits coalesces into one push while still feeling instant. With
    // the persistent socket a push is a cheap frame (no HTTP round-trip), and the
    // `syncInProgress` guard already caps it to one in-flight sync at a time, so
    // this can be short like desktop's WS local-change debounce (~300 ms). The 30 s
    // foreground poll + the blur/background flush remain the backstops.
    static let editSyncDebounceNanos: UInt64 = 400_000_000

    let bridge: RustBridge?
    let iso = ISO8601DateFormatter()
    let syncSessionKey = "knotq.localSyncSession"
    let backgroundGoogleSyncKey = "knotq.lastBackgroundGoogleSyncAt"
    var syncPollTask: Task<Void, Never>?
    var googleSyncTask: Task<Void, Never>?
    // Non-nil while a post-edit push is waiting out its debounce window.
    var pendingEditSyncTask: Task<Void, Never>?
    var resendCooldownTask: Task<Void, Never>?
    var googleOAuthSession: WebAuthenticationSessionCoordinator?
    var browserSignInSession: WebAuthenticationSessionCoordinator?
    var transactionListener: Task<Void, Never>?
    var dailyHistoryDays = AppModel.initialDailyHistoryDays(for: Date())
    var pendingDailyHistoryLoadAnchorDate: String?
    // Calendar day the model is currently anchored to. Used to notice a midnight
    // rollover (or timezone shift) so the home/daily "today" doesn't go stale
    // while the app stays alive or sits backgrounded across midnight.
    var anchoredDay = Calendar.current.startOfDay(for: Date())

    init() {
        bridge = try? RustBridge()
        iso.formatOptions = [.withInternetDateTime]
        syncSession = Self.loadSyncSession(key: syncSessionKey)
        if bridge == nil {
            errorMessage = "Rust core failed to initialize"
        }
        MobileNotificationScheduler.shared.configure(model: self)
        // Roll the daily/home "today" forward when the system day changes while the
        // app is alive. Backgrounded-across-midnight is handled separately on
        // scenePhase `.active`, since this notification only fires while running.
        NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDayRolloverIfNeeded() }
        }
        #if DEBUG
        let seededScreenshotFixture = seedScreenshotFixtureIfRequested()
        #endif
        // refresh() now hops through the bridge queue; read the first snapshot
        // directly so the initial frame isn't blank. Nothing else contends for
        // the core this early, so this stays fast.
        if let bridge {
            snapshot = try? bridge.snapshot(
                today: Self.dateOnly(selectedDate),
                weekOffset: weekOffset,
                dailyHistoryDays: dailyHistoryDays
            )
        }
        refresh()
        #if ACCOUNTS_ENABLED
        startSyncPolling()
        startTransactionListener()
        #endif
        #if DEBUG
        if !seededScreenshotFixture {
            seedEditorImageFixture()
        }
        #endif
    }

    var preferredColorScheme: ColorScheme? {
        switch snapshot?.settings.themeMode {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var backgroundRefreshEligible: Bool {
        syncSession?.supportsSync == true || (snapshot?.settings.googleAccountCount ?? 0) > 0
    }

    var canLoadOlderDailyHistory: Bool {
        dailyHistoryDays < Self.maxDailyHistoryDays
    }

    func refresh() {
        guard let bridge else { return }
        let today = Self.dateOnly(selectedDate)
        let week = weekOffset
        let history = dailyHistoryDays
        let loadAnchorDate = pendingDailyHistoryLoadAnchorDate
        let isDailyHistoryLoad = loadAnchorDate != nil
        pendingDailyHistoryLoadAnchorDate = nil
        bridge.enqueue({ b in
            (
                try b.snapshot(today: today, weekOffset: week, dailyHistoryDays: history),
                try b.pendingNotifications(),
                try b.deliveredNotificationsToClear()
            )
        }) { [weak self] result in
            guard let self else { return }
            if isDailyHistoryLoad {
                self.dailyHistoryLoadInProgress = false
                guard Self.dateOnly(self.selectedDate) == today else {
                    self.dailyHistoryLoadAnchorDate = nil
                    return
                }
            }
            switch result {
            case .success(let (snapshot, pending, staleNotificationIds)):
                self.apply(
                    snapshot: snapshot,
                    pendingNotifications: pending,
                    staleNotificationIds: staleNotificationIds
                )
                if isDailyHistoryLoad {
                    self.dailyHistoryLoadAnchorDate = loadAnchorDate
                }
                self.errorMessage = nil
            case .failure(let error):
                if isDailyHistoryLoad {
                    self.dailyHistoryLoadAnchorDate = nil
                }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Re-anchor to the current calendar day after a rollover. If the user was
    /// parked on what used to be "today" (the common case), advance the selected
    /// date with it; if they'd navigated to another day, keep their selection but
    /// still rebuild so today's daily queue exists and "today" markers refresh.
    /// Safe to call on every foreground — it no-ops while the day is unchanged.
    func handleDayRolloverIfNeeded() {
        let today = Calendar.current.startOfDay(for: Date())
        guard today != anchoredDay else { return }
        let wasOnPreviousToday = Calendar.current.startOfDay(for: selectedDate) == anchoredDay
        anchoredDay = today
        if wasOnPreviousToday {
            selectedDate = Date()
            weekOffset = 0
        }
        // Creates the new day's daily queue and rebuilds the snapshot, which also
        // reschedules notifications and clears any now-stale banners.
        ensureTodayDailyQueue()
    }

    func loadOlderDailyEntries(from oldestDate: String) {
        guard !dailyHistoryLoadInProgress else { return }
        let nextDailyHistoryDays = min(
            dailyHistoryDays + Self.dailyHistoryPageDays,
            Self.maxDailyHistoryDays
        )
        guard nextDailyHistoryDays > dailyHistoryDays else { return }
        pendingDailyHistoryLoadAnchorDate = oldestDate
        dailyHistoryDays = nextDailyHistoryDays
        dailyHistoryLoadInProgress = true
        refresh()
    }

    func clearDailyHistoryLoadAnchor() {
        dailyHistoryLoadAnchorDate = nil
    }

    /// Install a freshly-read snapshot plus its derived state. Always runs on
    /// the main actor with data produced on the bridge queue. `staleNotificationIds`
    /// are delivered banners the core says no longer apply (event ended, or the
    /// occurrence was completed) — cleared from Notification Center here.
    func apply(
        snapshot: MobileSnapshot,
        pendingNotifications: [MobileNotificationRequest],
        staleNotificationIds: [String] = []
    ) {
        self.snapshot = snapshot
        KnotQWidgetSnapshotStore.publish(snapshot: snapshot)
        MobileNotificationScheduler.shared.reschedule(pendingNotifications)
        MobileNotificationScheduler.shared.clearDelivered(staleNotificationIds)
        MobileNotificationScheduler.shared.updateBadgeCount(Self.overdueBadgeCount(for: snapshot))
        configureGoogleSyncPolling(accountCount: snapshot.settings.googleAccountCount)
        BackgroundSyncCoordinator.shared.scheduleIfEligible(backgroundRefreshEligible)
    }

    /// Await-able variant of `refresh()` for background wakes: installs the
    /// fresh snapshot AND re-arms the OS notification schedule before returning.
    /// The background task reports completion off this — and iOS suspends the
    /// process right after — so the reschedule must not be fire-and-forget: a
    /// suspended half-applied reschedule is how a synced change ends up with no
    /// local notification armed while the (persisted) widget still shows it.
    func refreshAndRearmNotifications() async {
        guard let bridge else { return }
        let today = Self.dateOnly(selectedDate)
        let week = weekOffset
        let history = dailyHistoryDays
        guard let result = try? await bridge.perform({ b in
            (
                try b.snapshot(today: today, weekOffset: week, dailyHistoryDays: history),
                try b.pendingNotifications(),
                try b.deliveredNotificationsToClear()
            )
        }) else { return }
        snapshot = result.0
        KnotQWidgetSnapshotStore.publish(snapshot: result.0)
        await MobileNotificationScheduler.shared.rescheduleNow(result.1)
        MobileNotificationScheduler.shared.clearDelivered(result.2)
        MobileNotificationScheduler.shared.updateBadgeCount(Self.overdueBadgeCount(for: result.0))
        configureGoogleSyncPolling(accountCount: result.0.settings.googleAccountCount)
        BackgroundSyncCoordinator.shared.scheduleIfEligible(backgroundRefreshEligible)
    }

    /// Re-arm the OS notification schedule from the core's current (on-disk)
    /// state without a snapshot rebuild. Run on background wakes that found no
    /// remote change: if an earlier run was suspended mid-reschedule, this
    /// restores the schedule, so every wake self-heals instead of trusting that
    /// the last reschedule completed.
    func rearmNotificationsNow() async {
        guard let bridge else { return }
        guard let result = try? await bridge.perform({ b in
            (try b.pendingNotifications(), try b.deliveredNotificationsToClear())
        }) else { return }
        await MobileNotificationScheduler.shared.rescheduleNow(result.0)
        MobileNotificationScheduler.shared.clearDelivered(result.1)
    }

    /// Number of overdue items shown on the app icon badge. Completed-but-retained
    /// occurrences (kept faded on the upcoming panel) are excluded so the badge
    /// only counts things that still need attention.
    static func overdueBadgeCount(for snapshot: MobileSnapshot) -> Int {
        snapshot.calendar.overdue.filter { !$0.done }.count
    }

    /// Recompute the overdue badge from a fresh snapshot. Used by background
    /// maintenance so the badge keeps up with time passing even when no remote
    /// change arrives to drive a normal `refresh()`.
    func refreshOverdueBadge() async {
        guard let bridge else { return }
        let today = Self.dateOnly(selectedDate)
        let week = weekOffset
        guard let result = try? await bridge.perform({ b in
            (
                try b.snapshot(today: today, weekOffset: week),
                try b.deliveredNotificationsToClear()
            )
        })
        else {
            return
        }
        // Tear down banners for events that ended (or occurrences completed)
        // while backgrounded, so they don't linger until the next foreground.
        MobileNotificationScheduler.shared.clearDelivered(result.1)
        MobileNotificationScheduler.shared.updateBadgeCount(Self.overdueBadgeCount(for: result.0))
    }

    func search(_ query: String) {
        guard let bridge else { return }
        bridge.enqueue({ try $0.search(query) }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let hits):
                self.searchHits = hits
                self.errorMessage = nil
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func dismissErrorMessage() {
        let dismissedMessage = errorMessage
        Task { @MainActor [weak self] in
            await Task.yield()
            if self?.errorMessage == dismissedMessage {
                self?.errorMessage = nil
            }
        }
    }

    func monthDays(year: Int, month: Int) async -> [MobileCalendarDay] {
        guard let bridge else { return [] }
        return (try? await bridge.perform { try $0.monthDays(year: year, month: month) }) ?? []
    }

    static func dateOnly(_ date: Date) -> String {
        MobileDate.dateOnly(date)
    }

    static func displayDate(_ raw: String) -> String {
        MobileDate.displayDate(raw)
    }

    static func date(from raw: String) -> Date? {
        MobileDate.parseDateOnly(raw)
    }
}

