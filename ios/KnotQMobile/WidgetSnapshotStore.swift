import Foundation

let knotQWidgetKind = "KnotQUpcomingWidget"
let knotQWidgetAppGroup = "group.com.enigmadux.knotq"

struct KnotQWidgetOccurrence: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var schemeName: String
    var kind: String
    var start: String?
    var end: String?
    var colorIndex: Int
    var done: Bool
}

struct KnotQWidgetSnapshot: Codable, Hashable {
    var generatedAt: Date
    var timeFormat: String
    var themeMode: String
    var items: [KnotQWidgetOccurrence]

    static let empty = KnotQWidgetSnapshot(
        generatedAt: Date(),
        timeFormat: "twelve_hour",
        themeMode: "system",
        items: []
    )
}

enum KnotQWidgetSnapshotStore {
    private static let key = "knotq.upcomingWidgetSnapshot.v1"

    static func load() -> KnotQWidgetSnapshot {
        decode(defaults.data(forKey: key))
    }

    /// Decode persisted widget state without inventing content. An absent or
    /// corrupt App Group value is a normal first-launch/recovery state, and an
    /// empty item list is a valid "nothing scheduled" state.
    static func decode(_ data: Data?) -> KnotQWidgetSnapshot {
        guard let data, let snapshot = try? JSONDecoder().decode(KnotQWidgetSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }

    static func save(_ snapshot: KnotQWidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: knotQWidgetAppGroup) ?? .standard
    }
}
