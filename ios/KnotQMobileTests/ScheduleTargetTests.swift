import XCTest
@testable import KnotQMobile

/// Pins the rule the "Schedule" toolbar button depends on: the line the user is
/// on must be a real item *before* anything decides which item to schedule.
///
/// The bug this guards: `openDateForLine` tested `model.scheme(id:)?.items.isEmpty`
/// to decide whether to create a first task, and `scheme(id:)` returns the
/// PRE-write snapshot. So on a scheme whose only content was a character the user
/// had just typed ("J"), the model still read as empty — the empty-document
/// branch fired, appended a SECOND, blank item, and scheduled *that*. The date
/// landed on the line below the one the user was looking at.
///
/// The fix flushes first and only then asks whether there is anything to target.
/// These tests assert the property that makes the fix correct — a just-typed line
/// is a real, findable item once the flush completes — against the real core, so
/// they fail if the deferral is "simplified" away again.
@MainActor
final class ScheduleTargetTests: XCTestCase {

    private static let scratchPrefix = "schedule-target-test-"

    override func setUp() async throws {
        try await super.setUp()
        let model = AppModel.shared
        guard model.bridge != nil else { return }
        for scheme in model.snapshot?.schemes ?? []
        where scheme.name.hasPrefix(Self.scratchPrefix) {
            _ = await removeScratchScheme(scheme.id)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @discardableResult
    private func removeScratchScheme(_ id: String) async -> Bool {
        let model = AppModel.shared
        model.deleteScheme(id: id)
        await waitUntil { model.snapshot?.schemes.contains { $0.id == id } != true }
        model.permanentlyDeleteScheme(id: id)
        await waitUntil { model.scheme(id: id) == nil }
        return model.scheme(id: id) == nil
    }

    /// An empty scheme, as the editor opens one.
    private func makeEmptyScratchScheme() async throws -> String {
        let model = AppModel.shared
        try XCTSkipIf(model.bridge == nil, "core unavailable in this environment")
        guard let id = await model.createScheme(name: Self.scratchPrefix + UUID().uuidString) else {
            throw XCTSkip("could not create a scratch scheme")
        }
        return id
    }

    private func edit(_ text: String, id: String? = nil, start: String? = nil) -> MobileItemEdit {
        MobileItemEdit(
            id: id,
            text: text,
            marker: "checkbox",
            indent: 0,
            done: false,
            start: start,
            end: nil,
            notificationOffsetSecs: nil,
            repeatRule: nil,
            media: [],
            content: []
        )
    }

    /// ISO-8601, the encoding the model uses for item dates.
    private var isoNow: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    /// The heart of it: right after submitting the typed line, the model still
    /// reads as empty. Anything that branches on "is this document empty?"
    /// before the write lands takes the wrong branch.
    func testASchemeStillReadsEmptyWhileTheFirstTypedLineIsInFlight() async throws {
        let model = AppModel.shared
        let schemeID = try await makeEmptyScratchScheme()
        defer { Task { _ = await self.removeScratchScheme(schemeID) } }

        XCTAssertEqual(model.scheme(id: schemeID)?.items.count, 0, "starts empty")

        let landed = expectation(description: "typed line landed")
        model.replaceSchemeItems(schemeID: schemeID, items: [edit("J")]) { landed.fulfill() }

        XCTAssertEqual(
            model.scheme(id: schemeID)?.items.count, 0,
            """
            The snapshot is still the PRE-write one here. This is exactly the \
            window in which the schedule button used to decide the document was \
            empty and append a second, blank line to schedule.
            """
        )

        await fulfillment(of: [landed], timeout: 10)
        XCTAssertEqual(
            model.scheme(id: schemeID)?.items.count, 1,
            "after the flush the typed line is the one and only item"
        )
        XCTAssertEqual(model.scheme(id: schemeID)?.items.first?.text, "J")
    }

    /// After the flush, the typed line is findable by id — so the ordinary
    /// "schedule the current line" path has a valid target and the
    /// empty-document fallback must not run.
    func testTheJustTypedLineIsATargetableItemOnceFlushed() async throws {
        let model = AppModel.shared
        let schemeID = try await makeEmptyScratchScheme()
        defer { Task { _ = await self.removeScratchScheme(schemeID) } }

        let landed = expectation(description: "flush")
        model.replaceSchemeItems(schemeID: schemeID, items: [edit("J")]) { landed.fulfill() }
        await fulfillment(of: [landed], timeout: 10)

        guard let items = model.scheme(id: schemeID)?.items, let first = items.first else {
            return XCTFail("the typed line should exist after the flush")
        }
        XCTAssertEqual(items.count, 1, "scheduling must not have anything else to land on")
        XCTAssertTrue(
            items.contains { $0.id == first.id },
            "the line the editor would name as current must be findable in the model"
        )

        // And scheduling it attaches the date to THAT item, not a new one.
        let scheduled = expectation(description: "scheduled")
        let edited = edit("J", id: first.id, start: isoNow)
        model.replaceSchemeItems(schemeID: schemeID, items: [edited]) { scheduled.fulfill() }
        await fulfillment(of: [scheduled], timeout: 10)

        let after = model.scheme(id: schemeID)?.items ?? []
        XCTAssertEqual(after.count, 1, "scheduling must not add a line")
        XCTAssertEqual(after.first?.text, "J", "the date belongs to the line the user typed on")
        XCTAssertNotNil(after.first?.start, "and that line is the one that got the date")
    }

    /// The fallback still has to work: a genuinely untouched empty document has
    /// no line to target, so scheduling creates the first one.
    func testAnUntouchedEmptySchemeStillGetsItsFirstLineCreated() async throws {
        let model = AppModel.shared
        let schemeID = try await makeEmptyScratchScheme()
        defer { Task { _ = await self.removeScratchScheme(schemeID) } }

        XCTAssertEqual(model.scheme(id: schemeID)?.items.count, 0)
        model.addItem(schemeID: schemeID, text: "")
        await waitUntil { model.scheme(id: schemeID)?.items.isEmpty == false }

        let items = model.scheme(id: schemeID)?.items ?? []
        XCTAssertEqual(items.count, 1, "exactly one line, for the schedule to attach to")
        XCTAssertEqual(items.first?.text, "", "and it is the blank line just created")
    }
}
