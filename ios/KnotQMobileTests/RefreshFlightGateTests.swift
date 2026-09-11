import XCTest
@testable import KnotQMobile

/// Snapshot reads build indexes, calendar occurrences, notification plans, and
/// widget state. These tests pin the coalescing contract: a storm becomes one
/// active read plus one latest follow-up, never a dropped final refresh.
final class RefreshFlightGateTests: XCTestCase {

    private func widgetSnapshot(
        timeFormat: String = "twelve_hour",
        themeMode: String = "light",
        title: String = "Task",
        generatedAt: Date = .distantPast
    ) -> KnotQWidgetSnapshot {
        KnotQWidgetSnapshot(
            generatedAt: generatedAt,
            timeFormat: timeFormat,
            themeMode: themeMode,
            items: [
                KnotQWidgetOccurrence(
                    id: "item", title: title, schemeName: "Inbox", kind: "assignment",
                    start: nil, end: nil, colorIndex: 0, done: false
                )
            ]
        )
    }

    func testFirstRequestStartsAFlight() {
        var gate = RefreshFlightGate()
        XCTAssertTrue(gate.request())
        XCTAssertTrue(gate.isInFlight)
        XCTAssertFalse(gate.followUpRequested)
    }

    func testSecondRequestDuringFlightIsCoalesced() {
        var gate = RefreshFlightGate()
        XCTAssertTrue(gate.request())
        XCTAssertFalse(gate.request())
        XCTAssertTrue(gate.isInFlight)
        XCTAssertTrue(gate.followUpRequested)
    }

    func testManyRequestsDuringFlightStillNeedOnlyOneFollowUp() {
        var gate = RefreshFlightGate()
        XCTAssertTrue(gate.request())
        for _ in 0..<20 {
            XCTAssertFalse(gate.request())
        }
        XCTAssertTrue(gate.followUpRequested)
        XCTAssertTrue(gate.finish())
        XCTAssertTrue(gate.isInFlight, "the direct follow-up owns the same flight")
        XCTAssertFalse(gate.followUpRequested)
    }

    func testQuietFlightFinishesCompletely() {
        var gate = RefreshFlightGate()
        XCTAssertTrue(gate.request())
        XCTAssertFalse(gate.finish())
        XCTAssertFalse(gate.isInFlight)
        XCTAssertFalse(gate.followUpRequested)
    }

    func testFollowUpThenQuietCompletionFinishesCompletely() {
        var gate = RefreshFlightGate()
        XCTAssertTrue(gate.request())
        XCTAssertFalse(gate.request())
        XCTAssertTrue(gate.finish())
        XCTAssertFalse(gate.finish())
        XCTAssertFalse(gate.isInFlight)
    }

    func testRefreshQueryRejectsASelectionThatChangedWhileReading() {
        let query = RefreshQuery(dateKey: "2026-09-10", weekOffset: 0, dailyHistoryDays: 3)

        XCTAssertTrue(query.matches(dateKey: "2026-09-10", weekOffset: 0, dailyHistoryDays: 3))
        XCTAssertFalse(query.matches(dateKey: "2026-09-11", weekOffset: 0, dailyHistoryDays: 3))
        XCTAssertFalse(query.matches(dateKey: "2026-09-10", weekOffset: 1, dailyHistoryDays: 3))
        XCTAssertFalse(query.matches(dateKey: "2026-09-10", weekOffset: 0, dailyHistoryDays: 34))
    }

    func testNewBurstDuringFollowUpGetsAnotherFollowUp() {
        var gate = RefreshFlightGate()
        XCTAssertTrue(gate.request())
        XCTAssertFalse(gate.request())
        XCTAssertTrue(gate.finish())
        XCTAssertFalse(gate.request())
        XCTAssertTrue(gate.followUpRequested)
        XCTAssertTrue(gate.finish())
        XCTAssertFalse(gate.followUpRequested)
        XCTAssertFalse(gate.finish())
        XCTAssertFalse(gate.isInFlight)
    }

    func testFinishWithoutAnActiveFlightIsHarmless() {
        var gate = RefreshFlightGate()
        XCTAssertFalse(gate.finish())
        XCTAssertFalse(gate.isInFlight)
        XCTAssertFalse(gate.followUpRequested)
    }

    func testACompletedFlightAcceptsANewRequest() {
        var gate = RefreshFlightGate()
        XCTAssertTrue(gate.request())
        XCTAssertFalse(gate.finish())
        XCTAssertTrue(gate.request())
        XCTAssertTrue(gate.isInFlight)
    }

    func testSessionGenerationInvalidatesCapturedWorkAfterAdvance() {
        var generation = SyncSessionGeneration()
        let captured = generation.value

        XCTAssertTrue(generation.matches(captured))
        generation.advance()
        XCTAssertFalse(generation.matches(captured))
        XCTAssertTrue(generation.matches(generation.value))
    }

    func testSessionGenerationAdvancesWithoutTrapping() {
        var generation = SyncSessionGeneration()
        for _ in 0..<3 {
            generation.advance()
        }
        XCTAssertEqual(generation.value, 3)
    }

    func testIdenticalWidgetPayloadDoesNotRepublishForNewTimestamp() {
        XCTAssertFalse(
            KnotQWidgetSnapshotStore.shouldPublish(
                previous: widgetSnapshot(generatedAt: .distantPast),
                next: widgetSnapshot(generatedAt: .distantFuture)
            )
        )
    }

    func testWidgetThemeChangeRepublishes() {
        XCTAssertTrue(
            KnotQWidgetSnapshotStore.shouldPublish(
                previous: widgetSnapshot(themeMode: "light"),
                next: widgetSnapshot(themeMode: "dark")
            )
        )
    }

    func testWidgetTimeFormatChangeRepublishes() {
        XCTAssertTrue(
            KnotQWidgetSnapshotStore.shouldPublish(
                previous: widgetSnapshot(timeFormat: "twelve_hour"),
                next: widgetSnapshot(timeFormat: "twenty_four_hour")
            )
        )
    }

    func testWidgetItemChangeRepublishes() {
        XCTAssertTrue(
            KnotQWidgetSnapshotStore.shouldPublish(
                previous: widgetSnapshot(title: "Old"),
                next: widgetSnapshot(title: "New")
            )
        )
    }

    func testMissingOrEmptyWidgetStateDoesNotInventItems() throws {
        XCTAssertTrue(KnotQWidgetSnapshotStore.decode(nil).items.isEmpty)

        let emptyData = try JSONEncoder().encode(KnotQWidgetSnapshot.empty)
        XCTAssertTrue(KnotQWidgetSnapshotStore.decode(emptyData).items.isEmpty)
    }
}
