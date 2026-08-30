import XCTest
@testable import KnotQMobile

/// `mergeRemoteSchemeItems` resolves a remote scheme update against unflushed
/// local editor lines: lines the user touched since the last flush win locally,
/// everything else — remote edits, additions, deletions — wins remotely.
@MainActor
final class RemoteMergeTests: XCTestCase {

    private func occurrence(
        scheme: String = "s",
        item: String = "i",
        json: String = "single",
        done: Bool = false,
        start: String? = nil,
        localDate: String = "2026-08-28"
    ) -> MobileOccurrence {
        MobileOccurrence(
            schemeId: scheme,
            itemId: item,
            occurrenceJson: json,
            occurrenceIndex: 0,
            isRecurring: json != "single",
            canDeleteFuture: false,
            schemeName: "Test",
            colorIndex: 0,
            isReadOnly: false,
            title: "Task",
            kind: "assignment",
            done: done,
            start: start,
            end: nil,
            notificationOffsetSecs: nil,
            localDate: localDate,
            repeatRule: nil
        )
    }

    private func snapshot(
        upcoming: [MobileOccurrence] = [],
        overdue: [MobileOccurrence] = [],
        days: [MobileCalendarDay] = []
    ) -> MobileSnapshot {
        MobileSnapshot(
            root: MobileNode(kind: "folder", id: "root", name: "Root", colorIndex: nil, isDailyQueue: false, isReadOnly: false, children: []),
            schemes: [], archivedSchemes: [], archivedNodes: [], daily: [],
            calendar: MobileCalendar(startDate: "2026-08-28", endDate: "2026-09-04", days: days, upcoming: upcoming, overdue: overdue),
            settings: MobileSettings(themeMode: "light", timeFormat: "twelve_hour", eventNotificationOffsetSecs: 0, assignmentNotificationOffsetSecs: 0, eventLookaheadDays: 7, reminderLookaheadDays: 7, assignmentLookaheadDays: 7, maximumUpcomingItems: 10, showOverdue: true, showCompleted: true, googleAccountCount: 0, googleAccounts: []),
            workspacePath: ""
        )
    }

    private func item(_ id: String, _ text: String, marker: String = "blank", indent: Int32 = 0, done: Bool = false) -> MobileItem {
        MobileItem(
            id: id,
            text: text,
            marker: marker,
            indent: indent,
            kind: "procedure",
            done: done,
            start: nil,
            end: nil,
            notificationOffsetSecs: nil,
            repeatRule: nil,
            media: [],
            tables: [],
            content: []
        )
    }

    private func edit(_ id: String?, _ text: String, marker: String = "blank", indent: Int32 = 0, done: Bool = false) -> MobileItemEdit {
        MobileItemEdit(
            id: id,
            text: text,
            marker: marker,
            indent: indent,
            done: done,
            start: nil,
            end: nil,
            notificationOffsetSecs: nil,
            repeatRule: nil,
            media: [],
            content: []
        )
    }

    func testRemoteWinsForUntouchedLinesLocalWinsForTouchedLines() {
        let baseline = [item("a", "alpha"), item("b", "beta")]
        // Remote edited "b"; the user is mid-typing on "a".
        let remote = [item("a", "alpha"), item("b", "beta remote")]
        let local = [edit("a", "alpha typed"), edit("b", "beta")]

        let merged = mergeRemoteSchemeItems(remote: remote, baseline: baseline, local: local)

        XCTAssertEqual(merged.map(\.text), ["alpha typed", "beta remote"])
        XCTAssertEqual(merged.map(\.id), ["a", "b"])
    }

    func testUnflushedNewLineIsKeptAtItsLocalPosition() {
        let baseline = [item("a", "alpha"), item("b", "beta")]
        let remote = [item("a", "alpha"), item("b", "beta"), item("c", "gamma remote")]
        let local = [edit("a", "alpha"), edit(nil, "fresh typing"), edit("b", "beta")]

        let merged = mergeRemoteSchemeItems(remote: remote, baseline: baseline, local: local)

        XCTAssertEqual(merged.map(\.text), ["alpha", "fresh typing", "beta", "gamma remote"])
        XCTAssertFalse(merged[1].id.isEmpty, "new lines get a minted id the core adopts on flush")
    }

    func testRemoteAdditionSurvivesTheMerge() {
        let baseline = [item("a", "alpha")]
        let remote = [item("a", "alpha"), item("r", "added remotely")]
        let local = [edit("a", "alpha typed")]

        let merged = mergeRemoteSchemeItems(remote: remote, baseline: baseline, local: local)

        XCTAssertEqual(merged.map(\.text), ["alpha typed", "added remotely"])
    }

    func testLocalDeleteWinsUnlessRemoteEditedTheLine() {
        let baseline = [item("a", "alpha"), item("b", "beta"), item("c", "gamma")]
        // User deleted "b" and "c" locally (unflushed); remote edited "c" meanwhile.
        let remote = [item("a", "alpha"), item("b", "beta"), item("c", "gamma remote")]
        let local = [edit("a", "alpha")]

        let merged = mergeRemoteSchemeItems(remote: remote, baseline: baseline, local: local)

        XCTAssertEqual(
            merged.map(\.text),
            ["alpha", "gamma remote"],
            "untouched-by-remote delete sticks; the delete/edit conflict keeps the remote edit"
        )
    }

    func testRemoteDeleteWinsUnlessLocallyEdited() {
        let baseline = [item("a", "alpha"), item("b", "beta"), item("c", "gamma")]
        // Remote deleted "b" and "c"; the user typed into "c" meanwhile.
        let remote = [item("a", "alpha")]
        let local = [edit("a", "alpha"), edit("b", "beta"), edit("c", "gamma typed")]

        let merged = mergeRemoteSchemeItems(remote: remote, baseline: baseline, local: local)

        XCTAssertEqual(
            merged.map(\.text),
            ["alpha", "gamma typed"],
            "untouched line honors the remote delete; the edited line survives it"
        )
    }

    func testPureEchoMergesToRemoteUnchanged() {
        let items = [item("a", "alpha"), item("b", "beta")]
        let merged = mergeRemoteSchemeItems(
            remote: items,
            baseline: items,
            local: [edit("a", "alpha"), edit("b", "beta")]
        )
        XCTAssertEqual(merged, items)
    }

    func testLocalMarkerAndDoneChangesWin() {
        let baseline = [item("a", "task", marker: "checkbox", done: false)]
        let remote = [item("a", "task", marker: "checkbox", done: false)]
        let local = [edit("a", "task", marker: "checkbox", done: true)]

        let merged = mergeRemoteSchemeItems(remote: remote, baseline: baseline, local: local)

        XCTAssertTrue(merged[0].done)
    }

    func testOptimisticToggleUpdatesEveryVisibleCopyOfOneOccurrence() {
        let target = occurrence(json: "2026-08-28T09:00:00Z")
        let otherInstance = occurrence(json: "2026-08-29T09:00:00Z")
        let original = snapshot(
            upcoming: [target, otherInstance],
            overdue: [target],
            days: [MobileCalendarDay(date: "2026-08-28", occurrences: [target])]
        )

        let updated = AppModel.toggledOccurrence(in: original, target: target)

        XCTAssertTrue(updated.calendar.upcoming[0].done)
        XCTAssertTrue(updated.calendar.overdue[0].done)
        XCTAssertTrue(updated.calendar.days[0].occurrences[0].done)
        XCTAssertFalse(updated.calendar.upcoming[1].done, "another recurring instance must not change")
        XCTAssertEqual(updated.calendar.startDate, original.calendar.startDate)
    }

    func testOptimisticToggleIsReversibleForRapidDoubleTap() {
        let target = occurrence()
        let original = snapshot(upcoming: [target])
        let once = AppModel.toggledOccurrence(in: original, target: target)
        let twice = AppModel.toggledOccurrence(in: once, target: once.calendar.upcoming[0])

        XCTAssertFalse(twice.calendar.upcoming[0].done)
    }

    /// `localAnchorDateKey` buckets by the occurrence's own `start`, not by the
    /// day the server happened to file it under — so an occurrence whose start
    /// falls on a different local day than its enclosing `MobileCalendarDay`
    /// lands on the day the user sees it.
    ///
    /// Midday UTC on purpose: it is the same calendar date in every timezone the
    /// simulator is plausibly set to, so this does not depend on the host clock.
    func testTimelineIndexKeepsOccurrencesOnTheirLocalDay() {
        let first = occurrence(item: "first", start: "2026-08-28T12:00:00Z")
        let second = occurrence(item: "second", start: "2026-08-29T12:00:00Z")
        let calendar = MobileCalendar(
            startDate: "2026-08-28",
            endDate: "2026-08-30",
            days: [
                MobileCalendarDay(date: "2026-08-28", occurrences: [first]),
                MobileCalendarDay(date: "2026-08-29", occurrences: [second])
            ],
            upcoming: [],
            overdue: []
        )

        let index = timelineOccurrencesByLocalDay(calendar)
        XCTAssertEqual(index["2026-08-28"]?.map(\.itemId), ["first"])
        XCTAssertEqual(index["2026-08-29"]?.map(\.itemId), ["second"])
        XCTAssertNil(index["2026-08-30"])
    }

    func testTimelineIndexDeduplicatesRepeatedOccurrenceWithinADay() {
        let repeated = occurrence(item: "same", json: "2026-08-28T09:00:00Z")
        let calendar = MobileCalendar(
            startDate: "2026-08-28",
            endDate: "2026-08-29",
            days: [
                MobileCalendarDay(date: "2026-08-28", occurrences: [repeated]),
                MobileCalendarDay(date: "2026-08-28", occurrences: [repeated])
            ],
            upcoming: [],
            overdue: []
        )

        XCTAssertEqual(timelineOccurrencesByLocalDay(calendar)["2026-08-28"]?.count, 1)
    }

    func testTimelineIndexTreatsNoCalendarAsEmpty() {
        XCTAssertTrue(timelineOccurrencesByLocalDay(nil).isEmpty)
    }

    func testEqualSnapshotDoesNotRepublishTheSwiftUIModel() {
        let value = snapshot(upcoming: [occurrence()])
        XCTAssertFalse(AppModel.shouldPublishSnapshot(current: value, next: value))
    }

    func testChangedSnapshotRepublishesTheSwiftUIModel() {
        let current = snapshot(upcoming: [occurrence(done: false)])
        let next = snapshot(upcoming: [occurrence(done: true)])
        XCTAssertTrue(AppModel.shouldPublishSnapshot(current: current, next: next))
        XCTAssertTrue(AppModel.shouldPublishSnapshot(current: nil, next: next))
    }

    // MARK: why the baseline must never predate an in-flight write

    /// The merge is only as good as its baseline, and it cannot tell "the user
    /// changed this line" from "this line was changed by a write I hadn't seen
    /// when I loaded". Loading an editor from the pre-write snapshot — which is
    /// what `snapshot` still holds until an async core write lands — poisons the
    /// baseline, and the merge then writes the user's own in-flight edit away.
    /// This is the corruption `SchemeWriteTracker` exists to prevent; the test
    /// pins the behaviour so the deferral isn't quietly removed as redundant.
    func testStaleBaselineDiscardsTheEditThatWasInFlight() {
        // The user typed "hello world" and it is on its way to the core.
        // A pane that loaded before it landed sees only "hello".
        let staleBaseline = [item("a", "hello")]
        // They keep typing, on top of the text they can see.
        let local = [edit("a", "hello!!")]
        // The write lands, carrying the edit that was in flight.
        let remote = [item("a", "hello world")]

        let merged = mergeRemoteSchemeItems(remote: remote, baseline: staleBaseline, local: local)

        XCTAssertEqual(merged.map(\.text), ["hello!!"])
        XCTAssertFalse(
            merged[0].text.contains("world"),
            "local-wins-per-line silently drops the in-flight edit when the baseline predates it"
        )
    }

    /// Same keystrokes, but the editor waited for the write before loading — so
    /// its baseline includes the in-flight edit and nothing is lost.
    func testBaselineTakenAfterTheWriteKeepsBothEdits() {
        let freshBaseline = [item("a", "hello world")]
        let local = [edit("a", "hello world!!")]
        let remote = [item("a", "hello world")]

        let merged = mergeRemoteSchemeItems(remote: remote, baseline: freshBaseline, local: local)

        XCTAssertEqual(merged.map(\.text), ["hello world!!"])
    }

    /// The same hazard for a non-text field: a checkbox toggled from the daily
    /// feed is invisible to a reader until its write lands, so an editor that
    /// loaded first carries `done: false` in its baseline and un-does the toggle.
    /// This is why every item-level op — not just `replaceSchemeItems` — is
    /// tracked as in flight.
    func testStaleBaselineRevertsAnInFlightToggle() {
        let staleBaseline = [item("a", "task", marker: "checkbox", done: false)]
        let local = [edit("a", "task typed", marker: "checkbox", done: false)]
        let remote = [item("a", "task", marker: "checkbox", done: true)]

        let merged = mergeRemoteSchemeItems(remote: remote, baseline: staleBaseline, local: local)

        XCTAssertFalse(merged[0].done, "the completed state the user just tapped is written back to false")
    }
}
