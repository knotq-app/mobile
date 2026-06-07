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
    // True while a destructive account action (cancel subscription / delete
    // account) is in flight, so Settings can disable its buttons.
    @Published var syncAccountActionInProgress = false
    @Published var syncInProgress = false
    @Published var googleAuthInProgress = false
    @Published var googleSyncInProgress = false
    @Published var googleCalendarStatus: String?
    // Available StoreKit subscription products (empty until loaded / if unconfigured).
    @Published var syncProducts: [Product] = []
    @Published var purchaseInProgress = false

    // App Store Connect product id(s) for the sync subscription.
    static let syncProductIDs: Set<String> = ["com.knotq.sync.monthly"]
    private static let foregroundGoogleSyncIntervalNanos: UInt64 = 120_000_000_000
    private static let backgroundGoogleSyncInterval: TimeInterval = 6 * 60 * 60

    private let bridge: RustBridge?
    private let iso = ISO8601DateFormatter()
    private let syncSessionKey = "knotq.localSyncSession"
    private let backgroundGoogleSyncKey = "knotq.lastBackgroundGoogleSyncAt"
    private var syncPollTask: Task<Void, Never>?
    private var googleSyncTask: Task<Void, Never>?
    private var googleOAuthSession: WebAuthenticationSessionCoordinator?
    private var browserSignInSession: WebAuthenticationSessionCoordinator?
    private var transactionListener: Task<Void, Never>?

    init() {
        bridge = try? RustBridge()
        iso.formatOptions = [.withInternetDateTime]
        syncSession = Self.loadSyncSession(key: syncSessionKey)
        if bridge == nil {
            errorMessage = "Rust core failed to initialize"
        }
        MobileNotificationScheduler.shared.configure(model: self)
        refresh()
        startSyncPolling()
        startTransactionListener()
        #if DEBUG
        seedEditorImageFixture()
        #endif
    }

    var preferredColorScheme: ColorScheme? {
        switch snapshot?.settings.themeMode {
        case "light": .light
        case "dark", nil: .dark
        default: nil
        }
    }

    var backgroundRefreshEligible: Bool {
        syncSession?.supportsSync == true || (snapshot?.settings.googleAccountCount ?? 0) > 0
    }

    func refresh() {
        guard let bridge else { return }
        do {
            let nextSnapshot = try bridge.snapshot(today: Self.dateOnly(selectedDate), weekOffset: weekOffset)
            snapshot = nextSnapshot
            KnotQWidgetSnapshotStore.publish(snapshot: nextSnapshot)
            rescheduleNotifications()
            configureGoogleSyncPolling(accountCount: nextSnapshot.settings.googleAccountCount)
            BackgroundSyncCoordinator.shared.scheduleIfEligible(backgroundRefreshEligible)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func search(_ query: String) {
        guard let bridge else { return }
        do {
            searchHits = try bridge.search(query)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func monthDays(year: Int, month: Int) -> [MobileCalendarDay] {
        guard let bridge else { return [] }
        return (try? bridge.monthDays(year: year, month: month)) ?? []
    }

    func createFolder(name: String, parentID: String? = nil) {
        mutate { try $0.createFolder(name: name, parentID: parentID) }
    }

    func renameFolder(id: String, name: String) {
        mutate { try $0.renameFolder(id: id, name: name) }
    }

    func deleteFolder(id: String) {
        mutate { try $0.deleteFolder(id: id) }
    }

    func archiveFolder(id: String) {
        deleteFolder(id: id)
    }

    @discardableResult
    func createScheme(name: String, folderID: String? = nil, position: Int32? = 0) -> String? {
        let before = Set(snapshot?.schemes.map(\.id) ?? [])
        mutate { try $0.createScheme(name: name, folderID: folderID, position: position) }
        return snapshot?.schemes.first { !before.contains($0.id) && $0.name == name }?.id
            ?? snapshot?.schemes.first { !before.contains($0.id) }?.id
    }

    func renameScheme(id: String, name: String) {
        mutate { try $0.renameScheme(id: id, name: name) }
    }

    func deleteScheme(id: String) {
        mutate { try $0.deleteScheme(id: id) }
    }

    func archiveScheme(id: String) {
        deleteScheme(id: id)
    }

    func restoreScheme(id: String) {
        mutate { try $0.restoreScheme(id: id) }
    }

    func permanentlyDeleteScheme(id: String) {
        mutate { try $0.permanentlyDeleteScheme(id: id) }
    }

    func emptyArchive() {
        mutate { try $0.emptyArchive() }
    }

    func setSchemeColor(id: String, colorIndex: Int32) {
        mutate { try $0.setSchemeColor(id: id, colorIndex: colorIndex) }
    }

    func moveNode(kind: String, id: String, folderID: String, position: Int) {
        mutate { try $0.moveNode(kind: kind, id: id, folderID: folderID, position: Int32(position)) }
    }

    func ensureDailyQueue(date: Date) {
        selectedDate = date
        mutate { try $0.ensureDailyQueue(date: Self.dateOnly(date)) }
    }

    func ensureTodayDailyQueue() {
        mutate { try $0.ensureDailyQueue(date: Self.dateOnly(Date())) }
    }

    func selectDate(_ date: Date) {
        selectedDate = date
        refresh()
    }

    func addItem(schemeID: String, text: String, marker: Marker = .checkbox, indent: Int32 = 0) {
        mutate { try $0.addItem(schemeID: schemeID, text: text, marker: marker, indent: indent) }
    }

    func addTodayDailyItem(text: String, marker: Marker = .checkbox, indent: Int32 = 0) {
        selectedDate = Date()
        mutate {
            try $0.addTodayDailyItem(
                today: Self.dateOnly(Date()),
                text: text,
                marker: marker,
                indent: indent
            )
        }
    }

    func updateItemText(schemeID: String, itemID: String, text: String) {
        mutate { try $0.updateItemText(schemeID: schemeID, itemID: itemID, text: text) }
    }

    func setItemMarker(schemeID: String, itemID: String, marker: Marker) {
        mutate { try $0.setItemMarker(schemeID: schemeID, itemID: itemID, marker: marker) }
    }

    func setItemIndent(schemeID: String, itemID: String, indent: Int32) {
        mutate { try $0.setItemIndent(schemeID: schemeID, itemID: itemID, indent: indent) }
    }

    func reorderItem(schemeID: String, from: Int, to: Int) {
        mutate { try $0.reorderItem(schemeID: schemeID, from: from, to: to) }
    }

    func replaceSchemeItems(schemeID: String, items: [MobileItemEdit]) {
        mutate { try $0.replaceSchemeItems(schemeID: schemeID, items: items) }
    }

    func setItemDate(schemeID: String, itemID: String, kind: String, date: Date?) {
        mutate {
            try $0.setItemDate(
                schemeID: schemeID,
                itemID: itemID,
                kind: kind,
                date: date.map { iso.string(from: $0) }
            )
        }
    }

    func setItemRecurrence(schemeID: String, itemID: String, rrule: String?) {
        mutate { try $0.setItemRecurrence(schemeID: schemeID, itemID: itemID, rrule: rrule) }
    }

    func commitEventEdit(
        occurrence: MobileOccurrence,
        title: String,
        start: Date?,
        end: Date?,
        rrule: String?,
        notificationOffsetSecs: Int32?,
        notificationDirty: Bool,
        done: Bool,
        scope: EventOccurrenceScope
    ) {
        mutate {
            try $0.commitEventEdit(
                occurrence: occurrence,
                title: title,
                occurrenceStart: occurrence.start,
                occurrenceEnd: occurrence.end,
                start: start.map { iso.string(from: $0) },
                end: end.map { iso.string(from: $0) },
                rrule: rrule,
                notificationOffsetSecs: notificationOffsetSecs,
                notificationDirty: notificationDirty,
                done: done,
                scope: scope
            )
        }
    }

    func setOccurrenceNotificationOffset(
        schemeID: String,
        itemID: String,
        occurrenceJSON: String? = nil,
        offsetSecs: Int32?
    ) {
        mutate {
            try $0.setOccurrenceNotificationOffset(
                schemeID: schemeID,
                itemID: itemID,
                occurrenceJSON: occurrenceJSON,
                offsetSecs: offsetSecs
            )
        }
    }

    func toggleItem(schemeID: String, itemID: String) {
        mutate { try $0.toggleItem(schemeID: schemeID, itemID: itemID) }
    }

    func toggleOccurrence(_ occurrence: MobileOccurrence) {
        mutate {
            try $0.toggleOccurrence(
                schemeID: occurrence.schemeId,
                itemID: occurrence.itemId,
                occurrenceJSON: occurrence.occurrenceJson
            )
        }
    }

    func deleteItem(schemeID: String, itemID: String) {
        mutate { try $0.deleteItem(schemeID: schemeID, itemID: itemID) }
    }

    func deleteEventOccurrence(_ occurrence: MobileOccurrence, scope: EventOccurrenceScope) {
        mutate { try $0.deleteEventOccurrence(occurrence, scope: scope) }
    }

    func addCalendarItem(kind: CalendarKind, text: String, date: Date, start: Date?, end: Date?, schemeID: String? = nil) {
        mutate {
            try $0.addCalendarItem(
                kind: kind,
                text: text,
                date: Self.dateOnly(date),
                start: start.map { iso.string(from: $0) },
                end: end.map { iso.string(from: $0) },
                schemeID: schemeID
            )
        }
    }

    func todayDailySchemeID() -> String? {
        snapshot?.daily.first { $0.date == Self.dateOnly(Date()) }?.scheme.id
    }

    /// Creates a calendar item and returns the new item's id so callers can
    /// follow up (e.g. apply a recurrence). Resolves nil schemes to today's
    /// daily queue, then diffs that scheme's items.
    @discardableResult
    func createCalendarItemReturningID(
        kind: CalendarKind,
        text: String,
        date: Date,
        start: Date?,
        end: Date?,
        schemeID: String?
    ) -> String? {
        guard let bridge else { return nil }
        let targetID: String
        if let schemeID {
            targetID = schemeID
        } else {
            let todayKey = Self.dateOnly(Date())
            try? bridge.ensureDailyQueue(date: todayKey)
            refresh()
            guard let dailyID = snapshot?.daily.first(where: { $0.date == todayKey })?.scheme.id else {
                addCalendarItem(kind: kind, text: text, date: date, start: start, end: end, schemeID: nil)
                return nil
            }
            targetID = dailyID
        }
        let before = Set(schemeItems(id: targetID).map(\.id))
        addCalendarItem(kind: kind, text: text, date: date, start: start, end: end, schemeID: targetID)
        return schemeItems(id: targetID).first { !before.contains($0.id) }?.id
    }

    /// Items for a scheme id, searching active, archived, and daily schemes.
    private func schemeItems(id: String) -> [MobileItem] {
        if let s = snapshot?.schemes.first(where: { $0.id == id }) { return s.items }
        if let s = snapshot?.daily.first(where: { $0.scheme.id == id })?.scheme { return s.items }
        if let s = snapshot?.archivedSchemes.first(where: { $0.id == id }) { return s.items }
        return []
    }

    func setThemeMode(_ mode: String) {
        mutate { try $0.setThemeMode(mode) }
    }

    func setTimeFormat(_ format: String) {
        mutate { try $0.setTimeFormat(format) }
    }

    func setNotificationDefaults(eventOffsetSecs: Int32, assignmentOffsetSecs: Int32) {
        mutate {
            try $0.setNotificationDefaults(
                eventOffsetSecs: eventOffsetSecs,
                assignmentOffsetSecs: assignmentOffsetSecs
            )
        }
    }

    func resetWorkspace() {
        mutate { try $0.resetWorkspace() }
    }

    func connectGoogleCalendar(parentID: String? = nil) async {
        guard !googleAuthInProgress, let bridge else { return }
        googleAuthInProgress = true
        defer {
            googleAuthInProgress = false
            googleOAuthSession = nil
        }

        do {
            let config = try Self.googleOAuthConfigForImport()
            let request = try bridge.googleAuthRequest(clientID: config.clientID, redirectURI: config.redirectURI)
            guard let authURL = URL(string: request.authUrl) else {
                throw GoogleOAuthConfigError.message("Google returned an invalid authorization URL.")
            }

            let session = WebAuthenticationSessionCoordinator()
            googleOAuthSession = session
            let callbackURL = try await session.authenticate(url: authURL, callbackScheme: config.redirectScheme)
            let result = try await Task.detached {
                try bridge.completeGoogleCalendarImport(
                    request: request,
                    callbackURL: callbackURL.absoluteString,
                    clientSecret: config.clientSecret,
                    parentID: parentID
                )
            }.value
            googleCalendarStatus = result.message
            refresh()
            if syncSession != nil {
                await syncOnce()
            }
            errorMessage = nil
        } catch {
            if Self.isWebAuthCancellation(error) {
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func syncGoogleCalendars(silent: Bool = false) async -> Bool {
        guard !googleSyncInProgress, let bridge else { return false }
        guard snapshot?.settings.googleAccountCount ?? 0 > 0 else { return false }
        googleSyncInProgress = true
        defer { googleSyncInProgress = false }

        do {
            let clientID = Self.configuredGoogleClientID()
            let clientSecret = Self.configuredGoogleClientSecret()
            let result = try await Task.detached {
                try bridge.syncGoogleCalendars(clientID: clientID, clientSecret: clientSecret)
            }.value
            googleCalendarStatus = result.message
            refresh()
            if syncSession != nil {
                await syncOnce()
            }
            if !silent {
                errorMessage = nil
            }
            return result.importedCount > 0 || result.syncedCount > 0
        } catch {
            if silent {
                googleCalendarStatus = error.localizedDescription
            } else {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    private static let signInPageURL = "https://www.knotq.com/signin.html"
    private static let signInRedirectScheme = "knotq"
    private static let signInRedirectURI = "knotq://auth-callback"
    private static let defaultSyncApiBase = "https://api.knotq.com"

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
            await syncOnce()
        } catch {
            if Self.isWebAuthCancellation(error) {
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    /// Redeem the one-time authorization code (with the PKCE verifier) for a session.
    private func exchangeAuthorizeCode(
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

    private static func signInAuthorizeURL(
        apiBase: String,
        mode: SyncAuthMode,
        state: String,
        codeChallenge: String,
        redirectURI: String
    ) -> URL? {
        var components = URLComponents(string: signInPageURL)
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

    private static func pkceVerifier() -> String {
        base64URLNoPad(randomData(32))
    }

    private static func pkceChallenge(_ verifier: String) -> String {
        base64URLNoPad(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func randomURLToken(_ byteCount: Int) -> String {
        base64URLNoPad(randomData(byteCount))
    }

    private static func randomData(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) })
    }

    private static func base64URLNoPad(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func installSyncSession(_ payload: SyncLoginResponse, apiBase: String) {
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
        saveSyncSession(session)
        startSyncPolling()
        BackgroundSyncCoordinator.shared.scheduleIfEligible(backgroundRefreshEligible)
    }

    func signOutSync() {
        syncSession = nil
        syncPollTask?.cancel()
        syncPollTask = nil
        BackgroundSyncCoordinator.shared.scheduleIfEligible(backgroundRefreshEligible)
        UserDefaults.standard.removeObject(forKey: syncSessionKey)
    }

    /// Turn off the sync entitlement for this account while keeping the account and
    /// the local workspace intact (the in-app "cancel subscription" action). The
    /// backend rotates the session, so we install the credentials it returns.
    func cancelSyncSubscription() async {
        guard syncSession != nil else { return }
        syncAccountActionInProgress = true
        defer { syncAccountActionInProgress = false }
        // Use a fresh access token; refresh signs us out if the session is dead.
        guard await refreshSyncSessionIfNeeded(),
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
                let code = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                throw SyncAuthError.message(Self.accountActionErrorMessage(code?["code"] as? String))
            }
            let payload = try JSONDecoder().decode(SyncLoginResponse.self, from: data)
            installSyncSession(payload, apiBase: session.apiBase)
            if syncSession?.supportsSync == true {
                errorMessage = "Your subscription has been cancelled. Sync remains available until the current billing period ends."
            } else {
                errorMessage = "Sync has been turned off for this account. Your local workspace stays on this device, and you can sign in again later to re-enable sync."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Schedule account deletion: the account is immediately inaccessible but is
    /// only purged after a 14-day grace window, so signing back in undoes it. Apple
    /// requires this in-app path for any app that supports account creation.
    func deleteSyncAccount() async {
        guard syncSession != nil else { return }
        syncAccountActionInProgress = true
        defer { syncAccountActionInProgress = false }
        guard await refreshSyncSessionIfNeeded(),
              let session = syncSession,
              let url = URL(string: "\(session.apiBase)/v1/auth/account") else {
            return
        }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(session.bearerToken)", forHTTPHeaderField: "Authorization")
            // The backend echoes the email back as a deliberate-action guard.
            request.httpBody = try JSONSerialization.data(withJSONObject: ["confirm_email": session.email])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SyncAuthError.message("Sync backend returned an invalid response.")
            }
            guard (200..<300).contains(http.statusCode) else {
                let code = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                throw SyncAuthError.message(Self.accountActionErrorMessage(code?["code"] as? String))
            }
            // The session is revoked server-side; drop it locally and tell the user.
            signOutSync()
            errorMessage = "Your account is scheduled for deletion. Sign in again within 14 days to cancel it; after that your synced data is permanently erased."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Subscriptions (StoreKit)

    private func startTransactionListener() {
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

    private func handle(transactionResult: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let transaction) = transactionResult else { return }
        await transaction.finish()
        await refreshEntitlement()
    }

    /// Force a session refresh so a server-side entitlement change (granted by a
    /// billing webhook) is reflected locally. Guarded by syncInProgress so it can't
    /// race the poll loop into replaying the single-use refresh token.
    func refreshEntitlement() async {
        guard !syncInProgress,
              let session = syncSession,
              !session.refreshToken.isEmpty,
              let url = URL(string: "\(session.apiBase)/v1/auth/refresh") else {
            return
        }
        syncInProgress = true
        defer { syncInProgress = false }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": session.refreshToken])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 401 {
                signOutSync()
                errorMessage = "Your sync session expired. Please sign in again."
                return
            }
            guard (200..<300).contains(http.statusCode) else { return }
            let payload = try JSONDecoder().decode(SyncLoginResponse.self, from: data)
            installRefreshedSession(payload, from: session)
        } catch {
            // Keep the current session; the user can retry.
        }
    }

    /// Verify a just-completed StoreKit purchase with the backend so the sync
    /// entitlement is granted *immediately* (and the session updated), instead of
    /// waiting on Apple's asynchronous App Store Server Notification. Shares the
    /// syncInProgress guard with the refresh path: the verify response rotates the
    /// session (a fresh refresh token), so it must not race the poll loop.
    private func verifyApplePurchase(jws: String) async {
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
    private func installRefreshedSession(_ payload: SyncLoginResponse, from session: LocalSyncSession) {
        var updated = session
        updated.bearerToken = payload.bearerToken
        updated.expiresAt = payload.expiresAt
        updated.refreshToken = payload.refreshToken
        updated.refreshExpiresAt = payload.refreshExpiresAt
        updated.supportsSync = payload.supportsSync
        syncSession = updated
        saveSyncSession(updated)
        BackgroundSyncCoordinator.shared.scheduleIfEligible(backgroundRefreshEligible)
        if updated.supportsSync {
            Task { await self.syncOnce() }
        }
    }

    /// Hand the Rust core a push token (e.g. an FCM token from Firebase) so the
    /// next sync registers this device for silent background wake-ups.
    func setPushToken(_ token: String, environment: String = "production") {
        guard let bridge else { return }
        do {
            try bridge.setPushRegistration(token: token, environment: environment)
        } catch {
            return
        }
        if syncSession?.supportsSync == true {
            Task { await runBackgroundSync() }
        }
    }

    /// One-shot sync used by background app refresh and silent pushes. Guarded so it
    /// can't race the foreground poll; returns whether remote changes were applied.
    @discardableResult
    func runBackgroundSync() async -> Bool {
        guard !syncInProgress, let session = syncSession, session.supportsSync else { return false }
        syncInProgress = true
        defer { syncInProgress = false }
        guard await refreshSyncSessionIfNeeded(), let bridge, let current = syncSession else {
            return false
        }
        do {
            let result = try await Task.detached {
                let changed = try bridge.syncOnce(
                    apiBase: current.apiBase,
                    bearerToken: current.bearerToken,
                )
                let notice = try bridge.takeSyncNotice()
                return (changed, notice)
            }.value
            if result.0 {
                refresh()
            }
            if let notice = result.1 {
                errorMessage = notice
            }
            return result.0
        } catch {
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
        guard await refreshSyncSessionIfNeeded() else { return }

        guard let bridge, let session = syncSession, session.supportsSync else { return }
        do {
            let result = try await Task.detached {
                let changed = try bridge.syncOnce(apiBase: session.apiBase, bearerToken: session.bearerToken)
                let notice = try bridge.takeSyncNotice()
                return (changed, notice)
            }.value
            if result.0 {
                refresh()
            }
            errorMessage = result.1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Refresh the access token before syncing if it's near expiry, persisting the
    /// rotated credentials immediately. Returns false (and signs out) only if the
    /// refresh token itself is dead; transient failures keep the current token.
    private func refreshSyncSessionIfNeeded() async -> Bool {
        guard let session = syncSession else { return false }
        guard !session.refreshToken.isEmpty else {
            signOutSync()
            errorMessage = "Your sync session expired. Please sign in again."
            return false
        }
        guard Self.tokenNeedsRefresh(session.expiresAt),
              let url = URL(string: "\(session.apiBase)/v1/auth/refresh")
        else {
            return true
        }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": session.refreshToken])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return true }
            if http.statusCode == 401 {
                // Refresh token revoked/expired/replayed: the session is gone.
                signOutSync()
                errorMessage = "Your sync session expired. Please sign in again."
                return false
            }
            guard (200..<300).contains(http.statusCode) else {
                // Transient server error: keep the current token, retry next tick.
                return true
            }
            let payload = try JSONDecoder().decode(SyncLoginResponse.self, from: data)
            var updated = session
            updated.bearerToken = payload.bearerToken
            updated.expiresAt = payload.expiresAt
            updated.refreshToken = payload.refreshToken
            updated.refreshExpiresAt = payload.refreshExpiresAt
            updated.supportsSync = payload.supportsSync
            syncSession = updated
            saveSyncSession(updated)
            BackgroundSyncCoordinator.shared.scheduleIfEligible(backgroundRefreshEligible)
            return true
        } catch {
            // Network/parse hiccup: keep the current token, retry next tick.
            return true
        }
    }

    /// True when the access token expires within the skew window (or is
    /// unparseable, in which case we refresh defensively).
    private static func tokenNeedsRefresh(_ expiresAt: String) -> Bool {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let expiry = withFraction.date(from: expiresAt) ?? plain.date(from: expiresAt) else {
            return true
        }
        return expiry.timeIntervalSinceNow <= 120
    }

    func scheme(id: String?) -> MobileScheme? {
        guard let id else { return nil }
        return snapshot?.schemes.first { $0.id == id }
            ?? snapshot?.daily.first { $0.scheme.id == id }?.scheme
            ?? snapshot?.archivedSchemes.first { $0.id == id }
    }

    private func mutate(_ action: (RustBridge) throws -> Void) {
        guard let bridge else { return }
        do {
            try action(bridge)
            refresh()
            errorMessage = nil
            if syncSession != nil {
                Task { await syncOnce() }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func handleNotificationAction(_ request: MobileNotificationActionRequest) {
        guard let bridge else { return }
        do {
            let changed = try bridge.applyNotificationAction(request)
            if changed {
                refresh()
                if syncSession != nil {
                    Task { await syncOnce() }
                }
            } else {
                rescheduleNotifications()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rescheduleNotifications() {
        guard let bridge else { return }
        do {
            MobileNotificationScheduler.shared.reschedule(try bridge.pendingNotifications())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startSyncPolling() {
        syncPollTask?.cancel()
        guard syncSession != nil else { return }
        syncPollTask = Task { [weak self] in
            await self?.syncOnce()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self?.syncOnce()
            }
        }
    }

    private func configureGoogleSyncPolling(accountCount: Int32) {
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

    private func runBackgroundGoogleCalendarSyncIfDue() async -> Bool {
        guard snapshot?.settings.googleAccountCount ?? 0 > 0 else { return false }
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: backgroundGoogleSyncKey) as? Date,
           Date().timeIntervalSince(last) < Self.backgroundGoogleSyncInterval {
            return false
        }
        defaults.set(Date(), forKey: backgroundGoogleSyncKey)
        return await syncGoogleCalendars(silent: true)
    }

    private func saveSyncSession(_ session: LocalSyncSession) {
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: syncSessionKey)
        }
    }

    private static func loadSyncSession(key: String) -> LocalSyncSession? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LocalSyncSession.self, from: data)
    }

    private func normalizedApiBase(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// The authorization code is minted by the hosted page and redeemed here, so the
    /// only failures the app surfaces are a stale/replayed code.
    private static func authorizeErrorMessage(_ code: String?) -> String {
        switch code {
        case "invalid_authorization_code", "authorization_code_expired", "invalid_code_challenge":
            return "Sign-in could not be completed. Please try signing in again."
        default:
            return "Sign in failed."
        }
    }

    private static func accountActionErrorMessage(_ code: String?) -> String {
        switch code {
        case "unauthorized":
            return "Your sync session expired. Sign in again, then retry."
        case "delete_confirmation_mismatch":
            return "Could not confirm the account. Please try again."
        case "billing_api_not_configured":
            return "Subscription cancellation is not configured yet."
        case "cancel_in_app_store":
            return "Manage this App Store subscription from your Apple account subscriptions."
        default:
            return "The request to the sync API failed."
        }
    }

    private static func googleOAuthConfigForImport() throws -> GoogleOAuthMobileConfig {
        guard let clientID = configuredGoogleClientID() else {
            throw GoogleOAuthConfigError.message("Bundle GoogleService-Info.plist or set KnotQGoogleClientID to connect Google Calendar.")
        }
        let redirectScheme = configuredGoogleRedirectScheme()
            ?? derivedGoogleRedirectScheme(clientID: clientID)
        guard let redirectScheme else {
            throw GoogleOAuthConfigError.message("Bundle GoogleService-Info.plist or set KnotQGoogleRedirectScheme for the Google OAuth callback.")
        }
        let redirectURI = configuredGoogleRedirectURI() ?? "\(redirectScheme):/oauth2redirect"
        return GoogleOAuthMobileConfig(
            clientID: clientID,
            clientSecret: configuredGoogleClientSecret(),
            redirectScheme: redirectScheme,
            redirectURI: redirectURI
        )
    }

    private static func configuredGoogleClientID() -> String? {
        googleConfigString(infoKey: "KnotQGoogleClientID", envKeys: ["KNOTQ_GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_ID"])
            ?? bundledGoogleServiceValue("CLIENT_ID")
    }

    private static func configuredGoogleClientSecret() -> String? {
        googleConfigString(infoKey: "KnotQGoogleClientSecret", envKeys: ["KNOTQ_GOOGLE_CLIENT_SECRET", "GOOGLE_CLIENT_SECRET"])
    }

    private static func configuredGoogleRedirectScheme() -> String? {
        googleConfigString(infoKey: "KnotQGoogleRedirectScheme", envKeys: ["KNOTQ_GOOGLE_REDIRECT_SCHEME", "GOOGLE_REDIRECT_SCHEME"])
            ?? bundledGoogleServiceValue("REVERSED_CLIENT_ID")
    }

    private static func configuredGoogleRedirectURI() -> String? {
        googleConfigString(infoKey: "KnotQGoogleRedirectURI", envKeys: ["KNOTQ_GOOGLE_REDIRECT_URI", "GOOGLE_REDIRECT_URI"])
    }

    private static func googleConfigString(infoKey: String, envKeys: [String]) -> String? {
        if let value = usableGoogleConfigString(Bundle.main.object(forInfoDictionaryKey: infoKey) as? String) {
            return value
        }
        for key in envKeys {
            if let value = usableGoogleConfigString(ProcessInfo.processInfo.environment[key]) {
                return value
            }
        }
        return nil
    }

    private static func bundledGoogleServiceValue(_ key: String) -> String? {
        guard let url = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any],
              let value = dictionary[key] as? String else {
            return nil
        }
        return usableGoogleConfigString(value)
    }

    private static func usableGoogleConfigString(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.contains("$(") else {
            return nil
        }
        return trimmed
    }

    private static func derivedGoogleRedirectScheme(clientID: String) -> String? {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix) else { return nil }
        return "com.googleusercontent.apps.\(clientID.dropLast(suffix.count))"
    }

    private static func isWebAuthCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == ASWebAuthenticationSessionError.errorDomain
            && nsError.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue
    }

    #if DEBUG
    private func seedEditorImageFixture() {
        guard let bridge else { return }
        do {
            try bridge.seedEditorImageFixture()
            snapshot = try bridge.snapshot(today: Self.dateOnly(selectedDate), weekOffset: weekOffset)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif

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

private struct SyncLoginResponse: Decodable {
    let userId: String
    let email: String
    let supportsSync: Bool
    let bearerToken: String
    let expiresAt: String
    let refreshToken: String
    let refreshExpiresAt: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case email
        case supportsSync = "supports_sync"
        case bearerToken = "bearer_token"
        case expiresAt = "expires_at"
        case refreshToken = "refresh_token"
        case refreshExpiresAt = "refresh_expires_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decode(String.self, forKey: .userId)
        email = try container.decode(String.self, forKey: .email)
        supportsSync = try container.decodeIfPresent(Bool.self, forKey: .supportsSync) ?? true
        bearerToken = try container.decode(String.self, forKey: .bearerToken)
        expiresAt = try container.decode(String.self, forKey: .expiresAt)
        refreshToken = try container.decode(String.self, forKey: .refreshToken)
        refreshExpiresAt = try container.decodeIfPresent(String.self, forKey: .refreshExpiresAt)
    }
}

private enum SyncAuthError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}

private struct GoogleOAuthMobileConfig {
    let clientID: String
    let clientSecret: String?
    let redirectScheme: String
    let redirectURI: String
}

private enum GoogleOAuthConfigError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}

/// Drives an `ASWebAuthenticationSession` for any browser-redirect flow (Google
/// Calendar import and sync sign-in), intercepting the custom callback scheme.
@MainActor
private final class WebAuthenticationSessionCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        session?.cancel()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let next = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
                    Task { @MainActor in
                        guard let self else { return }
                        let pending = self.continuation
                        self.continuation = nil
                        self.session = nil
                        if let error {
                            pending?.resume(throwing: error)
                        } else if let callbackURL {
                            pending?.resume(returning: callbackURL)
                        } else {
                            pending?.resume(throwing: GoogleOAuthConfigError.message("The browser did not return a callback URL."))
                        }
                    }
                }
                next.presentationContextProvider = self
                next.prefersEphemeralWebBrowserSession = false
                self.session = next
                if !next.start() {
                    self.session = nil
                    self.continuation = nil
                    continuation.resume(throwing: GoogleOAuthConfigError.message("Could not open the browser."))
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.cancel()
            }
        }
    }

    func cancel() {
        session?.cancel()
        session = nil
        continuation = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
            ?? scenes.first?.windows.first
            ?? ASPresentationAnchor()
    }
}
