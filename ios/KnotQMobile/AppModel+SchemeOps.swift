import AuthenticationServices
import CryptoKit
import Foundation
import StoreKit
import SwiftUI
import UIKit

extension AppModel {
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
                scheduleEditSync()
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

    /// `completion` fires once the mutation's snapshot is installed — the point
    /// where `scheme(id:)` reflects this replace (the editor's live flush adopts
    /// core-minted item ids there; reading synchronously would see the old list).
    func replaceSchemeItems(
        schemeID: String,
        items: [MobileItemEdit],
        completion: (@MainActor () -> Void)? = nil
    ) {
        mutate({ try $0.replaceSchemeItems(schemeID: schemeID, items: items) }, completion: completion)
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
                scheduleEditSync()
            }
            return id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Items for a scheme id, searching active, archived, and daily schemes.
    nonisolated static func schemeItems(in snapshot: MobileSnapshot, id: String) -> [MobileItem] {
        if let s = snapshot.schemes.first(where: { $0.id == id }) { return s.items }
        if let s = snapshot.daily.first(where: { $0.scheme.id == id })?.scheme { return s.items }
        if let s = snapshot.archivedSchemes.first(where: { $0.id == id }) { return s.items }
        return []
    }

}
