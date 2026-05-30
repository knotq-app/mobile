import Foundation
import SwiftUI

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

    private let bridge: RustBridge?
    private let iso = ISO8601DateFormatter()
    private let syncSessionKey = "knotq.localSyncSession"
    private var syncPollTask: Task<Void, Never>?

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
            snapshot = try bridge.snapshot(today: Self.dateOnly(selectedDate), weekOffset: weekOffset)
            rescheduleNotifications()
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
                expiresAt: payload.expiresAt
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
        guard !syncInProgress, let bridge, let session = syncSession, session.supportsSync else {
            return
        }
        syncInProgress = true
        defer { syncInProgress = false }
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

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case email
        case supportsSync = "supports_sync"
        case bearerToken = "bearer_token"
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decode(String.self, forKey: .userId)
        email = try container.decode(String.self, forKey: .email)
        supportsSync = try container.decodeIfPresent(Bool.self, forKey: .supportsSync) ?? true
        bearerToken = try container.decode(String.self, forKey: .bearerToken)
        expiresAt = try container.decode(String.self, forKey: .expiresAt)
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
