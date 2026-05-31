import AuthenticationServices
import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot: MobileSnapshot?
    @Published var searchHits: [MobileSearchHit] = []
    @Published var errorMessage: String?
    @Published var selectedDate = Date()
    @Published var weekOffset = 0
    @Published var syncSession: LocalSyncSession?
    @Published var syncAuthInProgress = false
    @Published var syncInProgress = false
    @Published var googleAuthInProgress = false
    @Published var googleSyncInProgress = false
    @Published var googleCalendarStatus: String?

    private let bridge: RustBridge?
    private let iso = ISO8601DateFormatter()
    private let syncSessionKey = "knotq.localSyncSession"
    private var syncPollTask: Task<Void, Never>?
    private var googleSyncTask: Task<Void, Never>?
    private var googleOAuthSession: GoogleOAuthSessionCoordinator?

    init() {
        bridge = try? RustBridge()
        iso.formatOptions = [.withInternetDateTime]
        syncSession = Self.loadSyncSession(key: syncSessionKey)
        if let session = syncSession {
            let migrated = Self.migratedSyncSession(session)
            if migrated != session {
                syncSession = migrated
                saveSyncSession(migrated)
            }
        }
        if bridge == nil {
            errorMessage = "Rust core failed to initialize"
        }
        MobileNotificationScheduler.shared.configure(model: self)
        refresh()
        startSyncPolling()
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

    func refresh() {
        guard let bridge else { return }
        do {
            let nextSnapshot = try bridge.snapshot(today: Self.dateOnly(selectedDate), weekOffset: weekOffset)
            snapshot = nextSnapshot
            KnotQWidgetSnapshotStore.publish(snapshot: nextSnapshot)
            rescheduleNotifications()
            configureGoogleSyncPolling(accountCount: nextSnapshot.settings.googleAccountCount)
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

    func addItem(schemeID: String, text: String, marker: Marker = .checkbox, indent: Int32 = 0) {
        mutate { try $0.addItem(schemeID: schemeID, text: text, marker: marker, indent: indent) }
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

    /// Creates a calendar item and returns the new item's id so callers can
    /// follow up (e.g. apply a recurrence). Resolves the daily-queue scheme for
    /// `date` when `schemeID` is nil, then diffs that scheme's items.
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
        let dateKey = Self.dateOnly(date)
        let targetID: String
        if let schemeID {
            targetID = schemeID
        } else {
            try? bridge.ensureDailyQueue(date: dateKey)
            refresh()
            guard let dailyID = snapshot?.daily.first(where: { $0.date == dateKey })?.scheme.id else {
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

            let session = GoogleOAuthSessionCoordinator()
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
            if Self.isGoogleAuthCancellation(error) {
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    func syncGoogleCalendars(silent: Bool = false) async {
        guard !googleSyncInProgress, let bridge else { return }
        guard snapshot?.settings.googleAccountCount ?? 0 > 0 else { return }
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
        } catch {
            if silent {
                googleCalendarStatus = error.localizedDescription
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    func signInToSync(apiBase: String, email: String, password: String) async {
        let apiBase = normalizedApiBase(apiBase)
        guard !apiBase.isEmpty, let url = URL(string: "\(apiBase)/v1/auth/login") else {
            errorMessage = "Enter a sync API URL."
            return
        }
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
            errorMessage = "Enter your email and password."
            return
        }

        syncAuthInProgress = true
        defer { syncAuthInProgress = false }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "email": email,
                "password": password
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SyncAuthError.message("Sync backend returned an invalid response.")
            }
            guard (200..<300).contains(http.statusCode) else {
                let code = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                throw SyncAuthError.message(Self.syncErrorMessage(code?["code"] as? String))
            }
            let payload = try JSONDecoder().decode(SyncLoginResponse.self, from: data)
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
            errorMessage = nil
            startSyncPolling()
            await syncOnce()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOutSync() {
        syncSession = nil
        syncPollTask?.cancel()
        syncPollTask = nil
        UserDefaults.standard.removeObject(forKey: syncSessionKey)
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
        guard let refreshToken = session.refreshToken, !refreshToken.isEmpty else {
            // Legacy session without a refresh token: proceed; if the access token
            // has lapsed the sync fails and the user can sign in again.
            return true
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
            request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
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
            if let rotated = payload.refreshToken, !rotated.isEmpty {
                updated.refreshToken = rotated
            }
            updated.refreshExpiresAt = payload.refreshExpiresAt
            updated.supportsSync = payload.supportsSync
            syncSession = updated
            saveSyncSession(updated)
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
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                await self?.syncGoogleCalendars(silent: true)
            }
        }
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
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return Self.migratedApiBase(trimmed)
    }

    private static func migratedSyncSession(_ session: LocalSyncSession) -> LocalSyncSession {
        var migrated = session
        migrated.apiBase = migratedApiBase(session.apiBase)
        return migrated
    }

    private static func migratedApiBase(_ apiBase: String) -> String {
        let trimmed = apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch trimmed {
        case "http://127.0.0.1:7878", "http://localhost:7878":
            return "http://127.0.0.1:8787"
        default:
            return trimmed
        }
    }

    private static func syncErrorMessage(_ code: String?) -> String {
        switch code {
        case "invalid_email", "unauthorized":
            return "Email or password is incorrect."
        case "password_too_long":
            return "Password is too long."
        default:
            return "Sign in failed."
        }
    }

    private static func googleOAuthConfigForImport() throws -> GoogleOAuthMobileConfig {
        guard let clientID = configuredGoogleClientID() else {
            throw GoogleOAuthConfigError.message("Set KNOTQ_GOOGLE_CLIENT_ID or KnotQGoogleClientID to connect Google Calendar.")
        }
        let redirectScheme = configuredGoogleRedirectScheme()
            ?? derivedGoogleRedirectScheme(clientID: clientID)
        guard let redirectScheme else {
            throw GoogleOAuthConfigError.message("Set KNOTQ_GOOGLE_REDIRECT_SCHEME or KnotQGoogleRedirectScheme for the Google OAuth callback.")
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
    }

    private static func configuredGoogleClientSecret() -> String? {
        googleConfigString(infoKey: "KnotQGoogleClientSecret", envKeys: ["KNOTQ_GOOGLE_CLIENT_SECRET", "GOOGLE_CLIENT_SECRET"])
    }

    private static func configuredGoogleRedirectScheme() -> String? {
        googleConfigString(infoKey: "KnotQGoogleRedirectScheme", envKeys: ["KNOTQ_GOOGLE_REDIRECT_SCHEME", "GOOGLE_REDIRECT_SCHEME"])
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

    private static func isGoogleAuthCancellation(_ error: Error) -> Bool {
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
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func displayDate(_ raw: String) -> String {
        let input = DateFormatter()
        input.calendar = Calendar(identifier: .gregorian)
        input.locale = Locale(identifier: "en_US_POSIX")
        input.dateFormat = "yyyy-MM-dd"
        guard let date = input.date(from: raw) else { return raw }
        let output = DateFormatter()
        output.dateStyle = .medium
        return output.string(from: date)
    }

    static func date(from raw: String) -> Date? {
        let input = DateFormatter()
        input.calendar = Calendar(identifier: .gregorian)
        input.locale = Locale(identifier: "en_US_POSIX")
        input.dateFormat = "yyyy-MM-dd"
        return input.date(from: raw)
    }
}

private struct SyncLoginResponse: Decodable {
    let userId: String
    let email: String
    let supportsSync: Bool
    let bearerToken: String
    let expiresAt: String
    let refreshToken: String?
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
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
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

@MainActor
private final class GoogleOAuthSessionCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
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
                            pending?.resume(throwing: GoogleOAuthConfigError.message("Google OAuth did not return a callback URL."))
                        }
                    }
                }
                next.presentationContextProvider = self
                next.prefersEphemeralWebBrowserSession = false
                self.session = next
                if !next.start() {
                    self.session = nil
                    self.continuation = nil
                    continuation.resume(throwing: GoogleOAuthConfigError.message("Could not start Google OAuth."))
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
