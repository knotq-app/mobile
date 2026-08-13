import XCTest
@testable import KnotQMobile

/// `mergeRemoteSchemeItems` resolves a remote scheme update against unflushed
/// local editor lines: lines the user touched since the last flush win locally,
/// everything else — remote edits, additions, deletions — wins remotely.
final class RemoteMergeTests: XCTestCase {

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
