import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot: MobileSnapshot?
    @Published var searchHits: [MobileSearchHit] = []
    @Published var errorMessage: String?
    @Published var selectedDate = Date()
    @Published var weekOffset = 0

    private let bridge: RustBridge?
    private let iso = ISO8601DateFormatter()

    init() {
        bridge = try? RustBridge()
        iso.formatOptions = [.withInternetDateTime]
        if bridge == nil {
            errorMessage = "Rust core failed to initialize"
        }
        refresh()
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

    func createFolder(name: String) {
        mutate { try $0.createFolder(name: name) }
    }

    func renameFolder(id: String, name: String) {
        mutate { try $0.renameFolder(id: id, name: name) }
    }

    func deleteFolder(id: String) {
        mutate { try $0.deleteFolder(id: id) }
    }

    @discardableResult
    func createScheme(name: String, folderID: String? = nil) -> String? {
        let before = Set(snapshot?.schemes.map(\.id) ?? [])
        mutate { try $0.createScheme(name: name, folderID: folderID) }
        return snapshot?.schemes.first { !before.contains($0.id) && $0.name == name }?.id
            ?? snapshot?.schemes.first { !before.contains($0.id) }?.id
    }

    func renameScheme(id: String, name: String) {
        mutate { try $0.renameScheme(id: id, name: name) }
    }

    func deleteScheme(id: String) {
        mutate { try $0.deleteScheme(id: id) }
    }

    func setSchemeColor(id: String, colorIndex: Int32) {
        mutate { try $0.setSchemeColor(id: id, colorIndex: colorIndex) }
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

    func toggleItem(schemeID: String, itemID: String) {
        mutate { try $0.toggleItem(schemeID: schemeID, itemID: itemID) }
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

    func setThemeMode(_ mode: String) {
        mutate { try $0.setThemeMode(mode) }
    }

    func setTimeFormat(_ format: String) {
        mutate { try $0.setTimeFormat(format) }
    }

    func resetWorkspace() {
        mutate { try $0.resetWorkspace() }
    }

    func scheme(id: String?) -> MobileScheme? {
        guard let id else { return nil }
        return snapshot?.schemes.first { $0.id == id }
    }

    private func mutate(_ action: (RustBridge) throws -> Void) {
        guard let bridge else { return }
        do {
            try action(bridge)
            refresh()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
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
