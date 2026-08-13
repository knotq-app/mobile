import XCTest
@testable import KnotQMobile

/// `SchemeWriteTracker` is what lets a view know the snapshot it can see is
/// already out of date. Getting the accounting wrong is silent in both
/// directions: leak a count and editors for that scheme defer their initial load
/// forever (blank document); drop one early and the stale-read window reopens.
final class SchemeWriteTrackerTests: XCTestCase {

    func testUntrackedSchemeIsNotInFlight() {
        let tracker = SchemeWriteTracker()
        XCTAssertFalse(tracker.isInFlight("a"))
        XCTAssertTrue(tracker.isEmpty)
    }

    func testBeginThenEndClearsTheScheme() {
        var tracker = SchemeWriteTracker()
        tracker.begin("a")
        XCTAssertTrue(tracker.isInFlight("a"))
        tracker.end("a")
        XCTAssertFalse(tracker.isInFlight("a"))
        XCTAssertTrue(tracker.isEmpty, "a settled scheme is removed, not left at zero")
    }

    /// The live flush fires on a debounce while `commitDocument` fires on
    /// disappear, so two writes for one scheme are routinely in flight together.
    /// The first completion must not clear the second's window.
    func testOverlappingWritesNest() {
        var tracker = SchemeWriteTracker()
        tracker.begin("a")
        tracker.begin("a")
        tracker.end("a")
        XCTAssertTrue(tracker.isInFlight("a"), "still one outstanding write")
        tracker.end("a")
        XCTAssertFalse(tracker.isInFlight("a"))
    }

    func testSchemesAreTrackedIndependently() {
        var tracker = SchemeWriteTracker()
        tracker.begin("a")
        XCTAssertFalse(tracker.isInFlight("b"), "one scheme's write must not block another's editor")
        tracker.begin("b")
        tracker.end("a")
        XCTAssertFalse(tracker.isInFlight("a"))
        XCTAssertTrue(tracker.isInFlight("b"))
    }

    func testEndingAnUntrackedSchemeIsANoOp() {
        var tracker = SchemeWriteTracker()
        tracker.end("a")
        XCTAssertFalse(tracker.isInFlight("a"))
        // Must not have gone negative: a subsequent real write still registers.
        tracker.begin("a")
        XCTAssertTrue(tracker.isInFlight("a"))
    }

    func testEndingMoreThanBegunCannotStrandTheScheme() {
        var tracker = SchemeWriteTracker()
        tracker.begin("a")
        tracker.end("a")
        tracker.end("a")
        tracker.begin("a")
        XCTAssertTrue(tracker.isInFlight("a"))
        tracker.end("a")
        XCTAssertFalse(tracker.isInFlight("a"), "an extra end must not leave a phantom count behind")
    }

    // MARK: multi-document writes

    func testMultiSchemeBeginTracksEveryDocument() {
        var tracker = SchemeWriteTracker()
        let tracked = tracker.begin(["a", "b"])
        XCTAssertTrue(tracker.isInFlight("a"))
        XCTAssertTrue(tracker.isInFlight("b"))
        tracker.end(tracked)
        XCTAssertTrue(tracker.isEmpty)
    }

    /// `moveItemToScheme` guards against it, but any caller that passes the same
    /// id twice must still balance — a stranded count is an editor that never
    /// loads.
    func testMultiSchemeBeginDeduplicates() {
        var tracker = SchemeWriteTracker()
        let tracked = tracker.begin(["a", "a"])
        XCTAssertEqual(tracked, ["a"])
        tracker.end(tracked)
        XCTAssertFalse(tracker.isInFlight("a"))
        XCTAssertTrue(tracker.isEmpty)
    }

    // MARK: what a freshly created editor is seeded with

    private func scheme(_ id: String, texts: [String]) -> MobileScheme {
        MobileScheme(
            id: id,
            name: id,
            displayName: id,
            colorIndex: 0,
            isDailyQueue: false,
            isReadOnly: false,
            date: nil,
            items: texts.enumerated().map { index, text in
                MobileItem(
                    id: "\(id)-\(index)",
                    text: text,
                    marker: "blank",
                    indent: 0,
                    kind: "procedure",
                    done: false,
                    start: nil,
                    end: nil,
                    notificationOffsetSecs: nil,
                    repeatRule: nil,
                    media: [],
                    tables: [],
                    content: []
                )
            }
        )
    }

    func testEditorIsSeededWithTheDocumentWhenQuiescent() {
        let tracker = SchemeWriteTracker()
        let doc = scheme("a", texts: ["hello"])
        XCTAssertEqual(tracker.initialEditorItems(for: doc).map(\.text), ["hello"])
    }

    /// The whole point: what `snapshot` holds during a write is text the user has
    /// already replaced, so a new editor must not be born showing it.
    func testEditorIsSeededEmptyWhileAWriteIsInFlight() {
        var tracker = SchemeWriteTracker()
        tracker.begin("a")
        let doc = scheme("a", texts: ["stale"])
        XCTAssertTrue(tracker.initialEditorItems(for: doc).isEmpty)
    }

    func testEditorSeedingIsUnaffectedByAnotherSchemesWrite() {
        var tracker = SchemeWriteTracker()
        tracker.begin("b")
        let doc = scheme("a", texts: ["hello"])
        XCTAssertEqual(
            tracker.initialEditorItems(for: doc).map(\.text),
            ["hello"],
            "a Daily feed shows several days at once; one day's write must not blank the others"
        )
    }

    func testEditorSeedingRecoversOnceTheWriteLands() {
        var tracker = SchemeWriteTracker()
        let doc = scheme("a", texts: ["fresh"])
        tracker.begin("a")
        XCTAssertTrue(tracker.initialEditorItems(for: doc).isEmpty)
        tracker.end("a")
        XCTAssertEqual(tracker.initialEditorItems(for: doc).map(\.text), ["fresh"])
    }

    func testEmptyMultiSchemeBeginTracksNothing() {
        var tracker = SchemeWriteTracker()
        let tracked = tracker.begin([])
        XCTAssertTrue(tracked.isEmpty)
        XCTAssertTrue(tracker.isEmpty)
    }

    /// A multi-document write and a single-document write can overlap on one of
    /// the documents; ending the multi one must leave the single one's window open.
    func testMultiAndSingleWritesOverlapOnOneScheme() {
        var tracker = SchemeWriteTracker()
        let moved = tracker.begin(["a", "b"])
        tracker.begin("a")
        tracker.end(moved)
        XCTAssertTrue(tracker.isInFlight("a"), "the single write is still outstanding")
        XCTAssertFalse(tracker.isInFlight("b"))
        tracker.end("a")
        XCTAssertTrue(tracker.isEmpty)
    }
}
