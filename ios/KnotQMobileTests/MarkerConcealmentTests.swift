import XCTest
import UIKit
@testable import KnotQMobile

/// Guards the "Obsidian-style" live preview: markdown markers (`**`, `__`, `*`,
/// `_`, `==`, leading `#`) are revealed only on the caret's line and collapse to
/// zero width everywhere else. The regression these tests exist for: moving the
/// caret between lines updated `revealedRange` and regenerated glyphs, but never
/// invalidated *layout*, so the zero-advancement collapse (a layout-time
/// decision) was computed against stale line fragments and the markers stayed
/// visually "stuck" on whichever line first revealed them.
@MainActor
final class MarkerConcealmentTests: XCTestCase {

    /// `NSLayoutManager.textStorage` is a weak back-reference (the storage owns
    /// the layout manager, not the reverse), so a test that only held the layout
    /// manager would let the storage deallocate out from under it. Pin every
    /// storage here for the lifetime of the test instance. XCTest makes a fresh
    /// instance per test method, so this naturally resets between tests.
    private var liveStorages: [NSTextStorage] = []

    // MARK: - Fixtures

    /// A fully wired TextKit 1 stack (storage + layout manager + container) with
    /// markdown markers tagged exactly the way the editor tags them.
    private func makeStack(_ text: String) -> (NSTextStorage, EditorLayoutManager, NSTextContainer) {
        let storage = NSTextStorage(
            string: text,
            attributes: [.font: UIFont.systemFont(ofSize: 17)]
        )
        liveStorages.append(storage)
        // Tag each line's markers through the production parser so the tests
        // exercise the real tagging, not a hand-rolled approximation.
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { line, range, _, _ in
            guard let line, !line.isEmpty else { return }
            applyEmphasis(body: line, lineLocation: range.location, storage: storage)
        }
        let layoutManager = EditorLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 2000, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        return (storage, layoutManager, container)
    }

    private func renderedWidth(_ layoutManager: EditorLayoutManager, _ container: NSTextContainer) -> CGFloat {
        layoutManager.ensureLayout(for: container)
        let glyphs = layoutManager.glyphRange(for: container)
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: container).width
    }

    /// Width of a single line's glyphs. `boundingRect` over a *multi*-line glyph
    /// range collapses to the container width, so per-line measurement is the
    /// only way to compare one line's collapse against another's.
    private func lineWidth(_ layoutManager: EditorLayoutManager, _ container: NSTextContainer, charRange: NSRange) -> CGFloat {
        layoutManager.ensureLayout(for: container)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        return layoutManager.boundingRect(forGlyphRange: glyphRange, in: container).width
    }

    private func markerRanges(_ storage: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        storage.enumerateAttribute(.knotqMarker, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { ranges.append(range) }
        }
        return ranges
    }

    // MARK: - The core regression

    /// The bug, end to end: as the caret moves on and off a line, the markers
    /// must actually collapse and re-expand. Width is a faithful proxy because
    /// collapsed markers contribute zero advancement to the line fragment.
    func testMarkersCollapseWhenCaretLeavesAndRestoreWhenItReturns() {
        let text = "**bold** tail"
        let (_, layoutManager, container) = makeStack(text)
        let wholeLine = NSRange(location: 0, length: (text as NSString).length)

        // Caret on the line → markers revealed.
        XCTAssertTrue(layoutManager.setRevealedRange(wholeLine, force: true))
        let revealedWidth = renderedWidth(layoutManager, container)

        // Caret leaves the line → markers must collapse (strictly narrower).
        XCTAssertTrue(layoutManager.setRevealedRange(NSRange(location: 0, length: 0), force: false))
        let hiddenWidth = renderedWidth(layoutManager, container)
        XCTAssertLessThan(
            hiddenWidth, revealedWidth,
            "Markers must collapse to zero width once the caret leaves the line"
        )

        // Caret returns → markers must reveal again (width restored).
        XCTAssertTrue(layoutManager.setRevealedRange(wholeLine, force: false))
        let restoredWidth = renderedWidth(layoutManager, container)
        XCTAssertEqual(
            restoredWidth, revealedWidth, accuracy: 0.5,
            "Markers must reveal again once the caret returns to the line"
        )
    }

    /// A two-line document: revealing line two must collapse line one's markers
    /// at the same time — the failure mode where the old line stays "stuck".
    func testRevealMovesBetweenLines() {
        let text = "**one**\n**two**"
        let (_, layoutManager, container) = makeStack(text)
        let ns = text as NSString
        let line1 = ns.paragraphRange(for: NSRange(location: 0, length: 0))
        let line2 = ns.paragraphRange(for: NSRange(location: ns.length, length: 0))
        // Measure line one *without* its trailing "\n": a line-break glyph's
        // bounding box runs to the container's trailing edge, which would pin
        // the width to the container width and mask the collapse.
        let line1Content = NSRange(location: line1.location, length: max(0, line1.length - 1))

        layoutManager.setRevealedRange(line1, force: true)
        let line1RevealedWidth = lineWidth(layoutManager, container, charRange: line1Content)

        // Move the caret to line two: line one's markers must now be hidden,
        // line two's must now be shown.
        layoutManager.setRevealedRange(line2, force: false)
        XCTAssertTrue(layoutManager.isHiddenMarker(at: 0), "Line one's marker should hide when the caret moves to line two")
        XCTAssertFalse(layoutManager.isHiddenMarker(at: line2.location), "Line two's marker should reveal")

        // Line one must now render narrower than when it was revealed — proof
        // the collapse actually re-laid out line one, not just line two.
        let line1HiddenWidth = lineWidth(layoutManager, container, charRange: line1Content)
        XCTAssertLessThan(line1HiddenWidth, line1RevealedWidth)
    }

    // MARK: - Decision logic

    func testIsHiddenMarkerRespectsRevealedRange() {
        let text = "**bold** tail"
        let (_, layoutManager, _) = makeStack(text)

        layoutManager.setRevealedRange(NSRange(location: 0, length: 0), force: true)
        XCTAssertTrue(layoutManager.isHiddenMarker(at: 0), "Leading * is a hidden marker off the caret line")
        XCTAssertTrue(layoutManager.isHiddenMarker(at: 7), "Trailing * is a hidden marker off the caret line")

        layoutManager.setRevealedRange(NSRange(location: 0, length: (text as NSString).length), force: true)
        XCTAssertFalse(layoutManager.isHiddenMarker(at: 0), "Revealed line keeps its markers visible")
        XCTAssertFalse(layoutManager.isHiddenMarker(at: 7), "Revealed line keeps its markers visible")
    }

    func testIsHiddenMarkerOnlyTargetsTaggedCharacters() {
        let text = "**bold** tail"
        let (_, layoutManager, _) = makeStack(text)
        layoutManager.setRevealedRange(NSRange(location: 0, length: 0), force: true)
        // Index 2 is 'b', index 9 is 't' — body text, never tagged.
        XCTAssertFalse(layoutManager.isHiddenMarker(at: 2))
        XCTAssertFalse(layoutManager.isHiddenMarker(at: 9))
    }

    func testSetRevealedRangeReportsWhetherItChanged() {
        let text = "**bold** tail"
        let (_, layoutManager, _) = makeStack(text)
        let range = NSRange(location: 0, length: 4)

        XCTAssertTrue(layoutManager.setRevealedRange(range, force: false), "First change is a real change")
        XCTAssertFalse(layoutManager.setRevealedRange(range, force: false), "Re-applying the same range is a no-op")
        XCTAssertTrue(layoutManager.setRevealedRange(range, force: true), "force overrides the no-op guard")
    }

    /// Collapsing markers is purely visual — the characters stay in storage so
    /// edits and persistence still see the literal `**…**`.
    func testHidingMarkersDoesNotMutateText() {
        let text = "**bold** tail"
        let (storage, layoutManager, container) = makeStack(text)
        layoutManager.setRevealedRange(NSRange(location: 0, length: 0), force: true)
        _ = renderedWidth(layoutManager, container)
        XCTAssertEqual(storage.string, text)
    }

    // MARK: - Table boundaries

    func testTableBoundaryBeforeCreatesBlankLineBeforeTableOnlyParagraph() {
        let fixture = makeEditorView()
        let view = fixture.0
        view.loadItems([tableOnlyItem(indent: 1)], theme: .dark, timeFormat: "twelve_hour", placeCursorAtEnd: false)

        let tableParagraph = paragraphRanges(in: view.textStorage.string as NSString)[0].fullRange
        let hit = EditorTableBoundaryHit(paragraphRange: tableParagraph, side: .before)
        XCTAssertTrue(view.placeCaretAtTableBoundary(hit, theme: .dark))

        let edits = view.extractItemEdits()
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.id, "table-item")
        XCTAssertEqual(edits.first?.text, "")
        XCTAssertEqual(view.selectedRange.location, 0)
    }

    func testTableBoundaryAfterCreatesBlankLineAfterTableOnlyParagraph() {
        let fixture = makeEditorView()
        let view = fixture.0
        view.loadItems([tableOnlyItem(indent: 2)], theme: .dark, timeFormat: "twelve_hour", placeCursorAtEnd: false)

        let tableParagraph = paragraphRanges(in: view.textStorage.string as NSString)[0].fullRange
        let hit = EditorTableBoundaryHit(paragraphRange: tableParagraph, side: .after)
        XCTAssertTrue(view.placeCaretAtTableBoundary(hit, theme: .dark))

        let edits = view.extractItemEdits()
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.id, "table-item")
        XCTAssertEqual(edits.first?.text, "")
        XCTAssertEqual(view.selectedRange.location, 1)
    }

    func testTypingAtTableBoundariesSavesAsOrderedTableContent() {
        let before = tableBoundaryEditAfterTyping(side: .before, text: "Before")
        XCTAssertEqual(before.text, "Before")
        XCTAssertEqual(before.content.count, 2)
        if case let .text(text)? = before.content.first {
            XCTAssertEqual(text, "Before")
        } else {
            XCTFail("before-table typing should save before the table")
        }
        if case .table? = before.content.last {
        } else {
            XCTFail("table should remain after before-boundary text")
        }

        let after = tableBoundaryEditAfterTyping(side: .after, text: "After")
        XCTAssertEqual(after.text, "After")
        XCTAssertEqual(after.content.count, 2)
        if case .table? = after.content.first {
        } else {
            XCTFail("table should remain before after-boundary text")
        }
        if case let .text(text)? = after.content.last {
            XCTAssertEqual(text, "After")
        } else {
            XCTFail("after-table typing should save after the table")
        }
    }

    func testTableBoundaryDeletes() {
        assertAfterTableBoundaryDelete(deletionRange: NSRange(location: 0, length: 1))
        assertAfterTableBoundaryDelete { view in
            NSRange(location: view.selectedRange.location, length: 1)
        }

        let fixture = makeEditorView()
        let view = fixture.0
        fixture.1.theme = .dark
        view.loadItems([tableOnlyItem(indent: 1)], theme: .dark, timeFormat: "twelve_hour", placeCursorAtEnd: false)

        let tableParagraph = paragraphRanges(in: view.textStorage.string as NSString)[0].fullRange
        let hit = EditorTableBoundaryHit(paragraphRange: tableParagraph, side: .before)
        XCTAssertTrue(view.placeCaretAtTableBoundary(hit, theme: .dark))
        XCTAssertEqual(view.selectedRange.location, 0)

        view.deleteBackward()

        let edits = view.extractItemEdits()
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.id, "table-item")
        XCTAssertEqual(view.selectedRange.location, 0)
    }

    // MARK: - Tagging (so future delimiter changes keep the markers concealable)

    func testEmphasisTagsEveryDelimiterStyle() {
        XCTAssertEqual(taggedRanges(for: "**b**"), [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
        XCTAssertEqual(taggedRanges(for: "__b__"), [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
        XCTAssertEqual(taggedRanges(for: "==h=="), [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
        XCTAssertEqual(taggedRanges(for: "*i*"), [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)])
        XCTAssertEqual(taggedRanges(for: "_i_"), [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)])
    }

    func testHeadingMarkerIsTagged() {
        let body = "# Title"
        let storage = NSTextStorage(string: body, attributes: [.font: UIFont.systemFont(ofSize: 17)])
        applyInlineMarkdownStyling(
            body: body,
            bodyRange: NSRange(location: 0, length: (body as NSString).length),
            in: storage
        )
        // The leading "# " (hash + one space) is the marker.
        XCTAssertEqual(markerRanges(storage), [NSRange(location: 0, length: 2)])
    }

    private func taggedRanges(for body: String) -> [NSRange] {
        let storage = NSTextStorage(string: body, attributes: [.font: UIFont.systemFont(ofSize: 17)])
        applyEmphasis(body: body, lineLocation: 0, storage: storage)
        return markerRanges(storage)
    }

    private func assertAfterTableBoundaryDelete(deletionRange: NSRange, file: StaticString = #filePath, line: UInt = #line) {
        assertAfterTableBoundaryDelete({ _ in deletionRange }, file: file, line: line)
    }

    private func assertAfterTableBoundaryDelete(_ deletionRange: (EditorTextView) -> NSRange, file: StaticString = #filePath, line: UInt = #line) {
        let fixture = makeEditorView()
        let view = fixture.0
        let coordinator = fixture.1
        coordinator.theme = .dark
        view.loadItems([tableOnlyItem(indent: 2)], theme: .dark, timeFormat: "twelve_hour", placeCursorAtEnd: false)

        let tableParagraph = paragraphRanges(in: view.textStorage.string as NSString)[0].fullRange
        let hit = EditorTableBoundaryHit(paragraphRange: tableParagraph, side: .after)
        XCTAssertTrue(view.placeCaretAtTableBoundary(hit, theme: .dark), file: file, line: line)

        let shouldAllowUIKitDelete = coordinator.textView(
            view,
            shouldChangeTextIn: deletionRange(view),
            replacementText: ""
        )

        XCTAssertFalse(shouldAllowUIKitDelete, file: file, line: line)
        let edits = view.extractItemEdits()
        XCTAssertEqual(edits.count, 1, file: file, line: line)
        XCTAssertEqual(edits.first?.id, "table-item", file: file, line: line)
        XCTAssertEqual(view.selectedRange.location, 0, file: file, line: line)
    }

    private func tableBoundaryEditAfterTyping(side: EditorTableBoundarySide, text: String, file: StaticString = #filePath, line: UInt = #line) -> MobileItemEdit {
        let fixture = makeEditorView()
        let view = fixture.0
        fixture.1.theme = .dark
        view.loadItems([tableOnlyItem(indent: 1)], theme: .dark, timeFormat: "twelve_hour", placeCursorAtEnd: false)

        let tableParagraph = paragraphRanges(in: view.textStorage.string as NSString)[0].fullRange
        let hit = EditorTableBoundaryHit(paragraphRange: tableParagraph, side: side)
        XCTAssertTrue(view.placeCaretAtTableBoundary(hit, theme: .dark), file: file, line: line)

        view.textStorage.replaceCharacters(
            in: view.selectedRange,
            with: NSAttributedString(string: text, attributes: view.typingAttributes)
        )
        view.selectedRange = NSRange(location: view.selectedRange.location + (text as NSString).length, length: 0)

        let edits = view.extractItemEdits()
        XCTAssertEqual(edits.count, 1, file: file, line: line)
        return edits[0]
    }

    private func makeEditorView() -> (EditorTextView, EditorCoordinator) {
        let view = EditorTextView()
        let coordinator = EditorCoordinator()
        coordinator.view = view
        view.coordinator = coordinator
        return (view, coordinator)
    }

    private func tableOnlyItem(indent: Int32) -> MobileItem {
        let line = MobileCellLine(
            id: "cell-line",
            text: "",
            marker: "blank",
            done: false,
            start: nil,
            end: nil,
            media: []
        )
        let table = MobileTable(
            columns: [
                MobileTableColumn(id: "column-1", name: "Column 1")
            ],
            rows: [
                MobileTableRow(
                    id: "row-1",
                    cells: [
                        MobileTableCell(text: "", lines: [line])
                    ]
                )
            ]
        )
        return MobileItem(
            id: "table-item",
            text: "",
            marker: "blank",
            indent: indent,
            kind: "procedure",
            done: false,
            start: nil,
            end: nil,
            notificationOffsetSecs: nil,
            repeatRule: nil,
            media: [],
            tables: [table],
            content: [.table(table: table)]
        )
    }
}
