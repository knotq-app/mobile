import XCTest
import UIKit
@testable import KnotQMobile

extension MarkerConcealmentTests {
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

    func testHighlightMarkersCollapseAndRevealWithCaretState() {
        let text = "Lead ==mark== tail"
        let (storage, layoutManager, container) = makeStack(text)
        let ns = text as NSString
        let wholeLine = NSRange(location: 0, length: ns.length)
        let markerIndexes = markerCharacterIndexes(storage)

        XCTAssertEqual(
            markerRanges(storage),
            [NSRange(location: 5, length: 2), NSRange(location: 11, length: 2)]
        )
        XCTAssertNotNil(
            storage.attribute(.backgroundColor, at: ns.range(of: "mark").location, effectiveRange: nil),
            "Highlighted content should stay formatted while its == markers are hidden"
        )

        layoutManager.setRevealedRange(wholeLine, force: true)
        assertMarkerCharacters(markerIndexes, hidden: false, in: layoutManager)
        let expandedWidth = lineWidth(layoutManager, container, charRange: wholeLine)

        layoutManager.setRevealedRange(NSRange(location: 0, length: 0), force: false)
        assertMarkerCharacters(markerIndexes, hidden: true, in: layoutManager)
        let formattedWidth = lineWidth(layoutManager, container, charRange: wholeLine)

        XCTAssertLessThan(
            formattedWidth,
            expandedWidth,
            "Collapsed preview should hide the == syntax without removing the highlighted text"
        )
        XCTAssertEqual(storage.string, text)
    }

    func testNestedHighlightRevealsEveryDelimiterOnCursorLine() {
        let text = "==**bold** and *italic*=="
        let (storage, layoutManager, _) = makeStack(text)
        let ns = text as NSString
        let wholeLine = NSRange(location: 0, length: ns.length)
        let markerIndexes = markerCharacterIndexes(storage)

        XCTAssertEqual(
            markerIndexes,
            [0, 1, 2, 3, 8, 9, 15, 22, 23, 24]
        )
        XCTAssertNotNil(storage.attribute(.backgroundColor, at: ns.range(of: "bold").location, effectiveRange: nil))
        XCTAssertNotNil(storage.attribute(.backgroundColor, at: ns.range(of: "italic").location, effectiveRange: nil))

        layoutManager.setRevealedRange(wholeLine, force: true)
        assertMarkerCharacters(markerIndexes, hidden: false, in: layoutManager)

        layoutManager.setRevealedRange(NSRange(location: 0, length: 0), force: false)
        assertMarkerCharacters(markerIndexes, hidden: true, in: layoutManager)
    }

    func testEditorSelectionExpandsHighlightSyntaxOnlyOnSelectedLines() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        let fixture = makeWiredEditorView()
        let view = fixture.0
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.loadItems(
            [
                textItem(id: "one", text: "==one==", indent: 0),
                textItem(id: "two", text: "==two==", indent: 0),
                textItem(id: "three", text: "==three==", indent: 0),
            ],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )
        XCTAssertTrue(view.becomeFirstResponder())

        guard let layoutManager = view.layoutManager as? EditorLayoutManager else {
            XCTFail("Expected editor layout manager")
            return
        }
        let ns = view.textStorage.string as NSString
        let paragraphs = paragraphRanges(in: ns)
        XCTAssertGreaterThanOrEqual(paragraphs.count, 3)

        let selectionStart = paragraphs[0].lineRange.location + 2
        let selectionEnd = paragraphs[1].lineRange.location + 4
        view.selectedRange = NSRange(location: selectionStart, length: selectionEnd - selectionStart)
        view.refreshMarkerVisibility(force: true)

        let markerIndexes = markerCharacterIndexes(view.textStorage)
        let selectedLineRange = NSUnionRange(paragraphs[0].lineRange, paragraphs[1].lineRange)
        let selectedMarkers = markerIndexes.filter { NSLocationInRange($0, selectedLineRange) }
        let unselectedMarkers = markerIndexes.filter { NSLocationInRange($0, paragraphs[2].lineRange) }

        XCTAssertEqual(selectedMarkers.count, 8)
        XCTAssertEqual(unselectedMarkers.count, 4)
        assertMarkerCharacters(selectedMarkers, hidden: false, in: layoutManager)
        assertMarkerCharacters(unselectedMarkers, hidden: true, in: layoutManager)

        view.resignFirstResponder()
        view.refreshMarkerVisibility(force: true)
        assertMarkerCharacters(markerIndexes, hidden: true, in: layoutManager)
        view.removeFromSuperview()
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

    // MARK: - Single-content block lines (image/table = one glyph on its own line)

    func testTableItemLoadsAsSingleGlyphLineAndExtractsAsBlock() {
        let fixture = makeEditorView()
        let view = fixture.0
        view.loadItems([tableOnlyItem(indent: 1)], theme: .dark, timeFormat: "twelve_hour", placeCursorAtEnd: false)

        // The whole line is exactly one block-object glyph (no surrounding text).
        XCTAssertEqual(view.textStorage.string, "\(blockObjectChar)\n")

        let edits = view.extractItemEdits()
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.id, "table-item")
        XCTAssertEqual(edits.first?.text, "")
        guard case .table? = edits.first?.content.first else {
            XCTFail("table item should extract as table content")
            return
        }
    }

    func testImageItemLoadsAsSingleGlyphLineAndExtractsAsBlock() {
        let fixture = makeEditorView()
        let view = fixture.0
        view.loadItems([imageOnlyItem(indent: 1)], theme: .dark, timeFormat: "twelve_hour", placeCursorAtEnd: false)

        XCTAssertEqual(view.textStorage.string, "\(blockObjectChar)\n")

        let edits = view.extractItemEdits()
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.text, "")
        guard case .image? = edits.first?.content.first else {
            XCTFail("image item should extract as image content")
            return
        }
    }

    func testTextAndBlockItemsLoadAsSeparateLines() {
        let fixture = makeEditorView()
        let view = fixture.0
        view.loadItems(
            [
                textItem(id: "before", text: "Before", indent: 1),
                tableOnlyItem(indent: 1),
                textItem(id: "after", text: "After", indent: 1)
            ],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )

        XCTAssertEqual(view.textStorage.string, "Before\n\(blockObjectChar)\nAfter\n")

        let edits = view.extractItemEdits()
        guard edits.count == 3 else {
            XCTFail("expected text/block/text to load as three lines, got \(edits.count)")
            return
        }
        XCTAssertEqual(edits[0].text, "Before")
        XCTAssertEqual(edits[1].text, "")
        guard case .table? = edits[1].content.first else {
            XCTFail("middle item should stay a table block on its own line")
            return
        }
        XCTAssertEqual(edits[2].text, "After")
    }

    func testBlockAttachmentSuppliesTransparentGlyphSoNoPlaceholderIconDraws() {
        // A nil glyph image makes TextKit stamp its default "missing attachment"
        // document icon (foreground pass) over the table/image that drawChrome
        // paints (background pass). The attachment must always return a
        // transparent image so only our render shows.
        let bounds = CGRect(x: 0, y: 0, width: 120, height: 80)
        let imageAttachment = KnotQBlockAttachment(block: .image(media: testImageMedia()), indent: 0)
        XCTAssertNotNil(
            imageAttachment.image(forBounds: bounds, textContainer: nil, characterIndex: 0),
            "image block attachment must supply a glyph image so TextKit draws no placeholder"
        )
        let tableAttachment = KnotQBlockAttachment(
            block: .table(table: MobileTable(columns: [], rows: [])),
            indent: 0
        )
        XCTAssertNotNil(
            tableAttachment.image(forBounds: bounds, textContainer: nil, characterIndex: 0),
            "table block attachment must supply a glyph image so TextKit draws no placeholder"
        )
    }

    func testDeletingSelectedTableDoesNotCrash() {
        let fixture = makeWiredEditorView()
        let view = fixture.0
        view.loadItems(
            [
                textItem(id: "a", text: "Before", indent: 0),
                tableOnlyItem(indent: 0),
                textItem(id: "b", text: "After", indent: 0)
            ],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )
        renderEditor(view)

        let paras = paragraphRanges(in: view.textStorage.string as NSString)
        let tablePara = paras[1].fullRange
        view.selectedRange = tablePara
        // Mimic the native deletion UITextView performs for a selection delete;
        // it fires `didProcessEditing` → normalize/isolate, which is where the
        // crash was reported.
        view.textStorage.replaceCharacters(in: tablePara, with: "")
        renderEditor(view)

        let edits = view.extractItemEdits()
        XCTAssertEqual(edits.map(\.text), ["Before", "After"])
        XCTAssertFalse(edits.contains { edit in
            edit.content.contains { if case .table = $0 { return true } else { return false } }
        })
    }

    func testDeleteSelectedTableThroughUIKitFirstResponderDoesNotCrash() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        let fixture = makeWiredEditorView()
        let view = fixture.0
        view.isEditable = true
        view.isSelectable = true
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.loadItems(
            [textItem(id: "a", text: "Before", indent: 0), tableOnlyItem(indent: 0), textItem(id: "b", text: "After", indent: 0)],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )
        XCTAssertTrue(view.becomeFirstResponder())
        renderEditor(view)

        let paras = paragraphRanges(in: view.textStorage.string as NSString)
        view.selectedRange = paras[1].fullRange
        // Real UIKit deletion of the selection (routes through the text input
        // machinery + delegate callbacks), the closest repro to a user delete.
        view.deleteBackward()
        renderEditor(view)

        XCTAssertFalse(view.extractItemEdits().contains { edit in
            edit.content.contains { if case .table = $0 { return true } else { return false } }
        })
        view.removeFromSuperview()
    }

    func testDeleteRichMultiCellTableThroughUIKitDoesNotCrash() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        let fixture = makeWiredEditorView()
        let view = fixture.0
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.loadItems(
            [richTableItem(indent: 0), textItem(id: "b", text: "After", indent: 0)],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )
        XCTAssertTrue(view.becomeFirstResponder())
        renderEditor(view)

        let paras = paragraphRanges(in: view.textStorage.string as NSString)
        view.selectedRange = paras[0].fullRange
        view.deleteBackward()
        renderEditor(view)

        XCTAssertFalse(view.extractItemEdits().contains { edit in
            edit.content.contains { if case .table = $0 { return true } else { return false } }
        })
        view.removeFromSuperview()
    }

    func testDeleteTableWhileCellEditorActiveDoesNotCrash() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        let fixture = makeWiredEditorView()
        let view = fixture.0
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.loadItems([richTableItem(indent: 0)], theme: .dark, timeFormat: "twelve_hour", placeCursorAtEnd: false)
        _ = view.becomeFirstResponder()
        renderEditor(view)

        // Open an in-place cell editor, then delete the whole table paragraph out
        // from under it (the overlay still references the now-gone table).
        if let hit = view.tableCellHit(itemID: "rich-table", tableIndex: 0, row: 0, column: 0) {
            view.beginEditingTableCell(hit)
        }
        let paras = paragraphRanges(in: view.textStorage.string as NSString)
        view.selectedRange = paras[0].fullRange
        view.textStorage.replaceCharacters(in: paras[0].fullRange, with: "")
        view.endTableCellEditing(commit: true)
        renderEditor(view)

        XCTAssertEqual(view.extractItemEdits(), [])
        view.removeFromSuperview()
    }

    func testDeletingTableWithChangedCellEditorDoesNotCommitStaleCell() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        let fixture = makeWiredEditorView()
        let view = fixture.0
        var commits: [(EditorTableCellHit, String)] = []
        view.onTableCellCommit = { hit, text in
            commits.append((hit, text))
        }
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.loadItems([richTableItem(indent: 0)], theme: .dark, timeFormat: "twelve_hour", placeCursorAtEnd: false)
        _ = view.becomeFirstResponder()
        renderEditor(view)

        guard let hit = view.tableCellHit(itemID: "rich-table", tableIndex: 0, row: 0, column: 0) else {
            XCTFail("Expected editable table cell")
            return
        }
        view.beginEditingTableCell(hit)
        guard let cellField = firstEmbeddedTextView(in: view) else {
            XCTFail("Expected in-place table cell field")
            return
        }
        cellField.text = "changed after delete"

        let paras = paragraphRanges(in: view.textStorage.string as NSString)
        view.selectedRange = paras[0].fullRange
        view.deleteBackward()
        renderEditor(view)

        XCTAssertTrue(commits.isEmpty)
        XCTAssertFalse(view.isEditingTableCell)
        XCTAssertEqual(view.extractItemEdits(), [])
        view.removeFromSuperview()
    }

}
