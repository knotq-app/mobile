import AuthenticationServices
import CryptoKit
import Foundation
import StoreKit
import SwiftUI
import UIKit

extension AppModel {
    /// Hand the Rust core a push token (e.g. an FCM token from Firebase) so the
    /// next sync registers this device for silent background wake-ups.
    func setPushToken(_ token: String, environment: String = "production") {
        guard let bridge else { return }
        bridge.enqueue({ try $0.setPushRegistration(token: token, environment: environment) }) { [weak self] result in
            guard let self, case .success = result else { return }
            if self.syncSession?.supportsSync == true {
                Task { await self.runBackgroundSync() }
            }
        }
    }

    /// One-shot sync used by background app refresh and silent pushes. Guarded so it
    /// can't race the foreground poll; returns whether remote changes were applied.
    @discardableResult
    func runBackgroundSync() async -> Bool {
        guard !syncInProgress, let session = syncSession, session.supportsSync else { return false }
        syncInProgress = true
        defer { syncInProgress = false }
        guard await refreshSyncSessionIfNeeded() == .ready, let bridge, let current = syncSession else {
            return false
        }
        do {
            let apiBase = current.apiBase
            let bearerToken = current.bearerToken
            let result = try await bridge.perform { b in
                let changed = try b.syncOnce(apiBase: apiBase, bearerToken: bearerToken)
                let notice = try b.takeSyncNotice()
                return (changed, notice)
            }
            if result.0 {
                refresh()
            }
            if let notice = result.1 {
                errorMessage = notice
            }
            syncOffline = false
            return result.0
        } catch {
            if Self.isLikelyNetworkError(error) {
                syncOffline = true
            }
            return false
        }
    }

    /// One-shot background maintenance used by BGAppRefreshTask. Cloud sync runs
    /// whenever eligible; Google Calendar sync is throttled separately because it
    /// can fan out into several Google API calls.
    @discardableResult
    func runBackgroundMaintenance() async -> Bool {
        let remoteChanged = await runBackgroundSync()
        let googleSynced = await runBackgroundGoogleCalendarSyncIfDue()
        // Refresh the badge before the task finishes (and the app may suspend)
        // so the overdue count stays current even when nothing synced.
        await refreshOverdueBadge()
        return remoteChanged || googleSynced
    }

    func syncOnce() async {
        // Set the in-progress guard before refreshing so concurrent callers bail
        // out — two simultaneous refreshes would replay the same (single-use)
        // refresh token and trip the server's reuse detection, revoking the session.
        guard !syncInProgress, syncSession != nil else { return }
        syncInProgress = true
        defer { syncInProgress = false }

        // Refresh the short-lived access token if it's near expiry (persisting the
        // rotated credentials), or bail out if the session is gone.
        guard await refreshSyncSessionIfNeeded() == .ready else { return }

        guard let bridge, let session = syncSession, session.supportsSync else { return }
        do {
            let apiBase = session.apiBase
            let bearerToken = session.bearerToken
            let result = try await bridge.perform { b in
                let changed = try b.syncOnce(apiBase: apiBase, bearerToken: bearerToken)
                let notice = try b.takeSyncNotice()
                return (changed, notice)
            }
            if result.0 {
                refresh()
            }
            syncOffline = false
            errorMessage = result.1
        } catch {
            if Self.isLikelyNetworkError(error) {
                syncOffline = true
                errorMessage = nil
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    func scheduleSync() {
        guard syncSession != nil else { return }
        Task { await self.syncOnce() }
    }

    /// Push that follows a local edit, debounced so a burst of edits coalesces
    /// into one sync instead of pushing on every mutation. Leading-window like
    /// desktop: the first edit of a burst arms the timer and later edits don't
    /// postpone it. The 30 s foreground poll backstops a continuous edit, and
    /// `flushPendingEditSync()` pushes before the app suspends.
    func scheduleEditSync() {
        guard syncSession != nil, pendingEditSyncTask == nil else { return }
        pendingEditSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.editSyncDebounceNanos)
            guard let self, !Task.isCancelled else { return }
            self.pendingEditSyncTask = nil
            await self.syncOnce()
        }
    }

    /// Flush a debounced edit immediately, wrapped in a background assertion so a
    /// push armed just before the app suspends isn't stranded until the next
    /// BGAppRefreshTask (~3 h) or foreground. No-op when no edit is pending.
    func flushPendingEditSync() {
        guard pendingEditSyncTask != nil else { return }
        pendingEditSyncTask?.cancel()
        pendingEditSyncTask = nil
        Task { [weak self] in
            guard let self else { return }
            _ = await self.withBackgroundAssertion("knotq.flush-edit-sync") {
                await self.runBackgroundSync()
            }
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
    func refreshSyncSessionIfNeeded(force: Bool = false) async -> SyncSessionRefreshResult {
        guard let session = syncSession else { return .sessionDead }
        guard !session.refreshToken.isEmpty else {
            syncOffline = true
            return .deferred
        }
        guard (force || Self.tokenNeedsRefresh(session.expiresAt)),
              let url = URL(string: "\(session.apiBase)/v1/auth/refresh")
        else {
            return .ready
        }
        do {
            var request = URLRequest(url: url)
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
                try await URLSession.shared.data(for: request)
            }
            guard let http = response as? HTTPURLResponse else {
                syncOffline = true
                return .deferred
            }
            if Self.isTerminalRefreshError(data) {
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
    static func tokenNeedsRefresh(_ expiresAt: String) -> Bool {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let expiry = withFraction.date(from: expiresAt) ?? plain.date(from: expiresAt) else {
            return true
        }
        return expiry.timeIntervalSinceNow <= 120
    }

    static func isLikelyNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return true
        }
        let message = error.localizedDescription.lowercased()
        return ["network", "request failed", "offline", "timed out", "cannot connect", "not connected"].contains { message.contains($0) }
    }

    static func isTerminalRefreshError(_ data: Data) -> Bool {
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
    func mutate(_ action: @escaping @Sendable (RustBridge) throws -> Void) {
        guard let bridge else { return }
        let today = Self.dateOnly(selectedDate)
        let week = weekOffset
        let history = dailyHistoryDays
        bridge.enqueue({ b in
            try action(b)
            return (
                try b.snapshot(today: today, weekOffset: week, dailyHistoryDays: history),
                try b.pendingNotifications(),
                try b.deliveredNotificationsToClear()
            )
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let (snapshot, pending, staleNotificationIds)):
                self.apply(
                    snapshot: snapshot,
                    pendingNotifications: pending,
                    staleNotificationIds: staleNotificationIds
                )
                self.errorMessage = nil
                if self.syncSession != nil {
                    self.scheduleEditSync()
                }
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
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
        // Online, poll-free sync: pull/push ride a persistent socket.
        startWsSync()
        syncPollTask = Task { [weak self] in
            // Pick up an entitlement change (a subscription bought on another device
            // or the web) on launch/sign-in before the first sync, so it shows up
            // without waiting for the access token to expire.
            await self?.refreshSubscriptionStatus()
            await self?.syncOnce()
            // Foreground sync is socket-driven: NO periodic network poll while the
            // socket is up. The 1 s tick is a cheap LOCAL flag read — a network sync
            // fires only when a peer's push arrives as a `changed` nudge (or a
            // reconnect flags a catch-up). The only poll left is a slow fallback
            // that runs ONLY when the socket is actually down (e.g. a network that
            // blocks WS), so such a device still converges.
            var secondsSinceFallbackPoll = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { break }
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

    func configureGoogleSyncPolling(accountCount: Int32) {
        if accountCount <= 0 {
            googleSyncTask?.cancel()
            googleSyncTask = nil
            return
        }
        guard googleSyncTask == nil else { return }
        googleSyncTask = Task { [weak self] in
            await self?.syncGoogleCalendars(silent: true)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.foregroundGoogleSyncIntervalNanos)
                await self?.syncGoogleCalendars(silent: true)
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
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: syncSessionKey)
        }
    }

    static func loadSyncSession(key: String) -> LocalSyncSession? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LocalSyncSession.self, from: data)
    }
}
