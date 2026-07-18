import AuthenticationServices
import CryptoKit
import Foundation
import StoreKit
import SwiftUI
import UIKit

// Entire sign-in / StoreKit / account / subscription surface. Compiled out when
// the `accounts` flag is off (shipped builds); every caller is gated to match.
#if ACCOUNTS_ENABLED
extension AppModel {
    /// Start a browser-based sign-in (or account creation): open the hosted sign-in
    /// page with a custom-scheme redirect + PKCE, then exchange the returned
    /// one-time code for a session. No password is ever entered in — or stored by —
    /// the app.
    func beginBrowserSignIn(mode: SyncAuthMode) async {
        guard !syncAuthInProgress else { return }
        let apiBase = normalizedApiBase(syncSession?.apiBase ?? Self.defaultSyncApiBase)
        let state = Self.randomURLToken(24)
        // PKCE: the verifier never leaves the device; only its challenge rides the
        // URL, so an intercepted code is useless without this app.
        let verifier = Self.pkceVerifier()
        let challenge = Self.pkceChallenge(verifier)
        guard let authURL = Self.signInAuthorizeURL(
            apiBase: apiBase,
            mode: mode,
            state: state,
            codeChallenge: challenge,
            redirectURI: Self.signInRedirectURI
        ) else {
            errorMessage = "Could not start sign-in."
            return
        }

        syncAuthInProgress = true
        defer {
            syncAuthInProgress = false
            browserSignInSession = nil
        }

        do {
            let session = WebAuthenticationSessionCoordinator()
            browserSignInSession = session
            let callbackURL = try await session.authenticate(
                url: authURL,
                callbackScheme: Self.signInRedirectScheme
            )
            let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard items.first(where: { $0.name == "state" })?.value == state else {
                throw SyncAuthError.message("Sign-in could not be verified. Please try again.")
            }
            guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                throw SyncAuthError.message("Sign-in did not complete.")
            }
            let payload = try await exchangeAuthorizeCode(apiBase: apiBase, code: code, codeVerifier: verifier)
            installSyncSession(payload, apiBase: apiBase)
            errorMessage = nil
            // Pull verification + subscription state so the Sync card reflects whether
            // the just-signed-in account can subscribe yet.
            await refreshAccountStatus()
            scheduleSync()
        } catch {
            if Self.isWebAuthCancellation(error) {
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    /// Redeem the one-time authorization code (with the PKCE verifier) for a session.
    func exchangeAuthorizeCode(
        apiBase: String,
        code: String,
        codeVerifier: String
    ) async throws -> SyncLoginResponse {
        guard let url = URL(string: "\(apiBase)/v1/auth/authorize/exchange") else {
            throw SyncAuthError.message("Enter a sync API URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code,
            "code_verifier": codeVerifier
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncAuthError.message("Sync backend returned an invalid response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw SyncAuthError.message(Self.authorizeErrorMessage(body?["code"] as? String))
        }
        return try JSONDecoder().decode(SyncLoginResponse.self, from: data)
    }

    static func signInAuthorizeURL(
        apiBase: String,
        mode: SyncAuthMode,
        state: String,
        codeChallenge: String,
        redirectURI: String
    ) -> URL? {
        var components = URLComponents(string: "\(webBase(forApiBase: apiBase))/signin.html")
        components?.queryItems = [
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "mode", value: mode == .createAccount ? "create" : "signin"),
            URLQueryItem(name: "api", value: apiBase),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components?.url
    }

    static func pkceVerifier() -> String {
        base64URLNoPad(randomData(32))
    }

    static func pkceChallenge(_ verifier: String) -> String {
        base64URLNoPad(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomURLToken(_ byteCount: Int) -> String {
        base64URLNoPad(randomData(byteCount))
    }

    static func randomData(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) })
    }

    static func base64URLNoPad(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func installSyncSession(_ payload: SyncLoginResponse, apiBase: String) {
        let session = LocalSyncSession(
            apiBase: apiBase,
            userId: payload.userId,
            email: payload.email,
            supportsSync: payload.supportsSync,
            bearerToken: payload.bearerToken,
            expiresAt: payload.expiresAt,
            refreshToken: payload.refreshToken,
            refreshExpiresAt: payload.refreshExpiresAt
        )
        syncSession = session
        syncOffline = false
        saveSyncSession(session)
        startSyncPolling()
        BackgroundSyncCoordinator.shared.scheduleIfEligible(backgroundRefreshEligible)
    }

    func signOutSync() {
        syncSession = nil
        syncOffline = false
        subscriptionCancelled = false
        subscriptionProvider = nil
        pendingDeletionChallengeId = nil
        emailVerified = nil
        resendCooldownTask?.cancel()
        resendCooldownTask = nil
        resendVerificationCooldown = 0
        resendVerificationInProgress = false
        syncPollTask?.cancel()
        syncPollTask = nil
        stopWsSync()
        BackgroundSyncCoordinator.shared.scheduleIfEligible(backgroundRefreshEligible)
        UserDefaults.standard.removeObject(forKey: syncSessionKey)
    }

    /// Open Apple's Manage Subscriptions sheet. An auto-renewable subscription
    /// bought through the App Store can only be cancelled there — neither the app
    /// nor our backend is allowed to cancel it — so this is where an iOS user goes.
    func openManageAppleSubscription() async {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene else {
            errorMessage = "Open Settings → Apple Account → Subscriptions to manage your subscription."
            return
        }
        do {
            try await AppStore.showManageSubscriptions(in: scene)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Turn off the sync entitlement for this account while keeping the account and
    /// the local workspace intact (the in-app "cancel subscription" action). The
    /// backend rotates the session, so we install the credentials it returns.
    func cancelSyncSubscription() async {
        guard syncSession != nil, !syncInProgress else { return }
        syncAccountActionInProgress = true
        syncInProgress = true
        defer {
            syncInProgress = false
            syncAccountActionInProgress = false
        }
        // Use a fresh access token; deferred refresh keeps the account signed in.
        guard await refreshSyncSessionForAccountAction(),
              let session = syncSession,
              let url = URL(string: "\(session.apiBase)/v1/auth/subscription/cancel") else {
            return
        }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(session.bearerToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [:] as [String: Any])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SyncAuthError.message("Sync backend returned an invalid response.")
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let code = body?["code"] as? String
                // App Store / Play Store subscriptions can't be cancelled
                // server-side; send the user to Apple's manage-subscriptions
                // sheet, which is where the cancel actually happens on iOS.
                if code == "cancel_in_app_store" {
                    await openManageAppleSubscription()
                    return
                }
                throw SyncAuthError.message(Self.accountActionErrorMessage(code))
            }
            let payload = try JSONDecoder().decode(SyncLoginResponse.self, from: data)
            installSyncSession(payload, apiBase: session.apiBase)
            if syncSession?.supportsSync == true {
                errorMessage = "Your subscription has been cancelled. Sync remains available until the current billing period ends."
            } else {
                errorMessage = "Sync has been turned off for this account. Your local workspace stays on this device, and you can sign in again later to re-enable sync."
            }
            await refreshAccountStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Schedule deletion of the sync account and cloud data from inside the app.
    /// Local workspace files stay on device; the backend revokes all sessions after
    /// accepting the deletion request, so the app signs out immediately.
    /// Step 1 of 2: re-authenticate with email + current password. On success the
    /// backend emails a one-time code and we surface the OTP entry step; nothing is
    /// scheduled until `confirmSyncAccountDeletion(code:)` completes.
    func requestSyncAccountDeletion(confirmEmail: String, password: String) async {
        guard syncSession != nil, !syncInProgress else { return }
        syncAccountActionInProgress = true
        syncInProgress = true
        defer {
            syncInProgress = false
            syncAccountActionInProgress = false
        }
        guard await refreshSyncSessionForAccountAction(),
              let session = syncSession,
              let url = URL(string: "\(session.apiBase)/v1/auth/account") else {
            return
        }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(session.bearerToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "confirm_email": confirmEmail.trimmingCharacters(in: .whitespacesAndNewlines),
                "password": password,
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SyncAuthError.message("Sync backend returned an invalid response.")
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let code = body?["code"] as? String
                throw SyncAuthError.message(Self.accountActionErrorMessage(code))
            }
            let challenge = try JSONDecoder().decode(ChallengeResponse.self, from: data)
            pendingDeletionChallengeId = challenge.challengeId
            errorMessage = "We emailed you a code. Enter it to confirm deleting your account."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Step 2 of 2: submit the emailed one-time code to schedule deletion. On success
    /// the account is scheduled for purge after the grace period and we sign out.
    func confirmSyncAccountDeletion(code: String) async {
        guard let challengeId = pendingDeletionChallengeId, !syncInProgress else { return }
        syncAccountActionInProgress = true
        syncInProgress = true
        defer {
            syncInProgress = false
            syncAccountActionInProgress = false
        }
        guard await refreshSyncSessionForAccountAction(),
              let session = syncSession,
              let url = URL(string: "\(session.apiBase)/v1/auth/account/delete/verify") else {
            return
        }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(session.bearerToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "challenge_id": challengeId,
                "code": code.trimmingCharacters(in: .whitespacesAndNewlines),
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SyncAuthError.message("Sync backend returned an invalid response.")
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let code = body?["code"] as? String
                throw SyncAuthError.message(Self.accountActionErrorMessage(code))
            }
            _ = try? JSONDecoder().decode(DeleteAccountResponse.self, from: data)
            pendingDeletionChallengeId = nil
            signOutSync()
            errorMessage = "Your account is scheduled for deletion. Sign in again within 14 days to cancel. Your local workspace stays on this device."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Undo a pending cancellation so the subscription renews again. Web
    /// subscriptions un-cancel through our backend; Apple/Google renewals can only be
    /// turned back on in their stores, so for those we open the store's
    /// manage-subscriptions screen. On iOS the subscription is normally a StoreKit
    /// (Apple) one, so an unknown provider routes to the App Store.
    func reEnableSyncSubscription() async {
        let provider = (subscriptionProvider ?? "").lowercased()
        if provider == "google" {
            openManagePlaySubscription()
            return
        }
        if provider != "web" {
            await openManageAppleSubscription()
            return
        }
        guard syncSession != nil, !syncInProgress else { return }
        syncAccountActionInProgress = true
        syncInProgress = true
        defer {
            syncInProgress = false
            syncAccountActionInProgress = false
        }
        guard await refreshSyncSessionForAccountAction(),
              let session = syncSession,
              let url = URL(string: "\(session.apiBase)/v1/auth/subscription/resume") else {
            return
        }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(session.bearerToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [:] as [String: Any])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SyncAuthError.message("Sync backend returned an invalid response.")
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let code = body?["code"] as? String
                if code == "resume_in_app_store" {
                    await openManageAppleSubscription()
                    return
                }
                if code == "resume_in_play_store" {
                    openManagePlaySubscription()
                    return
                }
                throw SyncAuthError.message(Self.accountActionErrorMessage(code))
            }
            let payload = try JSONDecoder().decode(SyncLoginResponse.self, from: data)
            installSyncSession(payload, apiBase: session.apiBase)
            errorMessage = "Your subscription will renew again."
            await refreshAccountStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Open Google Play's manage-subscriptions page (for the rare case an account's
    /// sync subscription is a Play one being managed from an iOS device).
    func openManagePlaySubscription() {
        guard let url = URL(string: "https://play.google.com/store/account/subscriptions") else { return }
        UIApplication.shared.open(url)
    }

    /// Read the authoritative subscription lifecycle from the backend so Settings can
    /// reflect a cancelled-but-active subscription and offer to re-enable it.
    func refreshAccountStatus() async {
        guard let session = syncSession,
              let url = URL(string: "\(session.apiBase)/v1/auth/account/status") else {
            subscriptionCancelled = false
            subscriptionProvider = nil
            emailVerified = nil
            syncOffline = false
            return
        }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(session.bearerToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return
            }
            let status = try JSONDecoder().decode(AccountStatusPayload.self, from: data)
            syncOffline = false
            subscriptionProvider = status.subscriptionProvider
            emailVerified = status.emailVerified
            subscriptionCancelled =
                status.supportsSync && (status.subscriptionState?.lowercased() == "cancelled")
        } catch {
            // Leave the last known state; the user can retry from Settings.
            if Self.isLikelyNetworkError(error) {
                syncOffline = true
            }
        }
    }

    /// Resend the email-verification link to the signed-in account. Soft-rate-limited
    /// on the client with a 60s cooldown (the backend rate-limits too). Surfaces the
    /// outcome in `errorMessage`.
    func resendVerificationEmail() async {
        guard let session = syncSession,
              !resendVerificationInProgress,
              resendVerificationCooldown == 0,
              let url = URL(string: "\(session.apiBase)/v1/auth/email/verify/resend") else {
            return
        }
        resendVerificationInProgress = true
        defer { resendVerificationInProgress = false }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(session.bearerToken)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SyncAuthError.message("Could not reach the sync service.")
            }
            if http.statusCode == 429 {
                throw SyncAuthError.message("You've requested this recently — wait a minute, then try again.")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw SyncAuthError.message("Could not resend the verification email.")
            }
            errorMessage = "Verification email sent. Check your inbox, then reopen Settings."
            startResendCooldown()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startResendCooldown(_ seconds: Int = 60) {
        resendCooldownTask?.cancel()
        resendVerificationCooldown = seconds
        // Created in a @MainActor context, so this Task runs on the main actor and can
        // touch `resendVerificationCooldown` directly.
        resendCooldownTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled, self.resendVerificationCooldown > 0 else { return }
                self.resendVerificationCooldown -= 1
            }
        }
    }

    /// Re-check the sync entitlement and subscription lifecycle from the backend.
    /// Called when the app is (re)opened so a subscription bought (or changed) while
    /// it was closed — the common "subscribe, reopen the app, see it" flow — shows up
    /// without waiting for the access token to expire. The forced refresh runs first
    /// and rotates the session; the status read then uses the fresh token, so the two
    /// never replay the single-use refresh token concurrently.
    func refreshSubscriptionStatus() async {
        guard syncSession != nil else { return }
        // Pick up an entitlement change first; this rotates the session so the status
        // read below uses the fresh token. Run it best-effort: even when the forced
        // refresh defers on a transient hiccup (which marks `syncOffline`), still read
        // the authoritative account status so a reachable backend clears the stale flag
        // instead of leaving the card stuck on "Offline" after sign-in. The status read
        // is a bearer-token GET, so it never replays the single-use refresh token.
        await refreshEntitlement()
        await refreshAccountStatus()
    }

    // MARK: - Subscriptions (StoreKit)

    func startTransactionListener() {
        transactionListener = Task { [weak self] in
            // StoreKit.Transaction, disambiguated from SwiftUI.Transaction.
            for await update in StoreKit.Transaction.updates {
                guard let self else { return }
                await self.handle(transactionResult: update)
            }
        }
    }

    /// Load the subscription products from the App Store. If the product ids aren't
    /// configured in App Store Connect yet, this just yields an empty list.
    func loadSyncProducts() async {
        do {
            let products = try await Product.products(for: Self.syncProductIDs)
            syncProducts = products.sorted { $0.price < $1.price }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Buy a sync subscription. The purchase carries appAccountToken = our account
    /// id, so Apple's server notification maps the subscription back to this
    /// account; entitlement is granted server-side and picked up on refresh.
    func purchaseSync(_ product: Product) async {
        guard let session = syncSession, !purchaseInProgress else { return }
        // Subscribing is gated on a confirmed email (the backend rejects the verify
        // call otherwise); stop here with a clear prompt rather than start a StoreKit
        // purchase the account can't redeem.
        if emailVerified == false {
            errorMessage = "Verify your email before subscribing — check your inbox for the link."
            return
        }
        purchaseInProgress = true
        defer { purchaseInProgress = false }
        do {
            var options: Set<Product.PurchaseOption> = []
            if let token = UUID(uuidString: session.userId) {
                options.insert(.appAccountToken(token))
            }
            let result = try await product.purchase(options: options)
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    errorMessage = "Could not verify the purchase. Please try again."
                    return
                }
                await transaction.finish()
                // Verify with the backend for an immediate grant (jwsRepresentation is
                // the signed transaction the server re-verifies); falls back to the
                // notification-driven refresh on any failure.
                await verifyApplePurchase(jws: verification.jwsRepresentation)
            case .userCancelled:
                break
            case .pending:
                errorMessage = "Your purchase is pending approval."
            @unknown default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Restore an existing subscription tied to the App Store account. Required by
    /// the App Store for any app offering subscription purchases.
    func restorePurchases() async {
        guard !purchaseInProgress else { return }
        purchaseInProgress = true
        defer { purchaseInProgress = false }
        do {
            try await AppStore.sync()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        // Verify any current subscription entitlement with the backend for an
        // immediate grant; fall back to the notification-driven refresh otherwise.
        for await entitlement in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement, transaction.productType == .autoRenewable {
                await verifyApplePurchase(jws: entitlement.jwsRepresentation)
                return
            }
        }
        await refreshEntitlement()
    }

    func handle(transactionResult: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let transaction) = transactionResult else { return }
        await transaction.finish()
        await refreshEntitlement()
    }

    /// Force a session refresh so a server-side entitlement change (granted by a
    /// billing webhook) is reflected locally. Guarded by syncInProgress so it can't
    /// race the poll loop into replaying the single-use refresh token.
    @discardableResult
    func refreshEntitlement() async -> Bool {
        guard !syncInProgress, syncSession != nil else { return false }
        syncInProgress = true
        var shouldScheduleSync = false
        defer {
            syncInProgress = false
            if shouldScheduleSync {
                scheduleSync()
            }
        }
        let result = await refreshSyncSessionIfNeeded(force: true)
        if result == .ready, syncSession?.supportsSync == true {
            shouldScheduleSync = true
        }
        return result == .ready
    }

    /// Verify a just-completed StoreKit purchase with the backend so the sync
    /// entitlement is granted *immediately* (and the session updated), instead of
    /// waiting on Apple's asynchronous App Store Server Notification. Shares the
    /// syncInProgress guard with the refresh path: the verify response rotates the
    /// session (a fresh refresh token), so it must not race the poll loop.
    func verifyApplePurchase(jws: String) async {
        guard !syncInProgress,
              let session = syncSession,
              let url = URL(string: "\(session.apiBase)/v1/billing/apple/verify") else {
            await refreshEntitlement()
            return
        }
        syncInProgress = true
        defer { syncInProgress = false }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(session.bearerToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["signed_transaction": jws])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return
            }
            let payload = try JSONDecoder().decode(SyncLoginResponse.self, from: data)
            installRefreshedSession(payload, from: session)
        } catch {
            // Fall back to the notification-driven path; the grant still arrives on
            // the next refresh once Apple's server notification lands.
        }
    }

    /// Apply a refreshed/verified session payload: persist it, reschedule background
    /// sync, and kick a sync if now entitled.
    func installRefreshedSession(_ payload: SyncLoginResponse, from session: LocalSyncSession) {
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
        if updated.supportsSync {
            scheduleSync()
        }
    }
}
#endif
