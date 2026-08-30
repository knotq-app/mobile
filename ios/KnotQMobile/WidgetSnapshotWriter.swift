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

        let next = KnotQWidgetSnapshot(
            generatedAt: Date(),
            timeFormat: snapshot.settings.timeFormat,
            themeMode: snapshot.settings.themeMode,
            items: items
        )
        // Refreshes are deliberately coalesced, but lifecycle and background
        // maintenance still produce unchanged snapshots. Re-encoding defaults
        // and waking WidgetKit for an identical payload burns main-thread time
        // and power without changing what the user can see.
        guard shouldPublish(previous: load(), next: next) else { return }
        save(next)
        WidgetCenter.shared.reloadTimelines(ofKind: knotQWidgetKind)
    }

    /// `generatedAt` is diagnostic metadata, not widget content. Keeping it out
    /// of this comparison lets an unchanged refresh remain a true no-op.
    static func shouldPublish(previous: KnotQWidgetSnapshot, next: KnotQWidgetSnapshot) -> Bool {
        previous.timeFormat != next.timeFormat
            || previous.themeMode != next.themeMode
            || previous.items != next.items
    }
}
