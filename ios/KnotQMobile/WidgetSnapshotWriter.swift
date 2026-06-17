import Foundation
import WidgetKit

extension KnotQWidgetSnapshotStore {
    @MainActor
    static func publish(snapshot: MobileSnapshot) {
        let now = Date()
        let items = (snapshot.calendar.overdue + snapshot.calendar.upcoming)
            .filter { occurrence in
                // Completed occurrences never belong on the widget.
                if occurrence.done { return false }
                // Hide events whose time block has already elapsed. The app marks
                // these complete in the background, but filter here too so a stale
                // snapshot never leaves a finished event on the widget. Overdue
                // assignments/reminders (non-event kinds) are intentionally kept.
                if occurrence.kind == "event",
                   let end = MobileDate.parseDateTime(occurrence.end ?? occurrence.start),
                   end <= now {
                    return false
                }
                return true
            }
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
