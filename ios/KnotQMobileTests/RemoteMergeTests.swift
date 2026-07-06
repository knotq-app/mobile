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
}
