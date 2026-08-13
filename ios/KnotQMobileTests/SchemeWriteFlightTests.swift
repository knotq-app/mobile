import XCTest
@testable import KnotQMobile

/// Exercises the in-flight bookkeeping against the REAL core, so the contract the
/// editor pane depends on is pinned end to end rather than only in the pure
/// `SchemeWriteTracker` unit tests:
///
///   1. a submitted write reads as in flight immediately, and
///   2. `snapshot` really is stale for that whole window, and
///   3. by the time a caller's completion runs, both are resolved.
///
/// (2) is the one worth pinning: it is easy to look at `replaceSchemeItems` and
/// assume the model updates synchronously, "simplify" the deferral away, and
/// silently reintroduce the stale-load-then-merge data loss.
@MainActor
final class SchemeWriteFlightTests: XCTestCase {

    private static let scratchPrefix = "write-flight-test-"

    /// These tests create real schemes in the host app's workspace, so a run that
    /// is interrupted (or an older build whose teardown was fire-and-forget)
    /// leaves them behind. Sweep them before starting rather than accumulating
    /// junk in whatever simulator the suite runs on.
    override func setUp() async throws {
        try await super.setUp()
        let model = AppModel.shared
        guard model.bridge != nil else { return }
        for scheme in model.snapshot?.schemes ?? []
        where scheme.name.hasPrefix(Self.scratchPrefix) {
            // Best effort: a leftover this sweep cannot remove is not a reason
            // to fail every test in the suite.
            _ = await removeScratchScheme(scheme.id)
        }
    }

    private func identityEdit(_ item: MobileItem) -> MobileItemEdit {
        MobileItemEdit(
            id: item.id,
            text: item.text,
            marker: item.marker,
            indent: item.indent,
            done: item.done,
            start: item.start,
            end: item.end,
            notificationOffsetSecs: item.notificationOffsetSecs,
            repeatRule: item.repeatRule,
            media: item.media,
            content: item.content
        )
    }

    /// A scheme with at least one item to edit, created for this test.
    private func makeScratchScheme() async throws -> String {
        let model = AppModel.shared
        try XCTSkipIf(model.bridge == nil, "core unavailable in this environment")
        guard let id = await model.createScheme(name: Self.scratchPrefix + UUID().uuidString) else {
            throw XCTSkip("could not create a scratch scheme")
        }
        let added = expectation(description: "seed item")
        model.addItem(schemeID: id, text: "seed", marker: .checkbox)
        // `addItem` has no completion; wait for the item to appear.
        Task { @MainActor in
            for _ in 0..<100 where model.scheme(id: id)?.items.isEmpty != false {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            added.fulfill()
        }
        await fulfillment(of: [added], timeout: 10)
        return id
    }

    /// Scratch schemes must be torn down before the test returns, not from a
    /// detached `Task` in a `defer` — the test process can exit first, and then
    /// they pile up in the workspace of whatever simulator ran the suite.
    /// Archive, then purge. `permanentlyDeleteScheme` only applies to something
    /// already in the archive, so deleting a live scheme takes both steps.
    /// Poll until `condition` holds, or give up. Core writes are async, so every
    /// step here has to be waited for rather than assumed.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @discardableResult
    private func removeScratchScheme(_ id: String) async -> Bool {
        let model = AppModel.shared
        model.deleteScheme(id: id)
        // `scheme(id:)` also searches the archive, so it cannot report progress
        // on the archive step — watch the live list instead.
        await waitUntil { model.snapshot?.schemes.contains { $0.id == id } != true }
        model.permanentlyDeleteScheme(id: id)
        await waitUntil { model.scheme(id: id) == nil }
        return model.scheme(id: id) == nil
    }

    private func deleteScratchScheme(_ id: String) async {
        let gone = await removeScratchScheme(id)
        XCTAssertTrue(gone, "scratch scheme outlived its test")
    }

    func testWriteIsInFlightUntilItsCompletionRuns() async throws {
        let model = AppModel.shared
        let schemeID = try await makeScratchScheme()

        XCTAssertFalse(model.hasWriteInFlight(schemeID: schemeID), "quiescent before the write")

        let items = (model.scheme(id: schemeID)?.items ?? []).map(identityEdit)
        let landed = expectation(description: "write landed")
        model.replaceSchemeItems(schemeID: schemeID, items: items) {
            XCTAssertFalse(
                model.hasWriteInFlight(schemeID: schemeID),
                "the flight must be over by the time a caller's completion sees the new snapshot"
            )
            landed.fulfill()
        }

        XCTAssertTrue(
            model.hasWriteInFlight(schemeID: schemeID),
            "in flight from the moment it is submitted — this is the window a fresh editor pane must not load in"
        )

        await fulfillment(of: [landed], timeout: 10)
        XCTAssertFalse(model.hasWriteInFlight(schemeID: schemeID))

        await deleteScratchScheme(schemeID)
    }

    /// The reason the deferral exists: the model genuinely does not reflect the
    /// write yet, so anything that rebuilds from `scheme(id:)` in this window
    /// renders text the user has already replaced.
    func testSnapshotStillHoldsPreWriteTextWhileInFlight() async throws {
        let model = AppModel.shared
        let schemeID = try await makeScratchScheme()

        guard let original = model.scheme(id: schemeID)?.items.first else {
            await deleteScratchScheme(schemeID)
            throw XCTSkip("scratch scheme has no item")
        }
        var edited = identityEdit(original)
        edited.text = "edited while in flight"
        // `content` is the authoritative representation for a text line, so
        // changing only `text` would be written back as the original.
        edited.content = [.text(text: "edited while in flight")]

        let landed = expectation(description: "write landed")
        model.replaceSchemeItems(schemeID: schemeID, items: [edited]) { landed.fulfill() }

        XCTAssertEqual(
            model.scheme(id: schemeID)?.items.first?.text,
            original.text,
            "the snapshot is the PRE-write document until the core write completes"
        )
        XCTAssertTrue(model.hasWriteInFlight(schemeID: schemeID), "…and that staleness is exactly what this reports")

        await fulfillment(of: [landed], timeout: 10)

        XCTAssertEqual(model.scheme(id: schemeID)?.items.first?.text, "edited while in flight")
        XCTAssertFalse(model.hasWriteInFlight(schemeID: schemeID))

        await deleteScratchScheme(schemeID)
    }

    /// Item-level operations are tracked too, not just `replaceSchemeItems` — a
    /// toggle that isn't tracked can be reverted by a concurrent editor merge
    /// (see `RemoteMergeTests.testStaleBaselineRevertsAnInFlightToggle`).
    func testItemLevelOperationIsAlsoTracked() async throws {
        let model = AppModel.shared
        let schemeID = try await makeScratchScheme()

        guard let itemID = model.scheme(id: schemeID)?.items.first?.id else {
            await deleteScratchScheme(schemeID)
            throw XCTSkip("scratch scheme has no item")
        }
        model.toggleItem(schemeID: schemeID, itemID: itemID)
        XCTAssertTrue(model.hasWriteInFlight(schemeID: schemeID), "a toggle is a scheme write like any other")

        let settled = expectation(description: "toggle landed")
        Task { @MainActor in
            for _ in 0..<100 where model.hasWriteInFlight(schemeID: schemeID) {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            settled.fulfill()
        }
        await fulfillment(of: [settled], timeout: 10)
        XCTAssertFalse(model.hasWriteInFlight(schemeID: schemeID))

        await deleteScratchScheme(schemeID)
    }
}
