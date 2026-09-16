import AuthenticationServices
import CryptoKit
import Foundation
import StoreKit
import SwiftUI
import UIKit

// Account and sign-in support is compiled out when `accounts` is off. StoreKit
// controls are separately gated by `IN_APP_PURCHASES_ENABLED` in the UI so an
// interim accounts-only build can safely ship before IAP approval.
#if ACCOUNTS_ENABLED
extension AppModel {
    /// Start a browser-based sign-in (or account creation): open the hosted sign-in
    /// page with a custom-scheme redirect + PKCE, then exchange the returned
    /// one-time code for a session. No password is ever entered in — or stored by —
    /// the app.
    func beginBrowserSignIn(mode: SyncAuthMode) async {
        guard !syncAuthInProgress else { return }
        let apiBase = normalizedApiBase(syncSession?.apiBase ?? Self.defaultSyncApiBase)
        guard !apiBase.isEmpty else {
            errorMessage = L10n.t("sync.error.api_url_https_required")
            return
        }
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
        let (data, http) = try await MobileHTTPResponseLimits.data(for: request)
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
        guard Self.isSecureSyncApiBase(apiBase) else {
            errorMessage = L10n.t("sync.error.api_url_https_required")
            return
        }
        syncSessionRefreshTask?.cancel()
        syncSessionRefreshTask = nil
        syncSessionGeneration.advance()
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
        syncSessionGeneration.advance()
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
        syncSessionRefreshTask?.cancel()
        syncSessionRefreshTask = nil
        syncPollTask?.cancel()
        syncPollTask = nil
        stopWsSync()
        BackgroundSyncCoordinator.shared.scheduleIfEligible(backgroundRefreshEligible)
        SyncSessionStore.remove(key: syncSessionKey)
        // Also clear the legacy location left by versions before Keychain
        // storage, including sessions that could not be migrated while locked.
        UserDefaults.standard.removeObject(forKey: syncSessionKey)
    }

    /// Open Apple's Manage Subscriptions sheet. If the system sheet cannot be
    /// presented, fall back to Apple's subscriptions URL and finally explain the
    /// Settings path so the user always has a way to manage the subscription.
    func openManageAppleSubscription() async {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene else {
            if !(await openAppleSubscriptionsURL()) {
                errorMessage = L10n.t("sync.error.manage_in_app_store")
            }
            return
        }
        do {
            try await AppStore.showManageSubscriptions(in: scene)
        } catch {
            if !(await openAppleSubscriptionsURL()) {
                errorMessage = L10n.t("sync.error.manage_in_app_store")
            }
        }
    }

    private func openAppleSubscriptionsURL() async -> Bool {
        guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            UIApplication.shared.open(url, options: [:]) { success in
                continuation.resume(returning: success)
            }
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
            let (data, http) = try await MobileHTTPResponseLimits.data(for: request)
            guard (200..<300).contains(http.statusCode) else {
                let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let code = body?["code"] as? String
                // App Store / Play Store subscriptions can't be cancelled
                // server-side; send the user to Apple's manage-subscriptions
                // sheet, which is where the cancel actually happens on iOS.
                if code == "cancel_in_app_store" {
                    await openManageAppleSubscription()
                    // The user may have cancelled in Apple's sheet; re-read the
                    // authoritative lifecycle before returning to Settings.
                    await refreshSubscriptionStatus()
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
            let (data, http) = try await MobileHTTPResponseLimits.data(for: request)
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
            let (data, http) = try await MobileHTTPResponseLimits.data(for: request)
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
            await openManagePlaySubscription()
            await refreshSubscriptionStatus()
            return
        }
        if provider != "web" {
            await openManageAppleSubscription()
            await refreshSubscriptionStatus()
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
            let (data, http) = try await MobileHTTPResponseLimits.data(for: request)
            guard (200..<300).contains(http.statusCode) else {
                let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let code = body?["code"] as? String
                if code == "resume_in_app_store" {
                    await openManageAppleSubscription()
                    await refreshSubscriptionStatus()
                    return
                }
                if code == "resume_in_play_store" {
                    await openManagePlaySubscription()
                    await refreshSubscriptionStatus()
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
    func openManagePlaySubscription() async {
        guard let url = URL(string: "https://play.google.com/store/account/subscriptions") else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            UIApplication.shared.open(url, options: [:]) { _ in
                continuation.resume()
            }
        }
    }

    /// Read the authoritative subscription lifecycle from the backend so Settings can
    /// reflect a cancelled-but-active subscription and offer to re-enable it.
    func refreshAccountStatus(allowAuthRefresh: Bool = true) async {
        guard let session = syncSession,
              let url = URL(string: "\(session.apiBase)/v1/auth/account/status") else {
            subscriptionCancelled = false
            subscriptionProvider = nil
            emailVerified = nil
            syncOffline = false
            return
        }
        let sessionGeneration = syncSessionGeneration.value
        do {
            var request = URLRequest(url: url)
            // Account status is auxiliary metadata; it must not hold startup or
            // settings indefinitely when the backend is slow.
            request.timeoutInterval = 5
            request.httpMethod = "GET"
            request.setValue("Bearer \(session.bearerToken)", forHTTPHeaderField: "Authorization")
            let (data, http) = try await MobileHTTPResponseLimits.data(for: request)
            guard (200..<300).contains(http.statusCode) else {
                // Entitlement changes invalidate the supports_sync claim embedded
                // in the access token. In particular, a token minted before an
                // Apple purchase has supportsSync=false, while the account now
                // has a paid grant; the backend correctly answers 401 until the
                // long-lived refresh token mints a token with the new claim.
                // Retry once with that rotated session so the Settings card does
                // not remain stuck on the old cached entitlement.
                if http.statusCode == 401, allowAuthRefresh {
                    if await refreshSyncSessionIfNeeded(force: true) == .ready {
                        await refreshAccountStatus(allowAuthRefresh: false)
                    }
                }
                return
            }
            let status = try JSONDecoder().decode(AccountStatusPayload.self, from: data)
            // A status response for a signed-out or replaced session must not
            // repopulate the subscription card for the next account.
            guard syncSessionGeneration.matches(sessionGeneration) else { return }
            syncOffline = false
            subscriptionProvider = status.subscriptionProvider
            emailVerified = status.emailVerified
            subscriptionCancelled =
                status.supportsSync && (status.subscriptionState?.lowercased() == "cancelled")
            // Status is the authoritative entitlement snapshot. Keep the cached
            // session aligned so a grant/revocation is reflected before the Rust
            // sync guard runs, without requiring a forced refresh-token rotation.
            if var session = syncSession, session.supportsSync != status.supportsSync {
                session.supportsSync = status.supportsSync
                syncSession = session
                saveSyncSession(session)
            }
        } catch {
            // Leave the last known state; the user can retry from Settings.
            guard syncSessionGeneration.matches(sessionGeneration) else { return }
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
            let (_, http) = try await MobileHTTPResponseLimits.data(for: request)
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
    /// without waiting for the access token to expire. The access token is refreshed
    /// only when needed; the status read itself is authoritative for the entitlement.
    func refreshSubscriptionStatus() async {
        guard syncSession != nil else { return }
        // Refresh only when the access token actually needs it. Forcing a rotating
        // refresh-token request on every launch added a network round-trip before the
        // real sync, and `refreshEntitlement()` also schedules a sync as a side effect.
        // The account-status response below is authoritative for supportsSync, so it
        // still picks up a subscription bought on another device without paying that
        // latency on every startup.
        _ = await refreshSyncSessionIfNeeded()
        await refreshAccountStatus()
    }

    // MARK: - Subscriptions (StoreKit)

    // StoreKit is separately gated from the accounts build so an accounts-only
    // binary can still ship while the subscription product is awaiting approval.
    // The App Store build enables `IN_APP_PURCHASES_ENABLED` in the Xcode target.
    #if IN_APP_PURCHASES_ENABLED
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
            let sortedProducts = products.sorted { $0.price < $1.price }
            syncProducts = sortedProducts

            // Eligibility belongs to the current App Store account, not to the
            // KnotQ account. Only advertise the trial when StoreKit reports both
            // an offer on the product and eligibility for this purchaser.
            var eligibility: [String: Bool] = [:]
            for product in sortedProducts {
                guard let subscription = product.subscription else { continue }
                let hasIntroductoryOffer = subscription.introductoryOffer != nil
                let isEligible = await subscription.isEligibleForIntroOffer
                eligibility[product.id] = hasIntroductoryOffer && isEligible
            }
            syncIntroOfferEligible = eligibility
        } catch {
            syncProducts = []
            syncIntroOfferEligible = [:]
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
                // Always perform one final authoritative read after the purchase flow
                // completes. The verification response updates the local sync session,
                // while account/status supplies the provider and cancellation metadata
                // that drives the visible Settings card. Keeping this explicit here
                // ensures a successful tap cannot leave the UI showing the pre-purchase
                // state even if StoreKit's transaction listener ran concurrently.
                await refreshSubscriptionStatusUntilEntitled()
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
        // StoreKit can take a moment to publish the restored transaction after
        // AppStore.sync() returns. Re-query it over the same bounded propagation
        // window before falling back to the backend status path.
        let delays: [UInt64] = [0, 1, 2, 3, 5]
        for (index, delay) in delays.enumerated() {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
            for await entitlement in StoreKit.Transaction.currentEntitlements {
                if case .verified(let transaction) = entitlement, transaction.productType == .autoRenewable {
                    await verifyApplePurchase(jws: entitlement.jwsRepresentation)
                    await refreshSubscriptionStatusUntilEntitled()
                    return
                }
            }
            if syncSession?.supportsSync == true || index == delays.count - 1 { break }
        }
        // StoreKit may complete restore without yielding a current entitlement
        // immediately. Refresh the session once, then keep checking account/status
        // for the same propagation window instead of silently stopping here.
        _ = await refreshEntitlement()
        await refreshSubscriptionStatusUntilEntitled()
    }

    func handle(transactionResult: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let transaction) = transactionResult else { return }
        // A transaction update can be the first delivery after the app was
        // terminated during checkout. Verify it directly instead of waiting for
        // App Store Server Notifications to grant the backend entitlement.
        if transaction.productType == .autoRenewable {
            await verifyApplePurchase(jws: transactionResult.jwsRepresentation)
            await refreshSubscriptionStatusUntilEntitled()
        } else {
            await refreshEntitlement()
        }
        await transaction.finish()
    }
    #endif

    /// Force a session refresh so a server-side entitlement change (granted by a
    /// billing webhook) is reflected locally. Guarded by syncInProgress so it can't
    /// race the poll loop into replaying the single-use refresh token.
    @discardableResult
    func refreshEntitlement(scheduleSyncWhenReady: Bool = true) async -> Bool {
        guard !syncInProgress, syncSession != nil else { return false }
        syncInProgress = true
        var shouldScheduleSync = false
        defer {
            syncInProgress = false
            if scheduleSyncWhenReady && shouldScheduleSync {
                scheduleSync()
            }
        }
        let result = await refreshSyncSessionIfNeeded(force: true)
        if result == .ready, syncSession?.supportsSync == true {
            shouldScheduleSync = true
        }
        return result == .ready
    }

    #if IN_APP_PURCHASES_ENABLED
    /// Verify a just-completed StoreKit purchase with the backend so the sync
    /// entitlement is granted *immediately* (and the session updated), instead of
    /// waiting on Apple's asynchronous App Store Server Notification. Shares the
    /// syncInProgress guard with the refresh path: the verify response rotates the
    /// session (a fresh refresh token), so it must not race the poll loop.
    func verifyApplePurchase(jws: String) async {
        guard syncSession != nil else { return }
        // The transaction listener and the purchase button can observe the same
        // StoreKit transaction. Wait for a concurrent session rotation to finish
        // rather than treating the purchase as already handled and returning.
        guard await waitForSyncAuthToFinish() else {
            await refreshSubscriptionStatusUntilEntitled()
            return
        }
        guard let session = syncSession,
              let url = URL(string: "\(session.apiBase)/v1/billing/apple/verify") else { return }
        syncInProgress = true
        defer { syncInProgress = false }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(session.bearerToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["signed_transaction": jws])
            let (data, http) = try await MobileHTTPResponseLimits.data(for: request)
            guard (200..<300).contains(http.statusCode) else {
                // The entitlement may still arrive through Apple's notification
                // path. Show anything already recorded without waiting for relaunch.
                await refreshAccountStatus()
                return
            }
            let payload = try JSONDecoder().decode(SyncLoginResponse.self, from: data)
            installRefreshedSession(payload, from: session)
            // The verify response updates the entitlement bit; account status owns
            // provider/cancellation metadata used by the subscription card.
            await refreshAccountStatus()
        } catch {
            // Fall back to the notification-driven path; the grant still arrives on
            // the next refresh once Apple's server notification lands. Still attempt
            // the status read so an already-applied webhook is visible immediately.
            await refreshAccountStatus()
        }
    }

    /// StoreKit can finish before Apple's notification or the backend's billing
    /// write is visible to account/status. Retry for a short bounded window with
    /// increasing delays, stopping as soon as the local session becomes entitled.
    private func refreshSubscriptionStatusUntilEntitled() async {
        let delays: [UInt64] = [0, 1, 2, 3, 5]
        for (index, delay) in delays.enumerated() {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
            guard !Task.isCancelled, syncSession != nil else { return }
            await refreshSubscriptionStatus()
            if syncSession?.supportsSync == true || index == delays.count - 1 { return }
        }
    }

    /// Wait briefly for another sync-auth operation to finish rotating the
    /// single-use refresh token before verifying a purchase with the current
    /// bearer/session. This avoids a race between StoreKit's listener and the
    /// purchase button's own verification call.
    private func waitForSyncAuthToFinish() async -> Bool {
        for _ in 0..<50 {
            guard !Task.isCancelled else { return false }
            if !syncInProgress { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return !syncInProgress
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
    #endif
}
#endif
