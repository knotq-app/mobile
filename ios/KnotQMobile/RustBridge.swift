import Foundation

final class RustBridge: @unchecked Sendable {
    private let core: MobileCore

    // All core access funnels through this serial queue. The Rust core is one
    // big mutex, and sync_once holds it across network I/O — a snapshot or edit
    // issued from the main thread would otherwise block the UI for the whole
    // sync. Serial + FIFO also preserves the submission order of edits.
    private let queue = DispatchQueue(label: "com.knotq.rust-bridge", qos: .userInitiated)

    #if DEBUG
    /// Debug-only slow-motion for core work, in milliseconds, from
    /// `-KnotQSlowCoreWriteMillis <n>`.
    ///
    /// A write to a small document lands in about a millisecond, so the window
    /// where the model still holds the pre-write snapshot is far too short to
    /// hit from UI automation — which makes the staleness bugs it causes
    /// untestable from the outside even though a large workspace, a CRDT encode
    /// or a cold save widens the same window on a real device. Stretching it
    /// makes those bugs reproducible on demand.
    private static let slowCoreWork: TimeInterval = {
        let millis = UserDefaults.standard.integer(forKey: "KnotQSlowCoreWriteMillis")
        return millis > 0 ? TimeInterval(millis) / 1000 : 0
    }()
    #endif

    /// Run core work on the bridge queue and deliver the result on the main
    /// actor. Submission order is preserved (serial queue), so fire-and-forget
    /// mutations enqueued from the main thread apply in UI order.
    func enqueue<T: Sendable>(
        _ work: @escaping @Sendable (RustBridge) throws -> T,
        completion: @escaping @MainActor (Result<T, Error>) -> Void
    ) {
        queue.async {
            let result = Result { try work(self) }
            #if DEBUG
            // After the work, so the delay models a slow core rather than a
            // slow queue: the write itself has happened, only the completion
            // that publishes it to the UI is still pending.
            if Self.slowCoreWork > 0 {
                Thread.sleep(forTimeInterval: Self.slowCoreWork)
            }
            #endif
            Task { @MainActor in
                completion(result)
            }
        }
    }

    /// Awaitable variant of `enqueue` for callers that need the result inline.
    func perform<T: Sendable>(_ work: @escaping @Sendable (RustBridge) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work(self) })
            }
        }
    }

    init() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDir = support.appendingPathComponent("KnotQMobile", isDirectory: true)
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        core = try MobileCore(appDir: appDir.path)
    }

    func snapshot(today: String, weekOffset: Int, dailyHistoryDays: Int = 3) throws -> MobileSnapshot {
        try core.snapshotWithDailyHistory(
            today: today,
            weekOffset: Int32(weekOffset),
            dailyHistoryDays: Int32(dailyHistoryDays)
        )
    }

    func monthDays(year: Int, month: Int) throws -> [MobileCalendarDay] {
        try core.monthDays(year: Int32(year), month: UInt32(month))
    }

    func search(_ query: String) throws -> [MobileSearchHit] {
        try core.search(query: query)
    }

    func createFolder(name: String, parentID: String?) throws {
        try core.createFolder(parentId: parentID, name: name, position: nil)
    }

    func renameFolder(id: String, name: String) throws {
        try core.renameFolder(folderId: id, name: name)
    }

    func deleteFolder(id: String) throws {
        try core.deleteFolder(folderId: id)
    }

    func createScheme(name: String, folderID: String?, position: Int32?) throws {
        try core.createScheme(folderId: folderID, name: name, colorIndex: nil, position: position)
    }

    func renameScheme(id: String, name: String) throws {
        try core.renameScheme(schemeId: id, name: name)
    }

    func deleteScheme(id: String) throws {
        try core.deleteScheme(schemeId: id)
    }

    func restoreScheme(id: String) throws {
        try core.restoreScheme(schemeId: id)
    }

    func permanentlyDeleteScheme(id: String) throws {
        try core.permanentlyDeleteScheme(schemeId: id)
    }

    func restoreFolder(id: String) throws {
        try core.restoreFolder(folderId: id)
    }

    func permanentlyDeleteFolder(id: String) throws {
        try core.permanentlyDeleteFolder(folderId: id)
    }

    func emptyArchive() throws {
        try core.emptyArchive()
    }

    func setSchemeColor(id: String, colorIndex: Int32) throws {
        try core.setSchemeColor(schemeId: id, colorIndex: colorIndex)
    }

    func moveNode(kind: String, id: String, folderID: String, position: Int32) throws {
        try core.moveNode(kind: kind, id: id, folderId: folderID, position: position)
    }

    /// Returns whether the queue had to be created — see `ensureTodayDailyQueue`.
    @discardableResult
    func ensureDailyQueue(date: String) throws -> Bool {
        try core.ensureDailyQueue(date: date)
    }

    func addItem(schemeID: String, text: String, marker: Marker, indent: Int32) throws {
        try core.addItem(schemeId: schemeID, text: text, marker: marker.rawValue, position: nil, indent: indent)
    }

    func addTodayDailyItem(today: String, text: String, marker: Marker, indent: Int32) throws {
        try core.addTodayDailyItem(today: today, text: text, marker: marker.rawValue, indent: indent)
    }

    func updateItemText(schemeID: String, itemID: String, text: String) throws {
        try core.updateItemText(schemeId: schemeID, itemId: itemID, text: text)
    }

    func insertTable(schemeID: String, afterItemID: String?, itemID: String) throws {
        try core.insertTable(schemeId: schemeID, afterItemId: afterItemID, itemId: itemID)
    }

    func setTableCellText(schemeID: String, itemID: String, row: Int32, column: Int32, text: String) throws {
        try core.setTableCellText(schemeId: schemeID, itemId: itemID, row: row, column: column, text: text)
    }

    func setTableColumnName(schemeID: String, itemID: String, column: Int32, name: String) throws {
        try core.setTableColumnName(schemeId: schemeID, itemId: itemID, column: column, name: name)
    }

    func setTableCellLineText(schemeID: String, itemID: String, row: Int32, column: Int32, lineIndex: Int32, text: String) throws {
        try core.setTableCellLineText(schemeId: schemeID, itemId: itemID, row: row, column: column, lineIndex: lineIndex, text: text)
    }

    func addTableCellLine(schemeID: String, itemID: String, row: Int32, column: Int32, lineIndex: Int32, text: String) throws {
        try core.addTableCellLine(schemeId: schemeID, itemId: itemID, row: row, column: column, lineIndex: lineIndex, text: text)
    }

    func removeTableCellLine(schemeID: String, itemID: String, row: Int32, column: Int32, lineIndex: Int32) throws {
        try core.removeTableCellLine(schemeId: schemeID, itemId: itemID, row: row, column: column, lineIndex: lineIndex)
    }

    func insertTableRow(schemeID: String, itemID: String, row: Int32) throws {
        try core.insertTableRow(schemeId: schemeID, itemId: itemID, row: row)
    }

    func deleteTableRow(schemeID: String, itemID: String, row: Int32) throws {
        try core.deleteTableRow(schemeId: schemeID, itemId: itemID, row: row)
    }

    func insertTableColumn(schemeID: String, itemID: String, column: Int32) throws {
        try core.insertTableColumn(schemeId: schemeID, itemId: itemID, column: column)
    }

    func deleteTableColumn(schemeID: String, itemID: String, column: Int32) throws {
        try core.deleteTableColumn(schemeId: schemeID, itemId: itemID, column: column)
    }

    func setItemMarker(schemeID: String, itemID: String, marker: Marker) throws {
        try core.setItemMarker(schemeId: schemeID, itemId: itemID, marker: marker.rawValue)
    }

    func setItemIndent(schemeID: String, itemID: String, indent: Int32) throws {
        try core.setItemIndent(schemeId: schemeID, itemId: itemID, indent: indent)
    }

    func reorderItem(schemeID: String, from: Int, to: Int) throws {
        try core.reorderItem(schemeId: schemeID, from: Int32(from), to: Int32(to))
    }

    func replaceSchemeItems(schemeID: String, items: [MobileItemEdit]) throws {
        try core.replaceSchemeItems(schemeId: schemeID, items: items)
    }

    func setItemDate(schemeID: String, itemID: String, kind: String, date: String?) throws {
        try core.setItemDate(schemeId: schemeID, itemId: itemID, kind: kind, date: date)
    }

    func setItemRecurrence(schemeID: String, itemID: String, rrule: String?) throws {
        try core.setItemRecurrence(schemeId: schemeID, itemId: itemID, rrule: rrule)
    }

    func commitEventEdit(
        occurrence: MobileOccurrence,
        title: String,
        occurrenceStart: String?,
        occurrenceEnd: String?,
        start: String?,
        end: String?,
        rrule: String?,
        notificationOffsetSecs: Int32?,
        notificationDirty: Bool,
        done: Bool,
        scope: EventOccurrenceScope
    ) throws {
        try core.commitEventEdit(
            schemeId: occurrence.schemeId,
            itemId: occurrence.itemId,
            occurrenceJson: occurrence.occurrenceJson,
            occurrenceIndex: occurrence.occurrenceIndex,
            title: title,
            occurrenceStart: occurrenceStart,
            occurrenceEnd: occurrenceEnd,
            start: start,
            end: end,
            rrule: rrule,
            notificationOffsetSecs: notificationOffsetSecs,
            notificationDirty: notificationDirty,
            done: done,
            scope: scope.rawValue
        )
    }

    func setOccurrenceNotificationOffset(
        schemeID: String,
        itemID: String,
        occurrenceJSON: String?,
        offsetSecs: Int32?
    ) throws {
        try core.setOccurrenceNotificationOffset(
            schemeId: schemeID,
            itemId: itemID,
            occurrenceJson: occurrenceJSON,
            offsetSecs: offsetSecs
        )
    }

    func toggleItem(schemeID: String, itemID: String) throws {
        try core.toggleItem(schemeId: schemeID, itemId: itemID)
    }

    func toggleOccurrence(schemeID: String, itemID: String, occurrenceJSON: String) throws {
        try core.toggleOccurrence(schemeId: schemeID, itemId: itemID, occurrenceJson: occurrenceJSON)
    }

    func deleteItem(schemeID: String, itemID: String) throws {
        try core.deleteItem(schemeId: schemeID, itemId: itemID)
    }

    func moveItemToScheme(sourceSchemeID: String, targetSchemeID: String, itemID: String) throws {
        try core.moveItemToScheme(sourceSchemeId: sourceSchemeID, targetSchemeId: targetSchemeID, itemId: itemID)
    }

    func deleteEventOccurrence(_ occurrence: MobileOccurrence, scope: EventOccurrenceScope) throws {
        try core.deleteEventOccurrence(
            schemeId: occurrence.schemeId,
            itemId: occurrence.itemId,
            occurrenceJson: occurrence.occurrenceJson,
            occurrenceIndex: occurrence.occurrenceIndex,
            scope: scope.rawValue
        )
    }

    func addCalendarItem(kind: CalendarKind, text: String, date: String, start: String?, end: String?, schemeID: String?) throws {
        try core.addCalendarItem(schemeId: schemeID, date: date, text: text, kind: kind.rawValue, start: start, end: end)
    }

    func googleAuthRequest(clientID: String, redirectURI: String) throws -> MobileGoogleAuthRequest {
        try core.googleAuthRequest(clientId: clientID, redirectUri: redirectURI)
    }

    func completeGoogleCalendarImport(
        request: MobileGoogleAuthRequest,
        callbackURL: String,
        parentID: String?
    ) throws -> MobileGoogleSyncResult {
        try core.completeGoogleCalendarImport(
            clientId: request.clientId,
            redirectUri: request.redirectUri,
            state: request.state,
            codeVerifier: request.codeVerifier,
            callbackUrl: callbackURL,
            parentId: parentID
        )
    }

    func syncGoogleCalendars() throws -> MobileGoogleSyncResult {
        try core.syncGoogleCalendars()
    }

    func unlinkGoogleAccount(accountID: String) throws {
        try core.unlinkGoogleAccount(accountId: accountID)
    }

    func setThemeMode(_ mode: String) throws {
        try core.setThemeMode(themeMode: mode)
    }

    func setTimeFormat(_ format: String) throws {
        try core.setTimeFormat(timeFormat: format)
    }

    func setNotificationDefaults(eventOffsetSecs: Int32, assignmentOffsetSecs: Int32) throws {
        try core.setNotificationDefaults(
            eventOffsetSecs: eventOffsetSecs,
            assignmentOffsetSecs: assignmentOffsetSecs
        )
    }

    func setUpcomingDisplaySettings(
        eventLookaheadDays: Int32,
        reminderLookaheadDays: Int32,
        assignmentLookaheadDays: Int32,
        maximumItems: Int32,
        showOverdue: Bool,
        showCompleted: Bool
    ) throws {
        try core.setUpcomingDisplaySettings(
            eventLookaheadDays: eventLookaheadDays,
            reminderLookaheadDays: reminderLookaheadDays,
            assignmentLookaheadDays: assignmentLookaheadDays,
            maximumItems: maximumItems,
            showOverdue: showOverdue,
            showCompleted: showCompleted
        )
    }

    func resetWorkspace() throws {
        try core.resetWorkspace()
    }

    func pendingNotifications() throws -> [MobileNotificationRequest] {
        try core.pendingNotifications(now: nil, horizonDays: 14)
    }

    func deliveredNotificationsToClear() throws -> [String] {
        try core.deliveredNotificationsToClear(now: nil)
    }

    func applyNotificationAction(_ request: MobileNotificationActionRequest) throws -> Bool {
        try core.applyNotificationAction(
            actionId: request.actionID,
            schemeId: request.schemeID,
            itemId: request.itemID,
            occurrenceJson: request.occurrenceJSON,
            triggerAt: request.triggerAt
        )
    }

    func syncOnce(apiBase: String, bearerToken: String) throws -> Bool {
        try core.syncOnce(apiBase: apiBase, bearerToken: bearerToken)
    }

    func forceSyncOnce(apiBase: String, bearerToken: String) throws -> Bool {
        try core.forceSyncOnce(apiBase: apiBase, bearerToken: bearerToken)
    }

    func startWsSync(apiBase: String, bearerToken: String) throws {
        try core.startWsSync(apiBase: apiBase, bearerToken: bearerToken)
    }

    func stopWsSync() throws {
        try core.stopWsSync()
    }

    func wsPendingChanged() throws -> Bool {
        try core.wsPendingChanged()
    }

    func noteRemoteChanged() throws {
        try core.noteRemoteChanged()
    }

    func isWsConnected() throws -> Bool {
        try core.isWsConnected()
    }

    func setPushRegistration(token: String, environment: String) throws {
        try core.setPushRegistration(token: token, environment: environment)
    }

    func takeSyncNotice() throws -> String? {
        try core.takeSyncNotice()
    }

    func seedEditorImageFixture() throws {
        try core.seedEditorImageFixture()
    }
}
