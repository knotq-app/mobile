import AuthenticationServices
import CryptoKit
import Foundation
import StoreKit
import SwiftUI
import UIKit

extension AppModel {
#if ACCOUNTS_ENABLED
    /// Hand the Rust core a push token (e.g. an FCM token from Firebase) so the
    /// next sync registers this device for silent background wake-ups.
    func setPushToken(_ token: String, environment: String = "production") {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            PushTokenStore.remove()
        } else {
            _ = PushTokenStore.save(.init(token: normalized, environment: environment))
        }
        guard let bridge else { return }
        bridge.enqueue({ try $0.setPushRegistration(token: normalized, environment: environment) }) { [weak self] result in
            guard let self, case .success = result else { return }
            if self.syncSession?.supportsSync == true {
                Task { await self.runBackgroundSync() }
            }
        }
    }

    /// Flag in the core that a peer pushed (a silent FCM wake-up arrived), so the
    /// upcoming `sync_once` cannot be coalesced away as an "idle" sync. The
    /// coalescer's recency clock is monotonic and pauses while the device sleeps,
    /// so without this a wake shortly after the last sync pulls nothing. Enqueued
    /// on the serial bridge queue, so it lands before a sync enqueued after it.
    func noteRemoteChanged() {
        guard let bridge else { return }
        bridge.enqueue({ try $0.noteRemoteChanged() }) { _ in }
    }
#else
    // Accounts/sync disabled: no-op stubs so shared callers still compile.
    func setPushToken(_ token: String, environment: String = "production") {}
    func noteRemoteChanged() {}
#endif

#if ACCOUNTS_ENABLED
    /// One-shot sync used by background app refresh and silent pushes. Guarded so it
    /// can't race the foreground poll; returns whether remote changes were applied.
    @discardableResult
    func runBackgroundSync(preferLiveSocket: Bool = false) async -> Bool {
        guard !syncInProgress, let session = syncSession, session.supportsSync else { return false }
        let sessionGeneration = syncSessionGeneration.value
        syncInProgress = true
        defer { syncInProgress = false }
        // Background resyncs normally ride plain HTTP. The socket should already be
        // down (the scenePhase handler tears it down), but if iOS suspended us
        // before that teardown ran, the core still holds a client whose socket died
        // with the suspension — drop it so the pull can't stall on a zombie
        // transport. Foreground re-opens it on scenePhase .active.
        //
        // A flush fired the instant the app blurs/backgrounds is the exception: the
        // socket is still alive, so `preferLiveSocket` keeps it up and this sync's
        // push rides the already-open connection (no fresh TLS handshake) — the
        // fastest way to get a just-made edit to peers. The caller tears the socket
        // down afterward (see flushPendingEditSyncAndTeardown).
        if !preferLiveSocket, UIApplication.shared.applicationState == .background {
            stopWsSync()
        }
        guard await refreshSyncSessionIfNeeded() == .ready else { return false }
        guard syncSessionGeneration.matches(sessionGeneration) else { return false }

        // One reactive auth retry. The proactive refresh above only fires when our
        // local expiry check says the token is near expiry; if the backend rejects
        // the bearer token anyway (clock skew, an early server-side revoke, or a key
        // rotation we missed), force a single refresh and try once more. A silent
        // push wakes us only briefly, so giving up on the first 401 would strand this
        // device until the next push or the ~3 h BGAppRefreshTask. Bounded to one
        // forced refresh so a genuinely dead session can't loop.
        var triedAuthRefresh = false
        while true {
            guard syncSessionGeneration.matches(sessionGeneration),
                  let bridge,
                  let current = syncSession,
                  current.supportsSync else { return false }
            let apiBase = current.apiBase
            let bearerToken = current.bearerToken
            do {
                let result = try await bridge.perform { b in
                    let changed = try b.syncOnce(
                        apiBase: apiBase,
                        bearerToken: bearerToken,
                        accountUserID: current.userId
                    )
                    let notice = try b.takeSyncNotice()
                    return (changed, notice)
                }
                guard syncSessionGeneration.matches(sessionGeneration) else { return false }
                if result.0 {
                    // Await the snapshot install AND the notification re-arm
                    // before returning: the background-task completion handler
                    // fires off our return value and iOS suspends the process
                    // right after, so a fire-and-forget refresh() here left the
                    // pulled change persisted with no UNNotificationRequest armed.
                    await refreshAndRearmNotifications()
                } else {
                    // No remote change, but re-arm from disk anyway so a wake
                    // self-heals a schedule lost by an earlier interrupted run.
                    await rearmNotificationsNow()
                }
                guard syncSessionGeneration.matches(sessionGeneration) else { return false }
                if let notice = result.1 {
                    errorMessage = notice
                }
                syncOffline = false
                return result.0
            } catch {
                guard syncSessionGeneration.matches(sessionGeneration) else { return false }
                // A terminal refresh failure signs out inside refreshSyncSessionIfNeeded;
                // a transient one returns non-.ready, so we fall through and bail.
                if !triedAuthRefresh,
                   Self.isAuthRejection(error),
                   await refreshSyncSessionIfNeeded(force: true) == .ready {
                    guard syncSessionGeneration.matches(sessionGeneration) else { return false }
                    triedAuthRefresh = true
                    let hadWs = await isWsConnected()
                    // If this ran while the foreground socket was up, rebuild it
                    // before retrying so the new handshake uses the fresh token.
                    stopWsSync()
                    if hadWs {
                        startWsSync()
                    }
                    continue
                }
                if Self.isLikelyNetworkError(error) {
                    syncOffline = true
                }
                return false
            }
        }
    }
#else
    @discardableResult
    func runBackgroundSync(preferLiveSocket: Bool = false) async -> Bool { false }
#endif

    /// One-shot background maintenance used by BGAppRefreshTask. Cloud sync runs
    /// whenever eligible; Google Calendar sync is throttled separately because it
    /// can fan out into several Google API calls.
    @discardableResult
    func runBackgroundMaintenance() async -> Bool {
        let remoteChanged = await runBackgroundSync()
        let googleSynced = await runBackgroundGoogleCalendarSyncIfDue()
        // Republish the widget and badge before the task finishes (and the app may
        // suspend) so both stay current even when nothing synced — which is the
        // only thing this task does for a purely local, no-account user.
        await refreshWidgetAndBadge()
        return remoteChanged || googleSynced
    }

#if ACCOUNTS_ENABLED
    func syncOnce(force: Bool = false) async {
        // Set the in-progress guard before refreshing so concurrent callers bail
        // out — two simultaneous refreshes would replay the same (single-use)
        // refresh token and trip the server's reuse detection, revoking the session.
        guard !syncInProgress, syncSession != nil else { return }
        let sessionGeneration = syncSessionGeneration.value
        syncInProgress = true
        defer { syncInProgress = false }

        // Refresh the short-lived access token if it's near expiry (persisting the
        // rotated credentials), or bail out if the session is gone.
        // A foreground pull should not pay a refresh round-trip for a token that
        // is still usable. If it expires during the pull, the bounded 401 retry
        // below refreshes it once. This removes the common startup auth stall
        // while retaining correctness at the expiry boundary.
        guard await refreshSyncSessionIfNeeded(minimumValidity: 15) == .ready else { return }
        guard syncSessionGeneration.matches(sessionGeneration) else { return }

        var triedAuthRefresh = false
        while true {
            guard syncSessionGeneration.matches(sessionGeneration),
                  let bridge,
                  let session = syncSession,
                  session.supportsSync else { return }
            do {
                let apiBase = session.apiBase
                let bearerToken = session.bearerToken
                let result = try await bridge.perform { b in
                    let changed = try force
                        ? b.forceSyncOnce(
                            apiBase: apiBase,
                            bearerToken: bearerToken,
                            accountUserID: session.userId
                        )
                        : b.syncOnce(
                            apiBase: apiBase,
                            bearerToken: bearerToken,
                            accountUserID: session.userId
                        )
                    let notice = try b.takeSyncNotice()
                    return (changed, notice)
                }
                guard syncSessionGeneration.matches(sessionGeneration) else { return }
                if result.0 {
                    refresh()
                }
                syncOffline = false
                errorMessage = result.1
                return
            } catch {
                guard syncSessionGeneration.matches(sessionGeneration) else { return }
                if !triedAuthRefresh, Self.isAuthRejection(error) {
                    switch await refreshSyncSessionIfNeeded(force: true) {
                    case .ready:
                        guard syncSessionGeneration.matches(sessionGeneration) else { return }
                        triedAuthRefresh = true
                        // Rebuild the socket: the current connection was authenticated
                        // with the token the backend just rejected.
                        stopWsSync()
                        startWsSync()
                        continue
                    case .deferred:
                        syncOffline = true
                        errorMessage = nil
                        return
                    case .sessionDead:
                        return
                    }
                }
                if Self.isAuthRejection(error) {
                    // A rejected short-lived bearer can still be a race with a
                    // token rotation, an in-flight request, or a delayed socket
                    // reconnect. We already attempted the one safe forced refresh
                    // above; never present this transient/auth-transport failure as
                    // a user-facing "Unauthorized" alert. The only sync-auth alert
                    // is produced below by the refresh endpoint's explicit terminal
                    // refresh-token response.
                    syncOffline = true
                    errorMessage = nil
                } else if Self.isLikelyNetworkError(error) {
                    syncOffline = true
                    errorMessage = nil
                } else {
                    errorMessage = error.localizedDescription
                }
                return
            }
        }
    }

    func scheduleSync() {
        guard syncSession != nil else { return }
        Task { await self.syncOnce() }
    }

    /// A visible user action must not be quietly coalesced behind a recent poll
    /// or sent through a socket that survived app suspension. Refresh the session,
    /// rebuild the socket for later background updates, then make a forced HTTP
    /// pull through the shared core.
    func manualResync() async {
        guard await refreshEntitlement(scheduleSyncWhenReady: false) else { return }
        stopWsSync()
        startWsSync()
        await syncOnce(force: true)
    }

    /// Push that follows a local edit, debounced so a burst of edits coalesces
    /// into one sync instead of pushing on every mutation. Leading-window like
    /// desktop: the first edit of a burst arms the timer and later edits don't
    /// postpone it. The 30 s foreground poll backstops a continuous edit, and the
    /// blur/background flush (see `flushPendingEditSyncOverWebSocket`) pushes over
    /// the live socket before the app suspends.
    func scheduleEditSync() {
        guard syncSession != nil, pendingEditSyncTask == nil else { return }
        pendingEditSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.editSyncDebounceNanos)
            guard let self, !Task.isCancelled else { return }
            self.pendingEditSyncTask = nil
            await self.syncOnce()
        }
    }

    /// Blur (scenePhase `.inactive`): the app just lost focus but the socket is
    /// still alive. If a local edit is still debounced, push it over the *live*
    /// socket right now — the fastest way to get it to peers (no fresh TLS
    /// handshake) — instead of waiting out the 400 ms debounce, the 30 s poll, or
    /// the background flush. The socket is deliberately left up because the app may
    /// return to active immediately (a transient blur: Control Center, a banner, an
    /// incoming call). Wrapped in a background assertion so the push completes even
    /// if the blur turns into a full background. No-op when no edit is pending.
    func flushPendingEditSyncOverWebSocket() {
        guard pendingEditSyncTask != nil else { return }
        pendingEditSyncTask?.cancel()
        pendingEditSyncTask = nil
        Task { [weak self] in
            guard let self else { return }
            _ = await self.withBackgroundAssertion("knotq.flush-edit-sync.blur") {
                await self.runBackgroundSync(preferLiveSocket: true)
            }
        }
    }

    /// Backgrounding (scenePhase `.background`): flush any still-pending edit over
    /// the live socket, THEN tear the socket down. Order matters — the teardown runs
    /// only after the push completes, so the push rides the open socket instead of a
    /// fresh HTTP handshake, and the two operations share one serial Task so a
    /// separate `stopWsSync()` can't race ahead of the push. The socket is always
    /// dropped afterward (a socket left open into a suspended process becomes a
    /// zombie that stalls the next pull); FCM + the ~3 h refresh cover wakeups.
    /// Normally `.inactive` already flushed the edit, so this is usually a plain
    /// teardown, but it still flushes as a safety net for the edit-then-background
    /// path that skips a distinct `.inactive`.
    func flushPendingEditSyncAndTeardown() {
        let hadPendingEdit = pendingEditSyncTask != nil
        pendingEditSyncTask?.cancel()
        pendingEditSyncTask = nil
        Task { [weak self] in
            guard let self else { return }
            if hadPendingEdit {
                _ = await self.withBackgroundAssertion("knotq.flush-edit-sync") {
                    await self.runBackgroundSync(preferLiveSocket: true)
                }
            }
            self.stopWsSync()
        }
    }

    func refreshSyncSessionForAccountAction() async -> Bool {
        switch await refreshSyncSessionIfNeeded() {
        case .ready:
            return true
        case .deferred:
            errorMessage = "Sync is offline. Try again when your connection is back."
            return false
        case .sessionDead:
            return false
        }
    }

    /// Refresh the access token before syncing if it's near expiry, persisting the
    /// rotated credentials immediately. `.sessionDead` is only returned when the
    /// auth endpoint rejects the refresh token; transient failures leave the account
    /// signed in and mark sync offline.
    func refreshSyncSessionIfNeeded(
        force: Bool = false,
        minimumValidity: TimeInterval = 120
    ) async -> SyncSessionRefreshResult {
        guard let session = syncSession else { return .sessionDead }
        let sessionGeneration = syncSessionGeneration.value
        guard Self.isSecureSyncApiBase(session.apiBase) else {
            errorMessage = L10n.t("sync.error.api_url_https_required")
            return .deferred
        }
        guard !session.refreshToken.isEmpty else {
            syncOffline = true
            return .deferred
        }
        guard (force || Self.tokenNeedsRefresh(session.expiresAt, minimumValidity: minimumValidity)),
              let url = URL(string: "\(session.apiBase)/v1/auth/refresh")
        else {
            return .ready
        }
        do {
            var request = URLRequest(url: url)
            // A foreground sync must not sit behind URLSession's several-minute
            // default timeout when the auth service is unreachable. The sync
            // retry loop will try again on the next tick.
            request.timeoutInterval = 5
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": session.refreshToken])
            // Hold a background-task assertion across the rotation so iOS lets the
            // request finish — and lets us persist the rotated token below — even if
            // the user backgrounds the app mid-flight. A bare foreground URLSession
            // request is cancelled on suspend; losing the rotation response here (the
            // server has already advanced the generation) is exactly what looks like
            // refresh-token reuse on the next launch and signs the user out.
            let (data, response) = try await withBackgroundAssertion("knotq.auth.refresh") {
                try await MobileHTTPResponseLimits.data(for: request)
            }
            let http = response
            // Do not let a refresh response from a previous login sign out or
            // overwrite a newer session installed while the request was away.
            guard syncSessionGeneration.matches(sessionGeneration) else { return .deferred }
            if Self.isTerminalRefreshError(http, data) {
                // The auth API explicitly rejected this refresh credential.
                signOutSync()
                errorMessage = "Your sync session expired. Please sign in again."
                return .sessionDead
            }
            guard (200..<300).contains(http.statusCode) else {
                // Transient server error: keep the current token, retry next tick.
                syncOffline = true
                return .deferred
            }
            let payload = try JSONDecoder().decode(SyncLoginResponse.self, from: data)
            var updated = session
            updated.bearerToken = payload.bearerToken
            updated.expiresAt = payload.expiresAt
            updated.refreshToken = payload.refreshToken
            updated.refreshExpiresAt = payload.refreshExpiresAt
            updated.supportsSync = payload.supportsSync
            syncSession = updated
            syncOffline = false
            saveSyncSession(updated)
            BackgroundSyncCoordinator.shared.scheduleIfEligible(backgroundRefreshEligible)
            return .ready
        } catch {
            // Network/parse hiccup: keep the current token, retry next tick.
            syncOffline = true
            return .deferred
        }
    }
#else
    // Accounts/sync disabled: no-op stubs preserving signatures for shared callers.
    func syncOnce(force: Bool = false) async {}
    func scheduleSync() {}
    func manualResync() async {}
    func scheduleEditSync() {}
    func flushPendingEditSyncOverWebSocket() {}
    func flushPendingEditSyncAndTeardown() {}
    func refreshSyncSessionForAccountAction() async -> Bool { false }
    func refreshSyncSessionIfNeeded(force: Bool = false) async -> SyncSessionRefreshResult { .sessionDead }
#endif

    /// Run a short, critical async network call under a UIKit background-task
    /// assertion so it can finish even if the user backgrounds the app mid-request.
    /// The token rotation is the motivating case: a foreground `URLSession` request
    /// is cancelled when iOS suspends the app, so without this the server can advance
    /// the refresh-token generation while we never persist the rotated token — and on
    /// the next launch that lost rotation looks like refresh-token reuse, revoking the
    /// whole session and signing the user out. Bounded by iOS's background-time
    /// budget; if the expiration handler fires first the request just fails and is
    /// retried next tick (recoverable), which is strictly better than losing a
    /// committed rotation. The server's reuse-grace window is the backstop for the
    /// residual case where the app is outright killed mid-rotation.
    func withBackgroundAssertion<T>(
        _ name: String,
        _ work: () async throws -> T
    ) async rethrows -> T {
        let app = UIApplication.shared
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = app.beginBackgroundTask(withName: name) {
            if taskID != .invalid {
                app.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
        defer {
            if taskID != .invalid {
                app.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
        return try await work()
    }

    /// True when the access token expires within the skew window (or is
    /// unparseable, in which case we refresh defensively).
    static func tokenNeedsRefresh(
        _ expiresAt: String,
        minimumValidity: TimeInterval = 120
    ) -> Bool {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let expiry = withFraction.date(from: expiresAt) ?? plain.date(from: expiresAt) else {
            return true
        }
        return expiry.timeIntervalSinceNow <= minimumValidity
    }

    static func isLikelyNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return true
        }
        let message = error.localizedDescription.lowercased()
        return ["network", "request failed", "offline", "timed out", "cannot connect", "not connected"].contains { message.contains($0) }
    }

    /// The backend rejected the bearer token itself — an HTTP 401, which the auth
    /// middleware tags `unauthorized` and the core surfaces as that code. Distinct
    /// from a transient network error: the access token was refused, so a forced
    /// refresh + one retry can recover it (vs. a network blip, which just retries
    /// on the next tick with the same token).
    static func isAuthRejection(_ error: Error) -> Bool {
        guard case let MobileError.Core(reason) = error else { return false }
        return reason.contains("unauthorized")
    }

    /// A visible sign-in-again prompt is reserved for an explicit 401 from the
    /// refresh endpoint that says the long-lived refresh credential is unusable.
    /// Do not infer this from a failed bearer-token request or from a similarly
    /// shaped body on a transient server response.
    static func isTerminalRefreshError(_ response: HTTPURLResponse, _ data: Data) -> Bool {
        guard response.statusCode == 401 else { return false }
        guard
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let code = body["code"] as? String
        else {
            return false
        }
        return terminalRefreshErrorCodes.contains(code)
    }

    static let terminalRefreshErrorCodes: Set<String> = [
        "invalid_refresh_token",
        "refresh_token_reused",
        "account_closed"
    ]

    func scheme(id: String?) -> MobileScheme? {
        guard let id else { return nil }
        return snapshot?.schemes.first { $0.id == id }
            ?? snapshot?.daily.first { $0.scheme.id == id }?.scheme
            ?? snapshot?.archivedSchemes.first { $0.id == id }
    }

    /// Apply a local edit on the bridge queue, then install the resulting
    /// snapshot. The bridge queue is serial and FIFO, so edits submitted from
    /// the main thread land in UI order even though nothing blocks here.
    /// `completion` runs on the main actor after the refreshed snapshot is
    /// installed (or after the failure is recorded) — the earliest point where
    /// re-reading the model observes this mutation.
    func mutate(
        _ action: @escaping @Sendable (RustBridge) throws -> Void,
        completion: (@MainActor () -> Void)? = nil
    ) {
        guard let bridge else { return }
        let today = Self.dateOnly(selectedDate)
        let week = weekOffset
        let history = dailyHistoryDays
        let query = RefreshQuery(
            dateKey: today,
            weekOffset: week,
            dailyHistoryDays: history
        )
        bridge.enqueue({ b in
            let started = CFAbsoluteTimeGetCurrent()
            try action(b)
            let applied = CFAbsoluteTimeGetCurrent()
            let snapshot = try b.snapshot(today: today, weekOffset: week, dailyHistoryDays: history)
            let snapshotted = CFAbsoluteTimeGetCurrent()
            let result = (
                snapshot,
                try b.pendingNotifications(),
                try b.deliveredNotificationsToClear()
            )
            CoreTiming.record(
                edit: applied - started,
                snapshot: snapshotted - applied,
                notifications: CFAbsoluteTimeGetCurrent() - snapshotted
            )
            return result
        }) { [weak self] result in
            guard let self else {
                completion?()
                return
            }
            switch result {
            case .success(let (snapshot, pending, staleNotificationIds)):
                let currentQuery = RefreshQuery(
                    dateKey: Self.dateOnly(self.selectedDate),
                    weekOffset: self.weekOffset,
                    dailyHistoryDays: self.dailyHistoryDays
                )
                if currentQuery == query {
                    self.apply(
                        snapshot: snapshot,
                        pendingNotifications: pending,
                        staleNotificationIds: staleNotificationIds
                    )
                } else {
                    self.reconcileNotifications(
                        pendingNotifications: pending,
                        staleNotificationIds: staleNotificationIds
                    )
                    // A selection change normally already requests this read;
                    // request again so a direct property change or a completion
                    // race cannot leave the newly selected view stale.
                    self.refresh()
                }
                self.errorMessage = nil
                if self.syncSession != nil {
                    self.scheduleEditSync()
                }
            case .failure(let error):
                self.errorMessage = error.localizedDescription
                // An optimistic presentation (currently used by home-screen
                // occurrence toggles) must not survive a failed durable write.
                // Refresh is queued after the failed operation, so it also
                // preserves FIFO ordering with any writes submitted after it.
                self.refresh()
            }
            completion?()
        }
    }

    func handleNotificationAction(_ request: MobileNotificationActionRequest) {
        guard let bridge else { return }
        bridge.enqueue({ try $0.applyNotificationAction(request) }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let changed):
                if changed {
                    self.refresh()
                    if self.syncSession != nil {
                        self.scheduleSync()
                    }
                } else {
                    self.rescheduleNotifications()
                }
                self.errorMessage = nil
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Await-able counterpart to `handleNotificationAction`, for the notification
    /// delegate's completion handler.
    ///
    /// The delegate runs with the app in the *background* whenever an action is
    /// tapped from the lock screen or Notification Center, and iOS may suspend
    /// the process as soon as the completion handler returns. The widget
    /// snapshot and the icon badge are only published from `apply(snapshot:)`,
    /// i.e. from the completion of the async core write — so a fire-and-forget
    /// enqueue leaves both showing the pre-action state until something else
    /// relaunches the app. That is the "marked it done but the widget/badge
    /// still shows it" report. Awaiting the whole chain (and holding a
    /// background task assertion around it, see `applyAction`) is what makes the
    /// widget and badge update at the moment of the tap.
    @discardableResult
    func handleNotificationActionNow(_ request: MobileNotificationActionRequest) async -> Bool {
        guard let bridge else { return false }
        guard let changed = try? await bridge.perform({ try $0.applyNotificationAction(request) })
        else { return false }
        if changed {
            // Rebuilds the snapshot, republishes the widget store, recomputes the
            // badge and re-arms the OS schedule — all before we return.
            await refreshAndRearmNotifications()
        } else {
            await rearmNotificationsNow()
        }
        return changed
    }

    func rescheduleNotifications() {
        guard let bridge else { return }
        bridge.enqueue({ try $0.pendingNotifications() }) { [weak self] result in
            switch result {
            case .success(let pending):
                MobileNotificationScheduler.shared.reschedule(pending)
            case .failure(let error):
                self?.errorMessage = error.localizedDescription
            }
        }
    }

#if ACCOUNTS_ENABLED
    /// Reconcile immediately whenever iOS returns the app to the foreground.
    /// Silent pushes are best-effort, and a socket retained across suspension can
    /// briefly look connected even though it can no longer receive `changed`
    /// nudges. An already-entitled session does not need a status request before
    /// its pull: Rust's canonical workspace lookup and the sync response are the
    /// correctness path. Refresh entitlement after the pull so foreground resume
    /// does not serialize an auxiliary request ahead of convergence.
    func resumeForegroundSync() async {
        let needsEntitlementDiscovery = syncSession?.supportsSync != true
        if needsEntitlementDiscovery {
            await refreshSubscriptionStatus()
        }
        stopWsSync()
        await syncOnce()
        startWsSync()
        if !needsEntitlementDiscovery {
            // Sync just refreshed the bearer when it was near expiry. Read the
            // auxiliary lifecycle state with that bearer instead of rotating the
            // single-use refresh token a second time during startup/resume.
            Task { await self.refreshAccountStatus() }
        }
    }

    /// Open the persistent sync WebSocket for the current session (online, poll-free
    /// sync; `sync_once`'s pull/push then ride the socket). Idempotent in the core.
    func startWsSync() {
        guard let bridge, let session = syncSession, session.supportsSync else { return }
        let apiBase = session.apiBase
        let bearerToken = session.bearerToken
        bridge.enqueue({ b -> Bool in
            try b.startWsSync(apiBase: apiBase, bearerToken: bearerToken)
            return true
        }) { _ in }
    }

    /// Tear down the sync WebSocket (backgrounded / signed out); sync falls back to HTTP.
    func stopWsSync() {
        guard let bridge else { return }
        bridge.enqueue({ b -> Bool in
            try b.stopWsSync()
            return true
        }) { _ in }
    }

    /// Whether a server `changed` nudge is waiting (a peer pushed). Drives the
    /// prompt "live" receive sync below.
    func wsPendingChanged() async -> Bool {
        guard let bridge else { return false }
        return (try? await bridge.perform { try $0.wsPendingChanged() }) ?? false
    }

    /// Whether the persistent socket is currently up. Used only to gate the slow
    /// fallback poll — while connected, foreground sync is entirely socket-driven
    /// (no network polling).
    func isWsConnected() async -> Bool {
        guard let bridge else { return false }
        return (try? await bridge.perform { try $0.isWsConnected() }) ?? false
    }

    func startSyncPolling() {
        syncPollTask?.cancel()
        guard syncSession != nil else { return }
        syncPollTask = Task { [weak self] in
            guard let self else { return }
            // An entitled account needs no auxiliary status request before its
            // first sync: Rust already performs the authoritative account-status
            // lookup to obtain the canonical workspace id. Doing the Swift
            // status lookup first created two serial status requests plus the
            // pull on every cold launch. Free/unknown accounts still check first
            // so a newly granted entitlement can enable sync immediately.
            let needsEntitlementDiscovery = self.syncSession?.supportsSync != true
            if needsEntitlementDiscovery {
                await self.refreshSubscriptionStatus()
            }
            guard !Task.isCancelled else { return }
            await self.syncOnce()
            guard !Task.isCancelled else { return }
            if !needsEntitlementDiscovery {
                // Keep subscription lifecycle UI fresh, but take this auxiliary
                // read off the initial Resyncing critical path. Sync already
                // handled any needed bearer refresh above.
                Task { await self.refreshAccountStatus() }
            }
            // Establish the persistent transport only after the first sync has
            // completed. Starting it before the initial HTTP fallback races its
            // connection callback with that sync and used to schedule a second
            // full account-status + pull cycle on every cold launch.
            self.startWsSync()
            // Foreground sync is socket-driven: NO periodic network poll while the
            // socket is up. The 1 s tick is a cheap LOCAL flag read — a network sync
            // fires only when a peer's push arrives as a `changed` nudge (or a
            // reconnect flags a catch-up). The only poll left is a slow fallback
            // that runs ONLY when the socket is actually down (e.g. a network that
            // blocks WS), so such a device still converges.
            var secondsSinceFallbackPoll = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    // Cancellation is the normal shutdown path (sign-out or
                    // replacement by a newly installed session). Never run a
                    // stale poll after the task has been cancelled.
                    return
                }
                guard !Task.isCancelled else { return }
                if await self.wsPendingChanged() {
                    secondsSinceFallbackPoll = 0
                    await self.syncOnce()
                    continue
                }
                secondsSinceFallbackPoll += 1
                if secondsSinceFallbackPoll >= 30 {
                    secondsSinceFallbackPoll = 0
                    // Connected → rely entirely on the socket; only poll if it's down.
                    if await self.isWsConnected() == false {
                        await self.syncOnce()
                    }
                }
            }
        }
    }
#else
    // Accounts/sync disabled: no-op stubs preserving signatures for shared callers.
    func startWsSync() {}
    func stopWsSync() {}
    func wsPendingChanged() async -> Bool { false }
    func isWsConnected() async -> Bool { false }
    func startSyncPolling() {}
#endif

    func configureGoogleSyncPolling(accountCount: Int32) {
        if accountCount <= 0 {
            googleSyncTask?.cancel()
            googleSyncTask = nil
            return
        }
        guard googleSyncTask == nil else { return }
        googleSyncTask = Task { [weak self] in
            guard let self else { return }
            await self.syncGoogleCalendars(silent: true)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.foregroundGoogleSyncIntervalNanos)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.syncGoogleCalendars(silent: true)
            }
        }
    }

    func runBackgroundGoogleCalendarSyncIfDue() async -> Bool {
        guard snapshot?.settings.googleAccountCount ?? 0 > 0 else { return false }
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: backgroundGoogleSyncKey) as? Date,
           Date().timeIntervalSince(last) < Self.backgroundGoogleSyncInterval {
            return false
        }
        defaults.set(Date(), forKey: backgroundGoogleSyncKey)
        return await syncGoogleCalendars(silent: true)
    }

    func saveSyncSession(_ session: LocalSyncSession) {
        guard let data = try? JSONEncoder().encode(session) else {
            errorMessage = "Could not save your sync session securely."
            return
        }
        guard SyncSessionStore.save(data, key: syncSessionKey) else {
            // Do not put a freshly issued access/refresh token back into
            // UserDefaults when the protected store is unavailable. The current
            // in-memory session remains usable and the error is actionable.
            errorMessage = "Could not save your sync session securely."
            return
        }
        // Remove the pre-Keychain copy only after the protected write succeeds.
        UserDefaults.standard.removeObject(forKey: syncSessionKey)
    }

    static func loadSyncSession(key: String) -> LocalSyncSession? {
        if let data = SyncSessionStore.load(key: key),
           let session = try? JSONDecoder().decode(LocalSyncSession.self, from: data),
           Self.isSecureSyncApiBase(session.apiBase) {
            return session
        }

        // One-time migration for builds that stored credentials in the plist.
        // Keep the legacy value if Keychain is temporarily unavailable so an
        // existing user is not signed out or forced through auth again.
        guard let legacyData = UserDefaults.standard.data(forKey: key),
              let session = try? JSONDecoder().decode(LocalSyncSession.self, from: legacyData),
              Self.isSecureSyncApiBase(session.apiBase) else {
            return nil
        }
        if SyncSessionStore.save(legacyData, key: key) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        return session
    }
}
