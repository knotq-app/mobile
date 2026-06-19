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

    private func assertColor(
        _ actual: UIColor?,
        equals expected: UIColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            XCTFail("Missing color", file: file, line: line)
            return
        }
        var ar: CGFloat = 0
        var ag: CGFloat = 0
        var ab: CGFloat = 0
        var aa: CGFloat = 0
        var er: CGFloat = 0
        var eg: CGFloat = 0
        var eb: CGFloat = 0
        var ea: CGFloat = 0
        XCTAssertTrue(
            actual.getRed(&ar, green: &ag, blue: &ab, alpha: &aa),
            file: file,
            line: line
        )
        XCTAssertTrue(
            expected.getRed(&er, green: &eg, blue: &eb, alpha: &ea),
            file: file,
            line: line
        )
        XCTAssertEqual(ar, er, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(ag, eg, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(ab, eb, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(aa, ea, accuracy: 0.01, file: file, line: line)
    }

    // MARK: - The core regression

    func testRestyleEditorStorageRecolorsExistingTextForThemeChange() {
        let meta = LineMeta()
        let storage = NSTextStorage(
            string: "Plain text\n",
            attributes: EditorAttributes.bodyAttributes(meta: meta, theme: .dark)
        )

        restyleEditorStorage(storage, theme: .light)

        XCTAssertEqual(storage.string, "Plain text\n")
        assertColor(
            storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor,
            equals: UIColor(KnotQTheme.light.textPrimary)
        )
    }

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

    func testSetRevealedRangeClampsEndOfDocumentRangesAfterTextShortens() {
        let (storage, layoutManager, container) = makeStack("**bold** tail\n")
        XCTAssertTrue(layoutManager.setRevealedRange(NSRange(location: storage.length, length: 0), force: false))
        layoutManager.ensureLayout(for: container)

        storage.setAttributedString(NSAttributedString(
            string: "\n",
            attributes: [.font: UIFont.systemFont(ofSize: 17)]
        ))

        XCTAssertFalse(layoutManager.setRevealedRange(NSRange(location: storage.length, length: 0), force: false))
        layoutManager.ensureLayout(for: container)
        XCTAssertLessThanOrEqual(layoutManager.revealedRange.location, storage.length)
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

    func testTypingAtTableBoundariesSavesAdjacentTextItems() {
        let before = tableBoundaryEditAfterTyping(side: .before, text: "Before")
        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(before[0].text, "Before")
        XCTAssertNil(before[0].id)
        XCTAssertEqual(before[1].id, "table-item")
        if case .table? = before[1].content.first {
        } else {
            XCTFail("table should remain after before-boundary text")
        }

        let after = tableBoundaryEditAfterTyping(side: .after, text: "After")
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after[0].id, "table-item")
        if case .table? = after[0].content.first {
        } else {
            XCTFail("table should remain before after-boundary text")
        }
        XCTAssertEqual(after[1].text, "After")
        XCTAssertNil(after[1].id)
    }

    func testBackspaceFromNonEmptyLineAfterTableMarksAdjacentBoundary() {
        let fixture = makeEditorView()
        let view = fixture.0
        let coordinator = fixture.1
        coordinator.theme = .dark
        view.loadItems(
            [tableOnlyItem(indent: 1), textItem(id: "after-item", text: "After", indent: 1)],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )

        let paragraphs = paragraphRanges(in: view.textStorage.string as NSString)
        XCTAssertEqual(paragraphs.count, 2)
        let deletionRange = NSRange(location: paragraphs[0].fullRange.location, length: 1)

        let shouldAllowUIKitDelete = coordinator.textView(
            view,
            shouldChangeTextIn: deletionRange,
            replacementText: ""
        )

        XCTAssertFalse(shouldAllowUIKitDelete)
        XCTAssertEqual(view.selectedRange.location, paragraphs[1].fullRange.location)

        let edits = view.extractItemEdits()
        XCTAssertEqual(edits.count, 2)
        XCTAssertEqual(edits.first?.id, "table-item")
        if case .table? = edits.first?.content.first {
        } else {
            XCTFail("table should remain before merged after-text")
        }
        XCTAssertEqual(edits[1].text, "After")
        XCTAssertNil(edits[1].id)
    }

    func testDeleteFromNonEmptyLineBeforeTableMarksAdjacentBoundary() {
        let fixture = makeEditorView()
        let view = fixture.0
        let coordinator = fixture.1
        coordinator.theme = .dark
        view.loadItems(
            [textItem(id: "before-item", text: "Before", indent: 1), tableOnlyItem(indent: 1)],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )

        let paragraphs = paragraphRanges(in: view.textStorage.string as NSString)
        XCTAssertEqual(paragraphs.count, 2)
        let deletionRange = NSRange(location: NSMaxRange(paragraphs[0].lineRange), length: 1)

        let shouldAllowUIKitDelete = coordinator.textView(
            view,
            shouldChangeTextIn: deletionRange,
            replacementText: ""
        )

        XCTAssertFalse(shouldAllowUIKitDelete)
        XCTAssertEqual(view.selectedRange.location, NSMaxRange(paragraphs[0].lineRange))

        let edits = view.extractItemEdits()
        XCTAssertEqual(edits.count, 2)
        XCTAssertEqual(edits[0].text, "Before")
        XCTAssertNil(edits[0].id)
        XCTAssertEqual(edits[1].id, "table-item")
        if case .table? = edits[1].content.first {
        } else {
            XCTFail("table should remain after merged before-text")
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

    func testDeletingSelectedSingleTableLeavesEmptyDocument() {
        let fixture = makeEditorView()
        let view = fixture.0
        let coordinator = fixture.1
        coordinator.theme = .dark
        view.loadItems([tableOnlyItem(indent: 1)], theme: .dark, timeFormat: "twelve_hour", placeCursorAtEnd: false)

        let tableParagraph = paragraphRanges(in: view.textStorage.string as NSString)[0].fullRange
        view.selectedRange = tableParagraph

        let shouldAllowUIKitDelete = coordinator.textView(
            view,
            shouldChangeTextIn: tableParagraph,
            replacementText: ""
        )

        XCTAssertFalse(shouldAllowUIKitDelete)
        XCTAssertEqual(view.textStorage.string, "\n")
        XCTAssertEqual(view.extractItemEdits(), [])
        XCTAssertEqual(view.selectedRange.location, 0)
    }

    func testDeletingSelectedTableBetweenTextDeletesOnlyTable() {
        let fixture = makeEditorView()
        let view = fixture.0
        let coordinator = fixture.1
        coordinator.theme = .dark
        view.loadItems(
            [
                textItem(id: "before-item", text: "Before", indent: 1),
                tableOnlyItem(indent: 1),
                textItem(id: "after-item", text: "After", indent: 1)
            ],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )

        let paragraphs = paragraphRanges(in: view.textStorage.string as NSString)
        let tableParagraph = paragraphs.first { paragraph in
            lineMeta(at: paragraph.fullRange.location, in: view.textStorage).hasBlockContent
        }
        guard let tableParagraph else {
            XCTFail("Expected table paragraph")
            return
        }
        view.selectedRange = tableParagraph.fullRange

        let shouldAllowUIKitDelete = coordinator.textView(
            view,
            shouldChangeTextIn: tableParagraph.fullRange,
            replacementText: ""
        )

        XCTAssertFalse(shouldAllowUIKitDelete)
        let edits = view.extractItemEdits()
        XCTAssertEqual(edits.count, 2)
        XCTAssertEqual(edits[0].text, "Before")
        XCTAssertEqual(edits[1].text, "After")
        XCTAssertTrue(edits.allSatisfy { edit in
            !edit.content.contains { inline in
                if case .table = inline { return true }
                return false
            }
        })
    }

    func testDeletingSelectionFromPreviousLineBreakThroughTableDoesNotCrash() {
        let fixture = makeEditorView()
        let view = fixture.0
        let coordinator = fixture.1
        coordinator.theme = .dark
        view.loadItems(
            [
                textItem(id: "before-item", text: "Before", indent: 1),
                tableOnlyItem(indent: 1),
                textItem(id: "after-item", text: "After", indent: 1)
            ],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )

        let paragraphs = paragraphRanges(in: view.textStorage.string as NSString)
        let tableParagraph = paragraphs[1]
        let selection = NSRange(
            location: NSMaxRange(paragraphs[0].lineRange),
            length: NSMaxRange(tableParagraph.fullRange) - NSMaxRange(paragraphs[0].lineRange)
        )
        view.selectedRange = selection

        let shouldAllowUIKitDelete = coordinator.textView(
            view,
            shouldChangeTextIn: selection,
            replacementText: ""
        )

        XCTAssertFalse(shouldAllowUIKitDelete)
        XCTAssertEqual(view.textStorage.string, "BeforeAfter\n")
        XCTAssertFalse(extractContainsTable(view.extractItemEdits()))
    }

    func testDeletingSelectionFromTableIntoNextLineDoesNotCrash() {
        let fixture = makeEditorView()
        let view = fixture.0
        let coordinator = fixture.1
        coordinator.theme = .dark
        view.loadItems(
            [
                textItem(id: "before-item", text: "Before", indent: 1),
                tableOnlyItem(indent: 1),
                textItem(id: "after-item", text: "After", indent: 1)
            ],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )

        let paragraphs = paragraphRanges(in: view.textStorage.string as NSString)
        let tableParagraph = paragraphs[1]
        let selection = NSRange(location: tableParagraph.fullRange.location, length: tableParagraph.fullRange.length + 2)
        view.selectedRange = selection

        let shouldAllowUIKitDelete = coordinator.textView(
            view,
            shouldChangeTextIn: selection,
            replacementText: ""
        )

        XCTAssertFalse(shouldAllowUIKitDelete)
        XCTAssertEqual(view.textStorage.string, "Before\nter\n")
        XCTAssertFalse(extractContainsTable(view.extractItemEdits()))
    }

    func testRichCopyPastePreservesTableContent() {
        let sourceFixture = makeEditorView()
        let source = sourceFixture.0
        source.loadItems([tableOnlyItem(indent: 1)], theme: .dark, timeFormat: "twelve_hour", placeCursorAtEnd: false)
        XCTAssertGreaterThan(source.textStorage.length, 0)
        source.selectedRange = NSRange(location: 0, length: source.textStorage.length)

        source.copy(nil)

        let destinationFixture = makeEditorView()
        let destination = destinationFixture.0
        destination.loadItems([], theme: .dark, timeFormat: "twelve_hour", placeCursorAtEnd: false)
        destination.selectedRange = NSRange(location: 0, length: 0)
        destination.paste(nil)

        let edits = destination.extractItemEdits()
        XCTAssertEqual(edits.count, 1)
        guard case let .table(table)? = edits.first?.content.first else {
            XCTFail("pasted item should retain table content")
            return
        }
        XCTAssertEqual(table.columns.first?.name, "Column 1")
        XCTAssertEqual(table.rows.first?.id, "row-1")
    }

    // MARK: - Image boundaries

    func testImageBlockBoundaryHitComputesBeforeAndAfterWithoutDrawCache() {
        let fixture = makeEditorView()
        let view = fixture.0
        fixture.1.theme = .dark
        view.frame = CGRect(x: 0, y: 0, width: 420, height: 360)
        view.textContainer.size = CGSize(width: 420, height: CGFloat.greatestFiniteMagnitude)
        view.loadItems([imageOnlyItem(indent: 1)], theme: .dark, timeFormat: "twelve_hour", placeCursorAtEnd: false)

        guard let before = firstBoundaryHit(in: view, matching: .before) else {
            XCTFail("Expected a computed before-block hit before any draw cache exists")
            return
        }
        guard let after = firstBoundaryHit(in: view, matching: .after) else {
            XCTFail("Expected a computed after-block hit before any draw cache exists")
            return
        }

        XCTAssertTrue(view.placeCaretAtTableBoundary(before, theme: .dark))
        XCTAssertEqual(view.selectedRange.location, 0)
        XCTAssertTrue(view.placeCaretAtTableBoundary(after, theme: .dark))
        XCTAssertGreaterThan(view.selectedRange.location, 0)
    }

    func testTypingAtImageBoundariesSavesAdjacentTextItems() {
        let before = imageBoundaryEditAfterTyping(side: .before, text: "Before")
        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(before[0].text, "Before")
        XCTAssertNil(before[0].id)
        XCTAssertEqual(before[1].id, "image-item")
        if case .image? = before[1].content.first {
        } else {
            XCTFail("image should remain after before-boundary text")
        }

        let after = imageBoundaryEditAfterTyping(side: .after, text: "After")
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after[0].id, "image-item")
        if case .image? = after[0].content.first {
        } else {
            XCTFail("image should remain before after-boundary text")
        }
        XCTAssertEqual(after[1].text, "After")
        XCTAssertNil(after[1].id)
    }

    func testBackspaceFromNonEmptyLineAfterImageMarksAdjacentBoundary() {
        let fixture = makeEditorView()
        let view = fixture.0
        let coordinator = fixture.1
        coordinator.theme = .dark
        view.loadItems(
            [imageOnlyItem(indent: 1), textItem(id: "after-image-item", text: "After", indent: 1)],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )

        let paragraphs = paragraphRanges(in: view.textStorage.string as NSString)
        XCTAssertEqual(paragraphs.count, 2)
        let deletionRange = NSRange(location: paragraphs[0].fullRange.location, length: 1)

        let shouldAllowUIKitDelete = coordinator.textView(
            view,
            shouldChangeTextIn: deletionRange,
            replacementText: ""
        )

        XCTAssertFalse(shouldAllowUIKitDelete)
        XCTAssertEqual(view.selectedRange.location, paragraphs[1].fullRange.location)

        let edits = view.extractItemEdits()
        XCTAssertEqual(edits.count, 2)
        XCTAssertEqual(edits.first?.id, "image-item")
        if case .image? = edits.first?.content.first {
        } else {
            XCTFail("image should remain before merged after-text")
        }
        XCTAssertEqual(edits[1].text, "After")
        XCTAssertNil(edits[1].id)
    }

    func testDeleteFromNonEmptyLineBeforeImageMarksAdjacentBoundary() {
        let fixture = makeEditorView()
        let view = fixture.0
        let coordinator = fixture.1
        coordinator.theme = .dark
        view.loadItems(
            [textItem(id: "before-image-item", text: "Before", indent: 1), imageOnlyItem(indent: 1)],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )

        let paragraphs = paragraphRanges(in: view.textStorage.string as NSString)
        XCTAssertEqual(paragraphs.count, 2)
        let deletionRange = NSRange(location: NSMaxRange(paragraphs[0].lineRange), length: 1)

        let shouldAllowUIKitDelete = coordinator.textView(
            view,
            shouldChangeTextIn: deletionRange,
            replacementText: ""
        )

        XCTAssertFalse(shouldAllowUIKitDelete)
        XCTAssertEqual(view.selectedRange.location, NSMaxRange(paragraphs[0].lineRange))

        let edits = view.extractItemEdits()
        XCTAssertEqual(edits.count, 2)
        XCTAssertEqual(edits[0].text, "Before")
        XCTAssertNil(edits[0].id)
        XCTAssertEqual(edits[1].id, "image-item")
        if case .image? = edits[1].content.first {
        } else {
            XCTFail("image should remain after merged before-text")
        }
    }

    func testBackspaceAfterImageBoundaryDeletesImageBlock() {
        let fixture = makeEditorView()
        let view = fixture.0
        let coordinator = fixture.1
        coordinator.theme = .dark
        view.loadItems([imageOnlyItem(indent: 1)], theme: .dark, timeFormat: "twelve_hour", placeCursorAtEnd: false)

        let imageParagraph = paragraphRanges(in: view.textStorage.string as NSString)[0].fullRange
        let hit = EditorTableBoundaryHit(paragraphRange: imageParagraph, side: .after)
        XCTAssertTrue(view.placeCaretAtTableBoundary(hit, theme: .dark))

        let shouldAllowUIKitDelete = coordinator.textView(
            view,
            shouldChangeTextIn: NSRange(location: 0, length: 1),
            replacementText: ""
        )

        XCTAssertFalse(shouldAllowUIKitDelete)
        XCTAssertEqual(view.extractItemEdits(), [])
        XCTAssertEqual(view.selectedRange.location, 0)
    }

    func testDeletingSelectionFromImageIntoNextLineDoesNotCrash() {
        let fixture = makeEditorView()
        let view = fixture.0
        let coordinator = fixture.1
        coordinator.theme = .dark
        view.loadItems(
            [
                textItem(id: "before-image-item", text: "Before", indent: 1),
                imageOnlyItem(indent: 1),
                textItem(id: "after-image-item", text: "After", indent: 1)
            ],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )

        let paragraphs = paragraphRanges(in: view.textStorage.string as NSString)
        let imageParagraph = paragraphs[1]
        let selection = NSRange(location: imageParagraph.fullRange.location, length: imageParagraph.fullRange.length + 2)
        view.selectedRange = selection

        let shouldAllowUIKitDelete = coordinator.textView(
            view,
            shouldChangeTextIn: selection,
            replacementText: ""
        )

        XCTAssertFalse(shouldAllowUIKitDelete)
        XCTAssertEqual(view.textStorage.string, "Before\nter\n")
        XCTAssertFalse(extractContainsImage(view.extractItemEdits()))
    }

    func testImageTrailingTextSplitsIntoBoundaryParagraphOnLoad() {
        let fixture = makeEditorView()
        let view = fixture.0
        view.loadItems([imageThenTextItem(text: "After", indent: 1)], theme: .dark, timeFormat: "twelve_hour", placeCursorAtEnd: false)

        let paragraphs = paragraphRanges(in: view.textStorage.string as NSString)
        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(testParagraphBody(paragraphs[0], in: view.textStorage.string as NSString), "")
        XCTAssertEqual(testParagraphBody(paragraphs[1], in: view.textStorage.string as NSString), "After")

        let edits = view.extractItemEdits()
        XCTAssertEqual(edits.count, 2)
        XCTAssertEqual(edits.first?.id, "image-item")
        if case .image? = edits.first?.content.first {
        } else {
            XCTFail("image should remain before split trailing text")
        }
        XCTAssertEqual(edits[1].text, "After")
        XCTAssertNil(edits[1].id)
    }

    func testControllerCommitFlushesActiveTableCellEdit() {
        let fixture = makeEditorView()
        let view = fixture.0
        let controller = EditorController()
        controller.view = view
        var commits: [(EditorTableCellHit, String)] = []
        view.onTableCellCommit = { hit, text in
            commits.append((hit, text))
        }

        view.beginEditingTableCell(EditorTableCellHit(
            itemID: "table-item",
            tableIndex: 0,
            row: 0,
            column: 0,
            text: "Old",
            frame: CGRect(x: 10, y: 10, width: 120, height: 40)
        ))
        guard let field = firstEmbeddedTextView(in: view) else {
            XCTFail("Expected in-place table cell field")
            return
        }

        field.text = "New"
        _ = controller.commit()

        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.0.itemID, "table-item")
        XCTAssertEqual(commits.first?.1, "New")
        XCTAssertFalse(view.isEditingTableCell)
    }

    // MARK: - Tagging (so future delimiter changes keep the markers concealable)

    func testEmphasisTagsEveryDelimiterStyle() {
        XCTAssertEqual(taggedRanges(for: "**b**"), [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
        XCTAssertEqual(taggedRanges(for: "__b__"), [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
        XCTAssertEqual(taggedRanges(for: "==h=="), [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
        XCTAssertEqual(taggedRanges(for: "~~s~~"), [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
        XCTAssertEqual(taggedRanges(for: "*i*"), [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)])
        XCTAssertEqual(taggedRanges(for: "_i_"), [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)])
    }

    func testStrikethroughMarkdownAppliesAttribute() {
        let body = "Keep ~~remove~~"
        let storage = NSTextStorage(
            string: body,
            attributes: [.font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor.label]
        )

        applyInlineMarkdownStyling(
            body: body,
            bodyRange: NSRange(location: 0, length: (body as NSString).length),
            in: storage
        )

        let struckRange = (body as NSString).range(of: "remove")
        XCTAssertEqual(
            storage.attribute(.strikethroughStyle, at: struckRange.location, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
    }

    func testMarkdownDisplayAttributedStringConcealsMarkersAndKeepsCompactFont() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13),
            .foregroundColor: UIColor.label
        ]

        let rendered = markdownDisplayAttributedString(
            body: "**Bold** ==Mark== ~~Gone~~",
            attributes: attributes,
            baseFont: UIFont.systemFont(ofSize: 13)
        )

        XCTAssertEqual(rendered.string, "Bold Mark Gone")
        let ns = rendered.string as NSString
        let boldRange = ns.range(of: "Bold")
        let markRange = ns.range(of: "Mark")
        let goneRange = ns.range(of: "Gone")
        let boldFont = rendered.attribute(.font, at: boldRange.location, effectiveRange: nil) as? UIFont
        XCTAssertEqual(boldFont?.pointSize, 13)
        XCTAssertTrue(boldFont?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false)
        XCTAssertNotNil(rendered.attribute(.backgroundColor, at: markRange.location, effectiveRange: nil))
        XCTAssertEqual(
            rendered.attribute(.strikethroughStyle, at: goneRange.location, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
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
        XCTAssertEqual(edits.count, 0, file: file, line: line)
        XCTAssertEqual(view.selectedRange.location, 0, file: file, line: line)
    }

    private func tableBoundaryEditAfterTyping(side: EditorTableBoundarySide, text: String, file: StaticString = #filePath, line: UInt = #line) -> [MobileItemEdit] {
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
        return edits
    }

    private func imageBoundaryEditAfterTyping(side: EditorTableBoundarySide, text: String, file: StaticString = #filePath, line: UInt = #line) -> [MobileItemEdit] {
        let fixture = makeEditorView()
        let view = fixture.0
        fixture.1.theme = .dark
        view.loadItems([imageOnlyItem(indent: 1)], theme: .dark, timeFormat: "twelve_hour", placeCursorAtEnd: false)

        let imageParagraph = paragraphRanges(in: view.textStorage.string as NSString)[0].fullRange
        let hit = EditorTableBoundaryHit(paragraphRange: imageParagraph, side: side)
        XCTAssertTrue(view.placeCaretAtTableBoundary(hit, theme: .dark), file: file, line: line)

        view.textStorage.replaceCharacters(
            in: view.selectedRange,
            with: NSAttributedString(string: text, attributes: view.typingAttributes)
        )
        view.selectedRange = NSRange(location: view.selectedRange.location + (text as NSString).length, length: 0)

        let edits = view.extractItemEdits()
        return edits
    }

    private func firstBoundaryHit(in view: EditorTextView, matching side: EditorTableBoundarySide) -> EditorTableBoundaryHit? {
        for y in stride(from: CGFloat(0), through: view.bounds.height, by: CGFloat(3)) {
            for x in stride(from: CGFloat(0), through: view.bounds.width, by: CGFloat(3)) {
                guard let hit = view.tableBoundaryHit(at: CGPoint(x: x, y: y)) else { continue }
                switch (hit.side, side) {
                case (.before, .before), (.after, .after):
                    return hit
                default:
                    continue
                }
            }
        }
        return nil
    }

    private func firstEmbeddedTextView(in root: UIView) -> UITextView? {
        for subview in root.subviews {
            if let textView = subview as? UITextView, textView !== root {
                return textView
            }
            if let nested = firstEmbeddedTextView(in: subview) {
                return nested
            }
        }
        return nil
    }

    private func extractContainsTable(_ edits: [MobileItemEdit]) -> Bool {
        edits.contains { edit in
            edit.content.contains { inline in
                if case .table = inline { return true }
                return false
            }
        }
    }

    private func extractContainsImage(_ edits: [MobileItemEdit]) -> Bool {
        edits.contains { edit in
            edit.content.contains { inline in
                if case .image = inline { return true }
                return false
            }
        }
    }

    private func testParagraphBody(_ paragraph: EditorParagraphRange, in ns: NSString) -> String {
        paragraph.lineRange.length > 0 ? ns.substring(with: paragraph.lineRange) : ""
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

    private func imageOnlyItem(indent: Int32) -> MobileItem {
        let media = testImageMedia()
        return MobileItem(
            id: "image-item",
            text: "",
            marker: "blank",
            indent: indent,
            kind: "procedure",
            done: false,
            start: nil,
            end: nil,
            notificationOffsetSecs: nil,
            repeatRule: nil,
            media: [media],
            tables: [],
            content: [.image(media: media)]
        )
    }

    private func imageThenTextItem(text: String, indent: Int32) -> MobileItem {
        let media = testImageMedia()
        return MobileItem(
            id: "image-item",
            text: text,
            marker: "blank",
            indent: indent,
            kind: "procedure",
            done: false,
            start: nil,
            end: nil,
            notificationOffsetSecs: nil,
            repeatRule: nil,
            media: [media],
            tables: [],
            content: [.image(media: media), .text(text: text)]
        )
    }

    private func testImageMedia() -> MobileItemMedia {
        MobileItemMedia(kind: "image", path: nil, format: "png", width: 320, height: 200)
    }

    private func textItem(id: String, text: String, indent: Int32) -> MobileItem {
        MobileItem(
            id: id,
            text: text,
            marker: "blank",
            indent: indent,
            kind: "procedure",
            done: false,
            start: nil,
            end: nil,
            notificationOffsetSecs: nil,
            repeatRule: nil,
            media: [],
            tables: [],
            content: [.text(text: text)]
        )
    }
}
