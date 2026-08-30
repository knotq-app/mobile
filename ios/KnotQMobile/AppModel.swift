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

    @Published var snapshot: MobileSnapshot? {
        didSet {
            // The launch screen stays up until this goes non-nil, so this — not
            // any single code path — is when the user first sees the app.
            guard oldValue == nil, snapshot != nil, !loggedFirstSnapshot else { return }
            loggedFirstSnapshot = true
            CoreTiming.launch("first snapshot installed", since: CoreTiming.sinceProcessStart())
        }
    }
    private var loggedFirstSnapshot = false
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
    /// Scheme writes submitted to the bridge queue but not yet reflected in
    /// `snapshot`. See `SchemeWriteTracker` for why readers must care.
    @Published private(set) var schemeWrites = SchemeWriteTracker()

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
    /// Search rebuilds the Rust index, so a typing burst must collapse to its
    /// final query instead of occupying the serial bridge queue once per key.
    var searchTask: Task<Void, Never>?
    var searchGeneration = 0
    /// A full snapshot rebuild also recalculates notifications and serializes a
    /// widget payload. Lifecycle and navigation callbacks routinely arrive in
    /// bursts, so keep one bridge read active and remember only that a fresher
    /// one is needed after it lands.
    var refreshFlight = RefreshFlightGate()
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
        CoreTiming.launch("AppModel.init entered", since: CoreTiming.sinceProcessStart())
        bridge = try? RustBridge()
        CoreTiming.launch("core opened", since: CoreTiming.sinceProcessStart())
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
        // Never read the first snapshot synchronously on the main actor. A cold
        // Release launch can spend several seconds opening and indexing the
        // workspace, which kept UIKit on the empty system launch screen and made
        // the app look permanently black. `refresh()` uses the serial bridge
        // queue; ContentView renders its visible loading state until it publishes
        // the resulting snapshot.
        refresh()
        CoreTiming.launch("AppModel.init done", since: CoreTiming.sinceProcessStart())
        #if ACCOUNTS_ENABLED
        startSyncPolling()
        #if IN_APP_PURCHASES_ENABLED
        startTransactionListener()
        #endif
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
        case "rose_pine_moon", "catppuccin_mocha", "tokyo_night": .dark
        case "parchment", "rose_pine_dawn", "catppuccin_latte": .light
        default: nil
        }
    }

    /// Whether to keep the periodic background refresh scheduled. Always true:
    /// the task's real work (`runBackgroundMaintenance`) is *local* maintenance —
    /// republish the widget snapshot, recompute the overdue badge, tear down
    /// banners for occurrences that have since passed — and none of that needs an
    /// account. Gating it on `supportsSync || googleAccountCount > 0` meant a
    /// purely local user never scheduled the task at all, so their widget and
    /// badge only changed when they opened the app; that is the "widget/badge is
    /// stale until I restart" report. Cloud and Google sync inside the task
    /// already no-op without a session, so scheduling for everyone costs a
    /// snapshot read every few hours.
    var backgroundRefreshEligible: Bool { true }

    var canLoadOlderDailyHistory: Bool {
        dailyHistoryDays < Self.maxDailyHistoryDays
    }

    func refresh() {
        guard let bridge else { return }
        guard refreshFlight.request() else { return }
        startRefresh(using: bridge)
    }

    /// Starts a refresh already admitted by `refreshFlight`. A queued follow-up
    /// calls this directly because the gate remains in flight across the handoff.
    private func startRefresh(using bridge: RustBridge) {
        let today = Self.dateOnly(selectedDate)
        let week = weekOffset
        let history = dailyHistoryDays
        let loadAnchorDate = pendingDailyHistoryLoadAnchorDate
        let isDailyHistoryLoad = loadAnchorDate != nil
        pendingDailyHistoryLoadAnchorDate = nil
        let logLaunchRead = !loggedFirstSnapshot
        bridge.enqueue({ b in
            let result = (
                try b.snapshot(today: today, weekOffset: week, dailyHistoryDays: history),
                try b.pendingNotifications(),
                try b.deliveredNotificationsToClear()
            )
            // Separates core work from the wait for the main actor: this runs on
            // the bridge queue, the "first snapshot installed" mark on the main
            // one. A gap between them is SwiftUI's first render, not the core.
            if logLaunchRead {
                CoreTiming.launch("launch read ready", since: CoreTiming.sinceProcessStart())
            }
            return result
        }) { [weak self] result in
            guard let self else { return }
            var shouldApplyResult = true
            if isDailyHistoryLoad {
                self.dailyHistoryLoadInProgress = false
                if Self.dateOnly(self.selectedDate) != today {
                    self.dailyHistoryLoadAnchorDate = nil
                    shouldApplyResult = false
                }
            }
            if shouldApplyResult {
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
            if self.refreshFlight.finish() {
                self.startRefresh(using: bridge)
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
        // Creates the new day's daily queue if it isn't there yet. The rebuild is
        // unconditional: "today" moved, so every date-relative marker, the daily
        // feed, the notification schedule and any now-stale banners have to be
        // recomputed even when the queue already existed (a background sync may
        // have created it).
        ensureTodayDailyQueue()
        refresh()
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
        let firstSnapshot = self.snapshot == nil
        let snapshotChanged = Self.shouldPublishSnapshot(current: self.snapshot, next: snapshot)
        // Periodic and lifecycle refreshes must still reconcile notifications,
        // but publishing an equal value wakes every SwiftUI observer and can
        // rebuild a large home/calendar tree for no visible change.
        if snapshotChanged {
            self.snapshot = snapshot
            KnotQWidgetSnapshotStore.publish(snapshot: snapshot)
            if firstSnapshot {
                CoreTiming.launch("widget published", since: CoreTiming.sinceProcessStart())
            }
            MobileNotificationScheduler.shared.updateBadgeCount(Self.overdueBadgeCount(for: snapshot))
            configureGoogleSyncPolling(accountCount: snapshot.settings.googleAccountCount)
            BackgroundSyncCoordinator.shared.scheduleIfEligible(backgroundRefreshEligible)
        }
        MobileNotificationScheduler.shared.reschedule(pendingNotifications)
        MobileNotificationScheduler.shared.clearDelivered(staleNotificationIds)
        if firstSnapshot {
            CoreTiming.launch("first apply done", since: CoreTiming.sinceProcessStart())
        }
    }

    /// Kept separate from `apply` so the equality gate is pinned by unit tests.
    static func shouldPublishSnapshot(current: MobileSnapshot?, next: MobileSnapshot) -> Bool {
        current != next
    }

    /// Install the visual result of a local occurrence toggle before the Rust
    /// write and snapshot rebuild finish. The core remains authoritative: the
    /// next completed mutation replaces this temporary value with a fresh
    /// snapshot. Keeping this narrow to the exact occurrence is important for
    /// recurring items, where toggling one instance must not mark every
    /// instance done on screen.
    func optimisticallyToggleOccurrence(_ target: MobileOccurrence) {
        guard let current = snapshot else { return }
        let toggled = Self.toggledOccurrence(in: current, target: target)
        guard toggled != current else { return }
        snapshot = toggled
        KnotQWidgetSnapshotStore.publish(snapshot: toggled)
        MobileNotificationScheduler.shared.updateBadgeCount(Self.overdueBadgeCount(for: toggled))
    }

    static func toggledOccurrence(in snapshot: MobileSnapshot, target: MobileOccurrence) -> MobileSnapshot {
        var result = snapshot
        func matches(_ occurrence: MobileOccurrence) -> Bool {
            occurrence.schemeId == target.schemeId
                && occurrence.itemId == target.itemId
                && occurrence.occurrenceJson == target.occurrenceJson
        }
        func toggle(_ occurrences: inout [MobileOccurrence]) {
            for index in occurrences.indices where matches(occurrences[index]) {
                occurrences[index].done.toggle()
            }
        }
        toggle(&result.calendar.upcoming)
        toggle(&result.calendar.overdue)
        for dayIndex in result.calendar.days.indices {
            toggle(&result.calendar.days[dayIndex].occurrences)
        }
        return result
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

    /// `mutate` for a write scoped to one scheme. Holds the scheme in
    /// `schemeWrites` for the whole flight so views that rebuild scheme
    /// content from `snapshot` can tell that what they can see is already stale.
    ///
    /// Every item-level operation belongs here, not just `replaceSchemeItems`:
    /// a checkbox toggled from the daily feed is equally invisible to a reader
    /// until it lands, and if the user starts typing in that window the editor's
    /// baseline predates the toggle — so the mid-edit merge treats the line as
    /// locally modified and writes the pre-toggle `done` back over it.
    func mutateScheme(
        _ schemeID: String,
        _ action: @escaping @Sendable (RustBridge) throws -> Void,
        completion: (@MainActor () -> Void)? = nil
    ) {
        // `mutate` returns without running the completion when there is no
        // bridge, which would strand the count and leave editors for this scheme
        // deferring their load forever.
        guard bridge != nil else { return }
        schemeWrites.begin(schemeID)
        mutate(action) { [weak self] in
            self?.schemeWrites.end(schemeID)
            completion?()
        }
    }

    /// `mutateScheme` for a write that touches more than one document.
    func mutateSchemes(
        _ schemeIDs: [String],
        _ action: @escaping @Sendable (RustBridge) throws -> Void,
        completion: (@MainActor () -> Void)? = nil
    ) {
        guard bridge != nil else { return }
        let tracked = schemeWrites.begin(schemeIDs)
        mutate(action) { [weak self] in
            self?.schemeWrites.end(tracked)
            completion?()
        }
    }

    /// Number of overdue items shown on the app icon badge. Completed-but-retained
    /// occurrences (kept faded on the upcoming panel) are excluded so the badge
    /// only counts things that still need attention.
    static func overdueBadgeCount(for snapshot: MobileSnapshot) -> Int {
        snapshot.calendar.overdue.filter { !$0.done }.count
    }

    /// Republish the widget snapshot and recompute the overdue badge from a fresh
    /// core read. Used by background maintenance so both keep up with time passing
    /// even when no remote change arrives to drive a normal `refresh()`.
    ///
    /// The widget publish matters as much as the badge: the stored snapshot is a
    /// point-in-time list, and the widget extension can only *filter* it (drop
    /// events that have ended) — it can never pull in an occurrence that has since
    /// come into range. Without republishing here, a user who doesn't open the app
    /// watches their widget drain to empty.
    ///
    /// `self.snapshot` is deliberately not assigned: this read uses the default
    /// `dailyHistoryDays`, so installing it would discard any older daily history
    /// the user has paged in.
    func refreshWidgetAndBadge() async {
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
        KnotQWidgetSnapshotStore.publish(snapshot: result.0)
        // Tear down banners for events that ended (or occurrences completed)
        // while backgrounded, so they don't linger until the next foreground.
        MobileNotificationScheduler.shared.clearDelivered(result.1)
        MobileNotificationScheduler.shared.updateBadgeCount(Self.overdueBadgeCount(for: result.0))
    }

    func search(_ query: String, debounce: Bool = true) {
        guard let bridge else { return }
        searchGeneration &+= 1
        let generation = searchGeneration
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchHits = []
            searchTask = nil
            return
        }
        searchTask = Task { [weak self, bridge] in
            if debounce {
                try? await Task.sleep(nanoseconds: 140_000_000)
            }
            guard !Task.isCancelled else { return }
            bridge.enqueue({ try $0.search(trimmed) }) { [weak self] result in
                guard let self, self.searchGeneration == generation else { return }
                self.searchTask = nil
                switch result {
                case .success(let hits):
                    self.searchHits = hits
                    self.errorMessage = nil
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
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
