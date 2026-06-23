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
    @Published private(set) var dailyHistoryLoadAnchorDate: String?
    @Published private(set) var dailyHistoryLoadInProgress = false

    // App Store Connect product id(s) for the sync subscription.
    static let syncProductIDs: Set<String> = ["com.enigmadux.knotq.sync.monthly"]
    private static let minimumDailyHistoryDays = 3
    /// Days of daily history loaded on first open. Kept small — most sessions
    /// only touch the last few days — so the initial snapshot builds fast; older
    /// days page in (a month at a time) as the feed scrolls up.
    private static let initialDailyHistoryWindowDays = 7
    private static let dailyHistoryPageDays = 31
    private static let maxDailyHistoryDays = 3650
    private static let foregroundGoogleSyncIntervalNanos: UInt64 = 120_000_000_000
    private static let backgroundGoogleSyncInterval: TimeInterval = 6 * 60 * 60

    private let bridge: RustBridge?
    private let iso = ISO8601DateFormatter()
    private let syncSessionKey = "knotq.localSyncSession"
    private let backgroundGoogleSyncKey = "knotq.lastBackgroundGoogleSyncAt"
    private var syncPollTask: Task<Void, Never>?
    private var googleSyncTask: Task<Void, Never>?
    private var resendCooldownTask: Task<Void, Never>?
    private var googleOAuthSession: WebAuthenticationSessionCoordinator?
    private var browserSignInSession: WebAuthenticationSessionCoordinator?
    private var transactionListener: Task<Void, Never>?
    private var dailyHistoryDays = AppModel.initialDailyHistoryDays(for: Date())
    private var pendingDailyHistoryLoadAnchorDate: String?

    init() {
        bridge = try? RustBridge()
        iso.formatOptions = [.withInternetDateTime]
        syncSession = Self.loadSyncSession(key: syncSessionKey)
        if bridge == nil {
            errorMessage = "Rust core failed to initialize"
        }
        MobileNotificationScheduler.shared.configure(model: self)
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
        startSyncPolling()
        startTransactionListener()
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
                try b.pendingNotifications()
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
            case .success(let (snapshot, pending)):
                self.apply(snapshot: snapshot, pendingNotifications: pending)
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
    /// the main actor with data produced on the bridge queue.
    private func apply(snapshot: MobileSnapshot, pendingNotifications: [MobileNotificationRequest]) {
        self.snapshot = snapshot
        KnotQWidgetSnapshotStore.publish(snapshot: snapshot)
        MobileNotificationScheduler.shared.reschedule(pendingNotifications)
        MobileNotificationScheduler.shared.updateBadgeCount(Self.overdueBadgeCount(for: snapshot))
        configureGoogleSyncPolling(accountCount: snapshot.settings.googleAccountCount)
        BackgroundSyncCoordinator.shared.scheduleIfEligible(backgroundRefreshEligible)
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
        guard let snapshot = try? await bridge.perform({ try $0.snapshot(today: today, weekOffset: week) })
        else {
            return
        }
        MobileNotificationScheduler.shared.updateBadgeCount(Self.overdueBadgeCount(for: snapshot))
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
    func createScheme(name: String, folderID: String? = nil, position: Int32? = 0) async -> String? {
        guard let bridge else { return nil }
        let today = Self.dateOnly(selectedDate)
        let week = weekOffset
        let history = dailyHistoryDays
        do {
            let (id, after, pending) = try await bridge.perform { b in
                let before = Set(try b.snapshot(
                    today: today,
                    weekOffset: week,
                    dailyHistoryDays: history
                ).schemes.map(\.id))
                try b.createScheme(name: name, folderID: folderID, position: position)
                let after = try b.snapshot(
                    today: today,
                    weekOffset: week,
                    dailyHistoryDays: history
                )
                let id = after.schemes.first { !before.contains($0.id) && $0.name == name }?.id
                    ?? after.schemes.first { !before.contains($0.id) }?.id
                return (id, after, try b.pendingNotifications())
            }
            apply(snapshot: after, pendingNotifications: pending)
            errorMessage = nil
            if syncSession != nil {
                scheduleSync()
            }
            return id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
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

    func restoreFolder(id: String) {
        mutate { try $0.restoreFolder(id: id) }
    }

    func permanentlyDeleteFolder(id: String) {
        mutate { try $0.permanentlyDeleteFolder(id: id) }
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
        let key = Self.dateOnly(date)
        mutate { try $0.ensureDailyQueue(date: key) }
    }

    func ensureTodayDailyQueue() {
        let key = Self.dateOnly(Date())
        mutate { try $0.ensureDailyQueue(date: key) }
    }

    func selectDate(_ date: Date) {
        selectedDate = date
        dailyHistoryDays = Self.initialDailyHistoryDays(for: date)
        pendingDailyHistoryLoadAnchorDate = nil
        dailyHistoryLoadAnchorDate = nil
        dailyHistoryLoadInProgress = false
        refresh()
    }

    func addItem(schemeID: String, text: String, marker: Marker = .checkbox, indent: Int32 = 0) {
        mutate { try $0.addItem(schemeID: schemeID, text: text, marker: marker, indent: indent) }
    }

    func addTodayDailyItem(text: String, marker: Marker = .checkbox, indent: Int32 = 0) {
        selectedDate = Date()
        let today = Self.dateOnly(Date())
        mutate {
            try $0.addTodayDailyItem(
                today: today,
                text: text,
                marker: marker,
                indent: indent
            )
        }
    }

    func updateItemText(schemeID: String, itemID: String, text: String) {
        mutate { try $0.updateItemText(schemeID: schemeID, itemID: itemID, text: text) }
    }

    func insertTable(schemeID: String, afterItemID: String?, itemID: String) {
        mutate { try $0.insertTable(schemeID: schemeID, afterItemID: afterItemID, itemID: itemID) }
    }

    func setTableCellText(schemeID: String, itemID: String, row: Int32, column: Int32, text: String) {
        mutate {
            try $0.setTableCellText(
                schemeID: schemeID,
                itemID: itemID,
                row: row,
                column: column,
                text: text
            )
        }
    }

    func setTableColumnName(schemeID: String, itemID: String, column: Int32, name: String) {
        mutate {
            try $0.setTableColumnName(
                schemeID: schemeID,
                itemID: itemID,
                column: column,
                name: name
            )
        }
    }

    func setTableCellLineText(schemeID: String, itemID: String, row: Int32, column: Int32, lineIndex: Int32, text: String) {
        mutate {
            try $0.setTableCellLineText(
                schemeID: schemeID,
                itemID: itemID,
                row: row,
                column: column,
                lineIndex: lineIndex,
                text: text
            )
        }
    }

    func addTableCellLine(schemeID: String, itemID: String, row: Int32, column: Int32, lineIndex: Int32, text: String) {
        mutate {
            try $0.addTableCellLine(
                schemeID: schemeID,
                itemID: itemID,
                row: row,
                column: column,
                lineIndex: lineIndex,
                text: text
            )
        }
    }

    func removeTableCellLine(schemeID: String, itemID: String, row: Int32, column: Int32, lineIndex: Int32) {
        mutate {
            try $0.removeTableCellLine(
                schemeID: schemeID,
                itemID: itemID,
                row: row,
                column: column,
                lineIndex: lineIndex
            )
        }
    }

    func insertTableRow(schemeID: String, itemID: String, row: Int32) {
        mutate { try $0.insertTableRow(schemeID: schemeID, itemID: itemID, row: row) }
    }

    func deleteTableRow(schemeID: String, itemID: String, row: Int32) {
        mutate { try $0.deleteTableRow(schemeID: schemeID, itemID: itemID, row: row) }
    }

    func insertTableColumn(schemeID: String, itemID: String, column: Int32) {
        mutate { try $0.insertTableColumn(schemeID: schemeID, itemID: itemID, column: column) }
    }

    func deleteTableColumn(schemeID: String, itemID: String, column: Int32) {
        mutate { try $0.deleteTableColumn(schemeID: schemeID, itemID: itemID, column: column) }
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
        let dateString = date.map { iso.string(from: $0) }
        mutate {
            try $0.setItemDate(
                schemeID: schemeID,
                itemID: itemID,
                kind: kind,
                date: dateString
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
        let startString = start.map { iso.string(from: $0) }
        let endString = end.map { iso.string(from: $0) }
        mutate {
            try $0.commitEventEdit(
                occurrence: occurrence,
                title: title,
                occurrenceStart: occurrence.start,
                occurrenceEnd: occurrence.end,
                start: startString,
                end: endString,
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
        // Retention (keeping a just-completed item on the upcoming panel) is
        // handled in the core, so the snapshot already includes it.
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

    /// Transfer an item to another scheme, preserving its identity and
    /// attributes (the mobile equivalent of the desktop event popup's scheme
    /// switch). A no-op when source and target match.
    func moveItemToScheme(sourceSchemeID: String, targetSchemeID: String, itemID: String) {
        guard sourceSchemeID != targetSchemeID else { return }
        mutate {
            try $0.moveItemToScheme(
                sourceSchemeID: sourceSchemeID,
                targetSchemeID: targetSchemeID,
                itemID: itemID
            )
        }
    }

    func deleteEventOccurrence(_ occurrence: MobileOccurrence, scope: EventOccurrenceScope) {
        mutate { try $0.deleteEventOccurrence(occurrence, scope: scope) }
    }

    func addCalendarItem(kind: CalendarKind, text: String, date: Date, start: Date?, end: Date?, schemeID: String? = nil) {
        let dateKey = Self.dateOnly(date)
        let startString = start.map { iso.string(from: $0) }
        let endString = end.map { iso.string(from: $0) }
        mutate {
            try $0.addCalendarItem(
                kind: kind,
                text: text,
                date: dateKey,
                start: startString,
                end: endString,
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
    ) async -> String? {
        guard let bridge else { return nil }
        let snapshotKey = Self.dateOnly(selectedDate)
        let week = weekOffset
        let history = dailyHistoryDays
        let todayKey = Self.dateOnly(Date())
        let dateKey = Self.dateOnly(date)
        let startString = start.map { iso.string(from: $0) }
        let endString = end.map { iso.string(from: $0) }
        do {
            let (id, after, pending) = try await bridge.perform { b in
                // Resolve nil schemes to today's daily queue, then diff that
                // scheme's items to recover the new item's id.
                var targetID = schemeID
                if targetID == nil {
                    try b.ensureDailyQueue(date: todayKey)
                    let current = try b.snapshot(
                        today: snapshotKey,
                        weekOffset: week,
                        dailyHistoryDays: history
                    )
                    targetID = current.daily.first { $0.date == todayKey }?.scheme.id
                }
                var before: Set<String> = []
                if let targetID {
                    let current = try b.snapshot(
                        today: snapshotKey,
                        weekOffset: week,
                        dailyHistoryDays: history
                    )
                    before = Set(Self.schemeItems(in: current, id: targetID).map(\.id))
                }
                try b.addCalendarItem(
                    kind: kind,
                    text: text,
                    date: dateKey,
                    start: startString,
                    end: endString,
                    schemeID: targetID
                )
                let after = try b.snapshot(
                    today: snapshotKey,
                    weekOffset: week,
                    dailyHistoryDays: history
                )
                let id = targetID.flatMap { target in
                    Self.schemeItems(in: after, id: target).first { !before.contains($0.id) }?.id
                }
                return (id, after, try b.pendingNotifications())
            }
            apply(snapshot: after, pendingNotifications: pending)
            errorMessage = nil
            if syncSession != nil {
                scheduleSync()
            }
            return id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Items for a scheme id, searching active, archived, and daily schemes.
    private nonisolated static func schemeItems(in snapshot: MobileSnapshot, id: String) -> [MobileItem] {
        if let s = snapshot.schemes.first(where: { $0.id == id }) { return s.items }
        if let s = snapshot.daily.first(where: { $0.scheme.id == id })?.scheme { return s.items }
        if let s = snapshot.archivedSchemes.first(where: { $0.id == id }) { return s.items }
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
            let clientID = config.clientID
            let redirectURI = config.redirectURI
            let request = try await bridge.perform { try $0.googleAuthRequest(clientID: clientID, redirectURI: redirectURI) }
            guard let authURL = URL(string: request.authUrl) else {
                throw GoogleOAuthConfigError.message("Google returned an invalid authorization URL.")
            }

            let session = WebAuthenticationSessionCoordinator()
            googleOAuthSession = session
            let callbackURL = try await session.authenticate(url: authURL, callbackScheme: config.redirectScheme)
            let callback = callbackURL.absoluteString
            let result = try await bridge.perform { b in
                try b.completeGoogleCalendarImport(
                    request: request,
                    callbackURL: callback,
                    parentID: parentID
                )
            }
            googleCalendarStatus = result.message
            refresh()
            if syncSession != nil {
                scheduleSync()
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
            let result = try await bridge.perform { try $0.syncGoogleCalendars() }
            googleCalendarStatus = result.message
            refresh()
            if syncSession != nil {
                scheduleSync()
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

    func unlinkGoogleCalendarAccount(_ account: MobileGoogleAccount) {
        mutate { try $0.unlinkGoogleAccount(accountID: account.id) }
    }

    private static let prodWebBase = "https://www.knotq.com"
    private static let sandboxWebBase = "https://sandbox.knotq.com"
    // The knotq.com site origin matching a sync API base, so a sandbox/local-dev
    // build opens the sandbox site instead of production. The sign-in page also
    // receives the API base via the allowlisted `?api=` param, which is what
    // actually pins the backend (needed for local, where the site is the sandbox
    // host but the API is the loopback Worker).
    private static func webBase(forApiBase apiBase: String) -> String {
        if apiBase.contains("sandbox.api.knotq.com")
            || apiBase.contains("127.0.0.1")
            || apiBase.contains("localhost") {
            return sandboxWebBase
        }
        return prodWebBase
    }
    private static let signInRedirectScheme = "knotq"
    private static let signInRedirectURI = "knotq://auth-callback"
    // Base URL used for a *new* sign-in when no session is stored yet. A
    // `KNOTQ_API_BASE` override (set it in the Xcode Run scheme's environment)
    // always wins; otherwise the default is build-aware — Debug builds target the
    // hosted sandbox (https://sandbox.api.knotq.com) so development never touches
    // production, while Release (App Store) builds target production. Existing
    // sessions keep their stored apiBase, so this never silently moves a signed-in
    // account between environments.
    private static var defaultSyncApiBase: String {
        if let override = ProcessInfo.processInfo.environment["KNOTQ_API_BASE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        #if DEBUG
        return "https://sandbox.api.knotq.com"
        #else
        return "https://api.knotq.com"
        #endif
    }

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

    private func startResendCooldown(_ seconds: Int = 60) {
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

    private func handle(transactionResult: VerificationResult<StoreKit.Transaction>) async {
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
        syncOffline = false
        saveSyncSession(updated)
        BackgroundSyncCoordinator.shared.scheduleIfEligible(backgroundRefreshEligible)
        if updated.supportsSync {
            scheduleSync()
        }
    }

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

    private func scheduleSync() {
        guard syncSession != nil else { return }
        Task { await self.syncOnce() }
    }

    private func refreshSyncSessionForAccountAction() async -> Bool {
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
    private func refreshSyncSessionIfNeeded(force: Bool = false) async -> SyncSessionRefreshResult {
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
            let (data, response) = try await URLSession.shared.data(for: request)
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

    private static func isLikelyNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return true
        }
        let message = error.localizedDescription.lowercased()
        return ["network", "request failed", "offline", "timed out", "cannot connect", "not connected"].contains { message.contains($0) }
    }

    private static func isTerminalRefreshError(_ data: Data) -> Bool {
        guard
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let code = body["code"] as? String
        else {
            return false
        }
        return terminalRefreshErrorCodes.contains(code)
    }

    private static let terminalRefreshErrorCodes: Set<String> = [
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
    private func mutate(_ action: @escaping @Sendable (RustBridge) throws -> Void) {
        guard let bridge else { return }
        let today = Self.dateOnly(selectedDate)
        let week = weekOffset
        let history = dailyHistoryDays
        bridge.enqueue({ b in
            try action(b)
            return (
                try b.snapshot(today: today, weekOffset: week, dailyHistoryDays: history),
                try b.pendingNotifications()
            )
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let (snapshot, pending)):
                self.apply(snapshot: snapshot, pendingNotifications: pending)
                self.errorMessage = nil
                if self.syncSession != nil {
                    self.scheduleSync()
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

    private func rescheduleNotifications() {
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

    private func startSyncPolling() {
        syncPollTask?.cancel()
        guard syncSession != nil else { return }
        syncPollTask = Task { [weak self] in
            // Pick up an entitlement change (a subscription bought on another device
            // or the web) on launch/sign-in before the first sync, so it shows up
            // without waiting for the access token to expire.
            await self?.refreshSubscriptionStatus()
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
        case "password_required":
            return "Enter your current password."
        case "password_too_long":
            return "That password is too long."
        case "invalid_credentials":
            return "That password is incorrect."
        case "billing_api_not_configured":
            return "Subscription cancellation is not configured yet."
        case "cancel_in_app_store":
            return "Manage this App Store subscription from your Apple account subscriptions."
        case "cancel_in_play_store":
            return "Manage this subscription from your Google Play account subscriptions."
        case "resume_in_app_store":
            return "Re-enable this subscription from your Apple account subscriptions."
        case "resume_in_play_store":
            return "Re-enable this subscription from your Google Play account subscriptions."
        case "no_active_subscription":
            return "There's no active paid subscription on this account to change."
        case "invalid_code":
            return "That code is incorrect."
        case "code_expired", "invalid_or_expired_code":
            return "That code has expired. Start the deletion again to get a new one."
        case "too_many_attempts":
            return "Too many incorrect codes. Start the deletion again to get a new one."
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
            redirectScheme: redirectScheme,
            redirectURI: redirectURI
        )
    }

    private static func configuredGoogleClientID() -> String? {
        googleConfigString(infoKey: "KnotQGoogleClientID", envKeys: ["KNOTQ_GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_ID"])
            ?? bundledGoogleServiceValue("CLIENT_ID")
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
    static var screenshotFixtureRequested: Bool {
        #if targetEnvironment(simulator)
        let process = ProcessInfo.processInfo
        return process.arguments.contains("--knotq-screenshot-fixture")
            || process.environment["KNOTQ_SCREENSHOT_FIXTURE"] == "1"
        #else
        return false
        #endif
    }

    @discardableResult
    private func seedScreenshotFixtureIfRequested() -> Bool {
        guard Self.screenshotFixtureRequested, let bridge else { return false }

        do {
            syncSession = nil
            UserDefaults.standard.removeObject(forKey: syncSessionKey)
            UserDefaults.standard.set(true, forKey: "knotq.mobile.onboardingCompleted.v1")

            selectedDate = Date()
            weekOffset = 0

            try bridge.resetWorkspace()
            try bridge.setThemeMode("dark")
            try bridge.setTimeFormat("twelve_hour")
            try bridge.setNotificationDefaults(
                eventOffsetSecs: 10 * 60,
                assignmentOffsetSecs: 2 * 60 * 60
            )

            let launchID = try renameOrCreateScreenshotScheme(
                bridge: bridge,
                currentNames: ["Start Here", "Example Plan", "Coursework"],
                targetName: "Semester Plan",
                colorIndex: 4
            )
            let scheduleID = try renameOrCreateScreenshotScheme(
                bridge: bridge,
                currentNames: ["Scheduling"],
                targetName: "Schedule",
                colorIndex: 5
            )
            let roadmapID = try renameOrCreateScreenshotScheme(
                bridge: bridge,
                currentNames: ["Projects"],
                targetName: "Research Project",
                colorIndex: 2
            )
            let classesID = try createScreenshotScheme(bridge: bridge, name: "Classes", colorIndex: 3)
            let fitnessID = try createScreenshotScheme(bridge: bridge, name: "Fitness", colorIndex: 0)
            let musicID = try createScreenshotScheme(bridge: bridge, name: "Music", colorIndex: 5)
            let lifeID = try createScreenshotScheme(bridge: bridge, name: "Life Admin", colorIndex: 9)
            let financeID = try createScreenshotScheme(bridge: bridge, name: "Finances", colorIndex: 7)

            try bridge.replaceSchemeItems(schemeID: launchID, items: launchPlanItems())
            try bridge.replaceSchemeItems(schemeID: scheduleID, items: scheduleItems())
            try bridge.replaceSchemeItems(schemeID: roadmapID, items: roadmapItems())
            try bridge.replaceSchemeItems(schemeID: classesID, items: classesItems())
            try bridge.replaceSchemeItems(schemeID: fitnessID, items: fitnessItems())
            try bridge.replaceSchemeItems(schemeID: musicID, items: musicItems())
            try bridge.replaceSchemeItems(schemeID: lifeID, items: lifeAdminItems())
            try bridge.replaceSchemeItems(schemeID: financeID, items: financeItems())
            try seedDailyScreenshotItems(bridge: bridge)

            snapshot = try bridge.snapshot(today: Self.dateOnly(selectedDate), weekOffset: weekOffset)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }

        return true
    }

    private func renameOrCreateScreenshotScheme(
        bridge: RustBridge,
        currentNames: [String],
        targetName: String,
        colorIndex: Int32
    ) throws -> String {
        let snapshot = try bridge.snapshot(today: Self.dateOnly(selectedDate), weekOffset: weekOffset)
        if let existing = snapshot.schemes.first(where: { currentNames.contains($0.name) || $0.name == targetName }) {
            if existing.name != targetName {
                try bridge.renameScheme(id: existing.id, name: targetName)
            }
            try bridge.setSchemeColor(id: existing.id, colorIndex: colorIndex)
            return existing.id
        }
        return try createScreenshotScheme(bridge: bridge, name: targetName, colorIndex: colorIndex)
    }

    private func createScreenshotScheme(bridge: RustBridge, name: String, colorIndex: Int32) throws -> String {
        let before = Set(try bridge.snapshot(today: Self.dateOnly(selectedDate), weekOffset: weekOffset).schemes.map(\.id))
        try bridge.createScheme(name: name, folderID: nil, position: nil)
        let snapshot = try bridge.snapshot(today: Self.dateOnly(selectedDate), weekOffset: weekOffset)
        guard let scheme = snapshot.schemes.first(where: { !before.contains($0.id) && $0.name == name })
            ?? snapshot.schemes.first(where: { $0.name == name }) else {
            throw ScreenshotFixtureError.message("Could not create screenshot scheme \(name).")
        }
        try bridge.setSchemeColor(id: scheme.id, colorIndex: colorIndex)
        return scheme.id
    }

    private func seedDailyScreenshotItems(bridge: RustBridge) throws {
        let todayKey = Self.dateOnly(selectedDate)
        try bridge.ensureDailyQueue(date: todayKey)
        let snapshot = try bridge.snapshot(today: todayKey, weekOffset: weekOffset)
        guard let dailyID = snapshot.daily.first(where: { $0.date == todayKey })?.scheme.id else {
            throw ScreenshotFixtureError.message("Could not prepare today's daily queue.")
        }
        try bridge.replaceSchemeItems(schemeID: dailyID, items: [
            screenshotItem("Today", marker: .blank),
            screenshotItem("Review lecture notes", marker: .checkbox, done: true),
            screenshotItem("Finish calculus questions", marker: .checkbox),
            screenshotItem("Email lab partner", marker: .checkbox),
            screenshotItem("Pack books for tutoring", marker: .checkbox),
            screenshotItem("Draft history thesis paragraph", marker: .checkbox, end: screenshotDate(dayOffset: 0, hour: 21, minute: 15)),
            screenshotItem("Inbox", marker: .blank),
            screenshotItem("Check scholarship portal", marker: .checkbox),
            screenshotItem("Text study group", marker: .checkbox),
            screenshotItem("Loose notes", marker: .blank),
            screenshotItem("Bring blue notebook to art history", marker: .bullet, indent: 1),
        ])
    }

    private func launchPlanItems() -> [MobileItemEdit] {
        [
            screenshotItem("Spring semester", marker: .blank),
            screenshotItem("Coursework", marker: .bullet),
            screenshotItem("Read philosophy chapter 8", marker: .checkbox, indent: 1, done: true),
            screenshotItem("Outline art history essay", marker: .checkbox, indent: 1),
            screenshotItem("Prepare stats lab questions", marker: .checkbox, indent: 1, end: screenshotDate(dayOffset: 1, hour: 16, minute: 30)),
            screenshotItem("Campus", marker: .bullet),
            screenshotItem("Reserve library study room", marker: .checkbox, indent: 1, done: true),
            screenshotItem("Meet writing tutor", marker: .checkbox, indent: 1),
            screenshotItem("Print music theory worksheet", marker: .checkbox, indent: 1),
            screenshotItem("Submit financial aid form", marker: .checkbox, indent: 1),
            screenshotItem("Exam prep", marker: .bullet),
            screenshotItem("Make flashcards for psychology", marker: .checkbox, indent: 1),
            screenshotItem("Archive last week's notes", marker: .checkbox, indent: 1),
        ]
    }

    private func scheduleItems() -> [MobileItemEdit] {
        [
            screenshotItem("Calendar blocks", marker: .blank),
            screenshotItem("Morning review", marker: .checkbox, done: true, start: screenshotDate(dayOffset: 0, hour: 11, minute: 15), end: screenshotDate(dayOffset: 0, hour: 11, minute: 45)),
            screenshotItem("Library study block", marker: .checkbox, done: true),
            screenshotItem("Essay drafting", marker: .checkbox, done: true),
            screenshotItem("Group project meeting", marker: .checkbox, start: screenshotDate(dayOffset: 1, hour: 12, minute: 30), end: screenshotDate(dayOffset: 1, hour: 13, minute: 15)),
            screenshotItem("Office hours", marker: .checkbox),
            screenshotItem("Weekly planning", marker: .checkbox),
        ]
    }

    private func roadmapItems() -> [MobileItemEdit] {
        [
            screenshotItem("History research paper", marker: .blank),
            screenshotItem("Find five primary sources", marker: .checkbox, done: true),
            screenshotItem("Annotate museum catalog", marker: .checkbox),
            screenshotItem("Send thesis to professor", marker: .checkbox, end: screenshotDate(dayOffset: 2, hour: 12, minute: 0)),
            screenshotItem("Draft sections", marker: .blank),
            screenshotItem("Write intro paragraph", marker: .checkbox),
            screenshotItem("Revise source notes", marker: .checkbox),
        ]
    }

    private func classesItems() -> [MobileItemEdit] {
        [
            screenshotItem("Coursework", marker: .blank),
            screenshotItem("Calculus problem set", marker: .checkbox, done: true),
            screenshotItem("Art History critique", marker: .checkbox, end: screenshotDate(dayOffset: 1, hour: 22, minute: 0)),
            screenshotItem("Psych reading response Ch. 7", marker: .checkbox, end: screenshotDate(dayOffset: 1, hour: 23, minute: 0)),
            screenshotItem("Stats problem set 8", marker: .checkbox),
            screenshotItem("Creative writing portfolio", marker: .checkbox),
            screenshotItem("Seminars", marker: .blank),
            screenshotItem("Chemistry lecture", marker: .checkbox, done: true, start: screenshotDate(dayOffset: 0, hour: 12, minute: 0), end: screenshotDate(dayOffset: 0, hour: 12, minute: 50)),
            screenshotItem("Art History seminar", marker: .checkbox, start: screenshotDate(dayOffset: 1, hour: 11, minute: 15), end: screenshotDate(dayOffset: 1, hour: 12, minute: 0)),
            screenshotItem("Stats lab", marker: .checkbox, start: screenshotDate(dayOffset: 3, hour: 14, minute: 0), end: screenshotDate(dayOffset: 3, hour: 15, minute: 15)),
        ]
    }

    private func fitnessItems() -> [MobileItemEdit] {
        [
            screenshotItem("Training", marker: .blank),
            screenshotItem("Club run", marker: .checkbox, start: screenshotDate(dayOffset: 1, hour: 15, minute: 15), end: screenshotDate(dayOffset: 1, hour: 16, minute: 0)),
            screenshotItem("Gym: upper body", marker: .checkbox, start: screenshotDate(dayOffset: 2, hour: 8, minute: 0), end: screenshotDate(dayOffset: 2, hour: 9, minute: 0)),
            screenshotItem("Yoga class", marker: .checkbox),
            screenshotItem("Pack running shoes", marker: .checkbox, done: true),
        ]
    }

    private func musicItems() -> [MobileItemEdit] {
        [
            screenshotItem("Practice", marker: .blank),
            screenshotItem("Piano practice", marker: .checkbox, done: true),
            screenshotItem("Band rehearsal", marker: .checkbox, start: screenshotDate(dayOffset: 2, hour: 14, minute: 0), end: screenshotDate(dayOffset: 2, hour: 15, minute: 30)),
            screenshotItem("Theory analysis", marker: .checkbox),
        ]
    }

    private func lifeAdminItems() -> [MobileItemEdit] {
        [
            screenshotItem("Errands", marker: .blank),
            screenshotItem("Pick up groceries", marker: .checkbox, start: screenshotDate(dayOffset: 4, hour: 17, minute: 0)),
            screenshotItem("Call Maya", marker: .checkbox),
            screenshotItem("Renew library books", marker: .checkbox),
            screenshotItem("Movie night", marker: .checkbox),
        ]
    }

    private func financeItems() -> [MobileItemEdit] {
        [
            screenshotItem("Monthly", marker: .blank),
            screenshotItem("Rent due", marker: .checkbox, end: screenshotDate(dayOffset: 6, hour: 9, minute: 0)),
            screenshotItem("Reconcile subscriptions", marker: .checkbox),
            screenshotItem("Update budget notes", marker: .checkbox),
        ]
    }

    private func screenshotItem(
        _ text: String,
        marker: Marker,
        indent: Int32 = 0,
        done: Bool = false,
        start: Date? = nil,
        end: Date? = nil,
        notificationOffsetSecs: Int32? = nil,
        repeatRule: String? = nil
    ) -> MobileItemEdit {
        MobileItemEdit(
            id: nil,
            text: text,
            marker: marker.rawValue,
            indent: indent,
            done: done,
            start: start.map { iso.string(from: $0) },
            end: end.map { iso.string(from: $0) },
            notificationOffsetSecs: notificationOffsetSecs,
            repeatRule: repeatRule,
            media: [],
            content: []
        )
    }

    private func screenshotDate(dayOffset: Int, hour: Int, minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let base = calendar.startOfDay(for: selectedDate)
        let day = calendar.date(byAdding: .day, value: dayOffset, to: base) ?? base
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

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

    private static func initialDailyHistoryDays(for date: Date) -> Int {
        // Open on just the last few days so the first snapshot is cheap; the feed
        // pages in older days on scroll. (Was: the whole previous month → today,
        // which loaded dozens of daily queues up front.)
        min(max(initialDailyHistoryWindowDays, minimumDailyHistoryDays), maxDailyHistoryDays)
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

#if DEBUG
private enum ScreenshotFixtureError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}
#endif

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

/// The subset of /v1/auth/account/status the app needs to reflect a cancelled
/// subscription. `subscription_state` is optional so older backends still decode.
private struct AccountStatusPayload: Decodable {
    let supportsSync: Bool
    let subscriptionState: String?
    let subscriptionProvider: String?
    // Fail closed: a response that omits the field decodes as unverified rather than
    // silently allowing checkout. The current backend always sends it.
    let emailVerified: Bool

    enum CodingKeys: String, CodingKey {
        case supportsSync = "supports_sync"
        case subscriptionState = "subscription_state"
        case subscriptionProvider = "subscription_provider"
        case emailVerified = "email_verified"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        supportsSync = try container.decodeIfPresent(Bool.self, forKey: .supportsSync) ?? true
        subscriptionState = try container.decodeIfPresent(String.self, forKey: .subscriptionState)
        subscriptionProvider = try container.decodeIfPresent(String.self, forKey: .subscriptionProvider)
        emailVerified = try container.decodeIfPresent(Bool.self, forKey: .emailVerified) ?? false
    }
}

private struct DeleteAccountResponse: Decodable {
    let deletionScheduled: Bool
    let purgeAfter: String?

    enum CodingKeys: String, CodingKey {
        case deletionScheduled = "deletion_scheduled"
        case purgeAfter = "purge_after"
    }
}

// A pending one-time-code challenge (e.g. account-deletion confirmation).
private struct ChallengeResponse: Decodable {
    let challengeId: String

    enum CodingKeys: String, CodingKey {
        case challengeId = "challenge_id"
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

private enum SyncSessionRefreshResult: Equatable {
    case ready
    case deferred
    case sessionDead
}

private struct GoogleOAuthMobileConfig {
    let clientID: String
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
