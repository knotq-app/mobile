import Foundation
import WidgetKit

extension KnotQWidgetSnapshotStore {
    @MainActor
    static func publish(snapshot: MobileSnapshot) {
        let items = (snapshot.calendar.overdue + snapshot.calendar.upcoming)
            .prefix(12)
            .map { occurrence in
                KnotQWidgetOccurrence(
                    id: "\(occurrence.schemeId)-\(occurrence.itemId)-\(occurrence.occurrenceJson)-\(occurrence.start ?? occurrence.end ?? occurrence.kind)",
                    title: occurrence.title,
                    schemeName: occurrence.schemeName,
                    kind: occurrence.kind,
                    start: occurrence.start,
                    end: occurrence.end,
                    colorIndex: Int(occurrence.colorIndex),
                    done: occurrence.done
                )
            }

        save(KnotQWidgetSnapshot(
            generatedAt: Date(),
            timeFormat: snapshot.settings.timeFormat,
            themeMode: snapshot.settings.themeMode,
            items: items
        ))
        WidgetCenter.shared.reloadTimelines(ofKind: knotQWidgetKind)
    }
}
