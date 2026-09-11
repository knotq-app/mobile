import XCTest
@testable import KnotQMobile

/// `mergeRemoteSchemeItems` resolves a remote scheme update against unflushed
/// local editor lines: lines the user touched since the last flush win locally,
/// everything else — remote edits, additions, deletions — wins remotely.
@MainActor
final class RemoteMergeTests: XCTestCase {

    func testBackgroundPushClassifierRequiresTheExactSyncEvent() {
        XCTAssertTrue(
            BackgroundSyncCoordinator.isKnotQBackgroundPush(["type": "notification_schedule_changed"]),
        )
        XCTAssertFalse(BackgroundSyncCoordinator.isKnotQBackgroundPush(["type": "other"]))
        XCTAssertFalse(BackgroundSyncCoordinator.isKnotQBackgroundPush([:]))
        XCTAssertFalse(BackgroundSyncCoordinator.isKnotQBackgroundPush(["type": 1]))
    }

    func testBrowserAuthIgnoresCallbacksFromCancelledAttempts() {
        var gate = WebAuthenticationAttemptGate()
        let first = gate.begin()
        gate.cancel()
        let second = gate.begin()

        XCTAssertFalse(gate.accepts(first))
        XCTAssertTrue(gate.accepts(second))
    }

    func testSyncApiBaseRequiresHttpsOrLoopbackHttp() {
        XCTAssertTrue(AppModel.isSecureSyncApiBase("https://api.knotq.com"))
        XCTAssertTrue(AppModel.isSecureSyncApiBase("https://sync.example.test/v1"))
        XCTAssertTrue(AppModel.isSecureSyncApiBase("http://127.0.0.1:8787"))
        XCTAssertTrue(AppModel.isSecureSyncApiBase("http://[::1]:8787"))
        XCTAssertFalse(AppModel.isSecureSyncApiBase("http://sync.example.test"))
        XCTAssertFalse(AppModel.isSecureSyncApiBase("http://127.0.0.1.evil.test"))
        XCTAssertFalse(AppModel.isSecureSyncApiBase("http://localhost.evil.test"))
    }

    func testSyncApiBaseRejectsCredentialsAndRoutingDecorations() {
        XCTAssertFalse(AppModel.isSecureSyncApiBase("https://user:password@api.knotq.com"))
        XCTAssertFalse(AppModel.isSecureSyncApiBase("https://api.knotq.com?redirect=evil"))
        XCTAssertFalse(AppModel.isSecureSyncApiBase("https://api.knotq.com#fragment"))
        XCTAssertFalse(AppModel.isSecureSyncApiBase("ftp://api.knotq.com"))
    }

    func testErrorAlertGateQueuesReplacementUntilTheVisibleAlertIsDismissed() {
        var gate = ErrorAlertGate()

        XCTAssertTrue(gate.receive("first"))
        XCTAssertEqual(gate.presentedMessage, "first")
        XCTAssertFalse(gate.receive("second"), "a visible alert must not trigger a second presentation")
        XCTAssertEqual(gate.pendingMessage, "second")

        XCTAssertTrue(gate.dismiss())
        XCTAssertEqual(gate.presentedMessage, "second")
        XCTAssertNil(gate.pendingMessage)
        XCTAssertFalse(gate.receive("second"), "repeating the visible error must stay deduplicated")
    }

    func testErrorAlertGateKeepsTheNewestErrorAndIgnoresDismissalWithoutAQueue() {
        var gate = ErrorAlertGate()

        XCTAssertFalse(gate.dismiss())
        XCTAssertTrue(gate.receive("first"))
        XCTAssertFalse(gate.receive("second"))
        XCTAssertFalse(gate.receive("third"))
        XCTAssertEqual(gate.pendingMessage, "third")

        XCTAssertTrue(gate.dismiss())
        XCTAssertEqual(gate.presentedMessage, "third")
        XCTAssertFalse(gate.dismiss())
        XCTAssertNil(gate.presentedMessage)
        XCTAssertFalse(gate.dismiss())
    }

    func testErrorAlertGateDropsQueuedErrorsWhenTheSourceClears() {
        var gate = ErrorAlertGate()

        XCTAssertTrue(gate.receive("first"))
        XCTAssertFalse(gate.receive("second"))
        XCTAssertFalse(gate.receive(nil))
        XCTAssertNil(gate.pendingMessage)
        XCTAssertFalse(gate.dismiss())
        XCTAssertNil(gate.presentedMessage)
    }

    func testTokenExpiryPolicyHandlesFractionalAndWholeSecondISO8601() {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wholeSecond = ISO8601DateFormatter()
        wholeSecond.formatOptions = [.withInternetDateTime]

        XCTAssertTrue(
            AppModel.tokenNeedsRefresh(
                fractional.string(from: Date(timeIntervalSinceNow: 10)),
                minimumValidity: 120
            ),
            "a token inside the skew window must refresh"
        )
        XCTAssertTrue(
            AppModel.tokenNeedsRefresh(
                wholeSecond.string(from: Date(timeIntervalSinceNow: 10 * 60)),
                minimumValidity: 120
            ) == false,
            "a token with useful remaining lifetime must not refresh"
        )
        XCTAssertTrue(
            AppModel.tokenNeedsRefresh("not-an-ISO-date"),
            "an unreadable expiry must fail closed and refresh defensively"
        )
    }

    func testMobileDateParsesFractionalAndWholeSecondTimestampsAcrossOffsets() {
        let whole = MobileDate.parseDateTime("2026-09-10T21:00:00Z")
        let fractional = MobileDate.parseDateTime("2026-09-10T17:00:00.123-04:00")

        XCTAssertNotNil(whole)
        XCTAssertNotNil(fractional)
        XCTAssertEqual(fractional?.timeIntervalSince1970 ?? 0, (whole?.timeIntervalSince1970 ?? 0) + 0.123, accuracy: 0.001)
        XCTAssertEqual(MobileDate.formatTime("2026-09-10T17:00:00.123-04:00", timeFormat: "twenty_four_hour"), "17:00")
    }

    func testDateOnlyParsingRejectsNormalizedOrNonCanonicalDates() {
        XCTAssertNotNil(AppModel.date(from: "2026-02-28"))
        XCTAssertNil(AppModel.date(from: "2026-02-29"), "2026 is not a leap year")
        XCTAssertNil(AppModel.date(from: "2026-02-30"), "invalid dates must not roll into March")
        XCTAssertNil(AppModel.date(from: "2026-1-1"), "date-only keys are canonical YYYY-MM-DD")
        XCTAssertNil(AppModel.date(from: "2026-13-01"))
    }

    func testMobileHTTPResponseLimitAllowsExactCapButRejectsOverflow() {
        var body = Data()
        XCTAssertNoThrow(try MobileHTTPResponseLimits.append(1, to: &body, maxBytes: 3))
        XCTAssertNoThrow(try MobileHTTPResponseLimits.append(2, to: &body, maxBytes: 3))
        XCTAssertNoThrow(try MobileHTTPResponseLimits.append(3, to: &body, maxBytes: 3))
        XCTAssertThrowsError(try MobileHTTPResponseLimits.append(4, to: &body, maxBytes: 3)) { error in
            XCTAssertEqual(error as? MobileHTTPResponseError, .tooLarge)
        }
        XCTAssertEqual(body, Data([1, 2, 3]))
    }

    func testMobileHTTPResponseLimitRejectsAnyByteWhenCapIsZero() {
        var body = Data()
        XCTAssertThrowsError(try MobileHTTPResponseLimits.append(1, to: &body, maxBytes: 0))
        XCTAssertTrue(body.isEmpty)
    }

    func testControlPlaneRequestsHaveABoundedDefaultTimeoutButKeepShorterDeadlines() {
        var defaultRequest = URLRequest(url: URL(string: "https://api.knotq.com/v1/auth/me")!)
        defaultRequest.timeoutInterval = 60
        XCTAssertEqual(
            MobileHTTPResponseLimits.boundedRequest(defaultRequest).timeoutInterval,
            MobileHTTPResponseLimits.maxRequestTimeout
        )

        var shortRequest = defaultRequest
        shortRequest.timeoutInterval = 5
        XCTAssertEqual(MobileHTTPResponseLimits.boundedRequest(shortRequest).timeoutInterval, 5)

        var unboundedRequest = defaultRequest
        unboundedRequest.timeoutInterval = 0
        XCTAssertEqual(
            MobileHTTPResponseLimits.boundedRequest(unboundedRequest).timeoutInterval,
            MobileHTTPResponseLimits.maxRequestTimeout
        )
    }

    func testTerminalRefreshErrorRequires401AndAnExplicitBackendCode() {
        let url = URL(string: "https://api.example.test/v1/auth/refresh")!
        let unauthorized = HTTPURLResponse(
            url: url,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )!
        let serverError = HTTPURLResponse(
            url: url,
            statusCode: 500,
            httpVersion: nil,
            headerFields: nil
        )!

        XCTAssertTrue(
            AppModel.isTerminalRefreshError(
                unauthorized,
                Data(#"{"code":"invalid_refresh_token"}"#.utf8)
            )
        )
        XCTAssertTrue(
            AppModel.isTerminalRefreshError(
                unauthorized,
                Data(#"{"code":"refresh_token_reused"}"#.utf8)
            )
        )
        XCTAssertFalse(
            AppModel.isTerminalRefreshError(
                unauthorized,
                Data(#"{"code":"temporary_failure"}"#.utf8)
            ),
            "unknown 401 bodies must remain retryable rather than signing the user out"
        )
        XCTAssertFalse(
            AppModel.isTerminalRefreshError(
                unauthorized,
                Data(#"{"message":"invalid_refresh_token"}"#.utf8)
            ),
            "a matching phrase in the wrong field must not trigger sign-out"
        )
        XCTAssertFalse(
            AppModel.isTerminalRefreshError(
                serverError,
                Data(#"{"code":"invalid_refresh_token"}"#.utf8)
            ),
            "a server failure is transient even if its body resembles an auth error"
        )
    }

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

    /// The editor reloads the changed item when a remote snapshot arrives. A
    /// plain numeric offset is not a stable caret anchor when that item itself
    /// changed, so exercise insertions, deletions, replacements, Unicode, and
    /// edits at both sides of the caret in one table-driven regression suite.
    func testCaretOffsetAdaptsToRemoteTextChanges() {
        let cases: [(String, String, Int, Int, String)] = [
            ("abcd", "XYabcd", 2, 4, "remote prefix moves the caret right"),
            ("abcd", "abXYcd", 2, 4, "remote insertion at the caret stays before the old suffix"),
            ("abcd", "abcdXY", 2, 2, "remote suffix does not move the caret"),
            ("abcd", "acd", 3, 2, "deletion before the caret moves it left"),
            ("abcd", "acd", 1, 1, "deletion after the caret does not move it"),
            ("abcd", "ad", 2, 1, "deletion spanning the caret collapses to its start"),
            ("abcd", "abXYd", 2, 4, "replacement at the caret keeps the caret after incoming text"),
            ("abcd", "abXYd", 3, 4, "replacement ending at the caret maps after its replacement"),
            ("hello world", "hello brave world", 6, 12, "word insertion before the old suffix"),
            ("hello world", "hello world", 6, 6, "unchanged text keeps the offset"),
            ("A😀BC", "A😀XYZBC", 3, 6, "UTF-16 emoji offsets are handled correctly"),
            ("A😀BC", "ABC", 3, 1, "deleting a surrogate pair before the caret"),
            ("", "remote", 0, 6, "insertion into an empty line"),
            ("remote", "", 3, 0, "deleting the entire line"),
            ("123456789", "123456789", -10, 0, "negative offsets clamp safely"),
            ("123456789", "123", 99, 3, "oversized offsets clamp to the new line"),
        ]

        for (old, new, offset, expected, message) in cases {
            XCTAssertEqual(
                adaptedEditorTextOffset(from: old, to: new, offset: offset),
                expected,
                message
            )
        }
    }

    /// Run the same position mapper through many deterministic edits. This is
    /// deliberately independent of UIKit so it remains fast enough to run in
    /// every iOS test invocation, while still covering boundaries that are easy
    /// to miss in a handful of hand-written examples.
    func testCaretOffsetInsertionAndDeletionPropertyCases() {
        for seed in 0..<160 {
            let old = String((0..<24).map { Character(UnicodeScalar(0xE000 + (($0 + seed) % 512))!) })
            let offset = (seed * 17) % (old.utf16.count + 1)
            let insertion = "<(seed)>"
            let insertionIndex = (seed * 11) % (old.utf16.count + 1)
            let oldNSString = old as NSString
            let inserted = oldNSString.replacingCharacters(
                in: NSRange(location: insertionIndex, length: 0),
                with: insertion
            )
            let expectedInsertion = offset >= insertionIndex
                ? offset + (insertion as NSString).length
                : offset
            XCTAssertEqual(
                adaptedEditorTextOffset(from: old, to: inserted, offset: offset),
                expectedInsertion,
                "insertion seed \(seed) at \(insertionIndex)"
            )

            let deletionStart = seed % oldNSString.length
            let deletionLength = 1 + ((seed * 7) % (oldNSString.length - deletionStart))
            let deleted = oldNSString.replacingCharacters(
                in: NSRange(location: deletionStart, length: deletionLength),
                with: ""
            )
            let expectedDeletion: Int
            if offset <= deletionStart {
                expectedDeletion = offset
            } else if offset >= deletionStart + deletionLength {
                expectedDeletion = offset - deletionLength
            } else {
                expectedDeletion = deletionStart
            }
            XCTAssertEqual(
                adaptedEditorTextOffset(from: old, to: deleted, offset: offset),
                expectedDeletion,
                "deletion seed \(seed) at \(deletionStart) length \(deletionLength)"
            )
        }
    }

    /// Exercise the actual EditorController -> EditorTextView reload path, not
    /// just the pure offset mapper. This catches regressions where a future
    /// editor refactor captures the wrong line text or restores the old absolute
    /// offset before the mapper gets a chance to run.
    func testReloadPreservingCaretAdaptsRemoteEditInsideTheActiveLine() {
        let view = EditorTextView()
        let controller = EditorController()
        controller.view = view
        let coordinator = EditorCoordinator()
        coordinator.view = view
        coordinator.controller = controller
        coordinator.theme = .dark
        view.coordinator = coordinator
        view.delegate = coordinator
        view.textStorage.delegate = coordinator
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        view.loadItems(
            [item("a", "alpha"), item("b", "beta gamma")],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )

        // The second line is "beta gamma\n". Put the caret after "beta ";
        // the remote insertion should carry it over the inserted phrase.
        view.selectedRange = NSRange(location: 6 + 5, length: 0)
        controller.reloadPreservingCaret(
            items: [item("a", "alpha"), item("b", "beta brave gamma")],
            theme: .dark,
            timeFormat: "twelve_hour"
        )

        XCTAssertEqual(view.selectedRange, NSRange(location: 6 + 11, length: 0))
        XCTAssertEqual(view.text, "alpha\nbeta brave gamma\n")
    }

    func testReloadPreservingCaretTracksLineWhenRemoteTextAboveItChanges() {
        let view = EditorTextView()
        let controller = EditorController()
        controller.view = view
        let coordinator = EditorCoordinator()
        coordinator.view = view
        coordinator.controller = controller
        coordinator.theme = .dark
        view.coordinator = coordinator
        view.delegate = coordinator
        view.textStorage.delegate = coordinator
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        view.loadItems(
            [item("a", "alpha"), item("b", "beta")],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )
        view.selectedRange = NSRange(location: 6 + 2, length: 0)

        controller.reloadPreservingCaret(
            items: [item("a", "alpha remote"), item("b", "beta")],
            theme: .dark,
            timeFormat: "twelve_hour"
        )

        // "alpha remote\n" is 13 UTF-16 units; the caret remains after "be"
        // on item b rather than at the old absolute index 8.
        XCTAssertEqual(view.selectedRange, NSRange(location: 13 + 2, length: 0))
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

    func testTimelineLayoutCacheReusesCollisionResultsUntilColumnWidthChanges() {
        let view = DayTimelineUIKitView()
        view.selectedDate = Calendar.current.startOfDay(for: Date())
        view.occurrencesByLocalDay = [AppModel.dateOnly(view.selectedDate): [
            occurrence(start: "2026-08-28T09:00:00Z")
        ]]
        let narrow = DayTimelineGeometry(visibleCount: 2, columnWidth: 120, canvasOffsetX: -120)

        let first = view.laidEvents(forDayIndex: 0, geometry: narrow)
        let second = view.laidEvents(forDayIndex: 0, geometry: narrow)

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.first?.frame, first.first?.frame)
        XCTAssertEqual(view.laidEventsCache.count, 1)

        let wide = DayTimelineGeometry(visibleCount: 2, columnWidth: 180, canvasOffsetX: -180)
        let resized = view.laidEvents(forDayIndex: 0, geometry: wide)

        XCTAssertEqual(resized.count, 1)
        XCTAssertEqual(view.laidEventsCacheColumnWidth, wide.columnWidth)
        XCTAssertEqual(view.laidEventsCache.count, 1)
        XCTAssertNotEqual(resized.first?.frame.width, first.first?.frame.width)
    }

    func testTimelineGeometryClampsDayHitTestingAtColumnBoundaries() {
        let geometry = DayTimelineGeometry(visibleCount: 2, columnWidth: 120, canvasOffsetX: -120)

        XCTAssertEqual(geometry.dayIndex(forClipX: -500, in: geometry.visibleDayRange), 0)
        XCTAssertEqual(geometry.dayIndex(forClipX: 0, in: geometry.visibleDayRange), 0)
        XCTAssertEqual(geometry.dayIndex(forClipX: 119.99, in: geometry.visibleDayRange), 0)
        XCTAssertEqual(geometry.dayIndex(forClipX: 120, in: geometry.visibleDayRange), 1)
        XCTAssertEqual(geometry.dayIndex(forClipX: 500, in: geometry.visibleDayRange), 1)
    }

    func testCachedDateFormattingUsesTheConfiguredClockStyle() {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = 13
        components.minute = 7
        let date = Calendar.current.date(from: components)!

        XCTAssertEqual(MobileDate.formatTime(date, timeFormat: "twenty_four_hour"), "13:07")
        XCTAssertEqual(MobileDate.formatTime(date, timeFormat: "twelve_hour"), "1:07 PM")
    }

    func testOnboardingStepClampingProtectsSceneRestoreAndTransitionEdges() {
        XCTAssertEqual(clampedOnboardingStep(-1, count: 5), 0)
        XCTAssertEqual(clampedOnboardingStep(0, count: 5), 0)
        XCTAssertEqual(clampedOnboardingStep(2, count: 5), 2)
        XCTAssertEqual(clampedOnboardingStep(99, count: 5), 4)
        XCTAssertEqual(clampedOnboardingStep(99, count: 0), 0)
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
