import Foundation

final class RustBridge {
    private let core: MobileCore

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

    func snapshot(today: String, weekOffset: Int) throws -> MobileSnapshot {
        try core.snapshot(today: today, weekOffset: Int32(weekOffset))
    }

    func search(_ query: String) throws -> [MobileSearchHit] {
        try core.search(query: query)
    }

    func createFolder(name: String) throws {
        try core.createFolder(name: name, position: nil)
    }

    func renameFolder(id: String, name: String) throws {
        try core.renameFolder(folderId: id, name: name)
    }

    func deleteFolder(id: String) throws {
        try core.deleteFolder(folderId: id)
    }

    func createScheme(name: String, folderID: String?) throws {
        try core.createScheme(folderId: folderID, name: name, colorIndex: nil, position: nil)
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

    func emptyArchive() throws {
        try core.emptyArchive()
    }

    func setSchemeColor(id: String, colorIndex: Int32) throws {
        try core.setSchemeColor(schemeId: id, colorIndex: colorIndex)
    }

    func ensureDailyQueue(date: String) throws {
        try core.ensureDailyQueue(date: date)
    }

    func addItem(schemeID: String, text: String, marker: Marker, indent: Int32) throws {
        try core.addItem(schemeId: schemeID, text: text, marker: marker.rawValue, position: nil, indent: indent)
    }

    func updateItemText(schemeID: String, itemID: String, text: String) throws {
        try core.updateItemText(schemeId: schemeID, itemId: itemID, text: text)
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

    func toggleItem(schemeID: String, itemID: String) throws {
        try core.toggleItem(schemeId: schemeID, itemId: itemID)
    }

    func deleteItem(schemeID: String, itemID: String) throws {
        try core.deleteItem(schemeId: schemeID, itemId: itemID)
    }

    func addCalendarItem(kind: CalendarKind, text: String, date: String, start: String?, end: String?, schemeID: String?) throws {
        try core.addCalendarItem(schemeId: schemeID, date: date, text: text, kind: kind.rawValue, start: start, end: end)
    }

    func setThemeMode(_ mode: String) throws {
        try core.setThemeMode(themeMode: mode)
    }

    func setTimeFormat(_ format: String) throws {
        try core.setTimeFormat(timeFormat: format)
    }

    func resetWorkspace() throws {
        try core.resetWorkspace()
    }

    func seedEditorImageFixture() throws {
        try core.seedEditorImageFixture()
    }
}
