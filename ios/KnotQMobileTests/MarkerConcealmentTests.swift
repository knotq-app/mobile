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

    private func pumpRunLoop() {
        let drained = expectation(description: "run loop drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    func testDeleteLastRowTableGlyphThroughUIKitDoesNotCrash() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        let fixture = makeWiredEditorView()
        let view = fixture.0
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.loadItems(
            [textItem(id: "a", text: "Line one", indent: 0), textItem(id: "b", text: "Line two", indent: 0), tableOnlyItem(indent: 0)],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )
        _ = view.becomeFirstResponder()
        renderEditor(view)

        // Table is the last paragraph; its "\n" is the document's trailing
        // newline. Select just the glyph and delete.
        let paras = paragraphRanges(in: view.textStorage.string as NSString)
        view.selectedRange = paras[2].lineRange   // the lone block glyph
        view.deleteBackward()
        pumpRunLoop()          // let UIKit's deferred layout/draw fire
        renderEditor(view)

        XCTAssertFalse(view.extractItemEdits().contains { edit in
            edit.content.contains { if case .table = $0 { return true } else { return false } }
        })
        view.removeFromSuperview()
    }

    func testDeleteLastRowTableWholeParagraphThroughUIKitDoesNotCrash() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        let fixture = makeWiredEditorView()
        let view = fixture.0
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.loadItems(
            [textItem(id: "a", text: "Line one", indent: 0), tableOnlyItem(indent: 0)],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )
        _ = view.becomeFirstResponder()
        renderEditor(view)

        // Select the table's WHOLE paragraph — including the document's trailing
        // "\n" — then delete; this removes the trailing newline.
        let paras = paragraphRanges(in: view.textStorage.string as NSString)
        view.selectedRange = paras[1].fullRange
        view.deleteBackward()
        pumpRunLoop()
        renderEditor(view)

        XCTAssertFalse(view.extractItemEdits().contains { edit in
            edit.content.contains { if case .table = $0 { return true } else { return false } }
        })
        view.removeFromSuperview()
    }

    func testDeleteLastRowTableInSelfSizingDailyEditorDoesNotCrash() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        let fixture = makeWiredEditorView()
        let view = fixture.0
        view.isScrollEnabled = false   // Daily-feed self-sizing mode
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.loadItems(
            [textItem(id: "a", text: "Line one", indent: 0), textItem(id: "b", text: "Line two", indent: 0), tableOnlyItem(indent: 0)],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )
        _ = view.becomeFirstResponder()
        _ = view.measuredHeight(forWidth: 400)
        renderEditor(view)

        let paras = paragraphRanges(in: view.textStorage.string as NSString)
        view.selectedRange = paras[2].fullRange
        view.deleteBackward()
        // Self-sizing re-measure path (the deferred Auto Layout / draw cycle).
        _ = view.measuredHeight(forWidth: 400)
        _ = view.intrinsicContentSize
        view.refreshEmbeddedLayoutIfNeeded()
        pumpRunLoop()
        _ = view.measuredHeight(forWidth: 400)
        renderEditor(view)

        XCTAssertFalse(view.extractItemEdits().contains { edit in
            edit.content.contains { if case .table = $0 { return true } else { return false } }
        })
        view.removeFromSuperview()
    }

    func testDeleteOnlyTableInSelfSizingDailyEditorDoesNotCrash() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        let fixture = makeWiredEditorView()
        let view = fixture.0
        view.isScrollEnabled = false
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.loadItems([tableOnlyItem(indent: 0)], theme: .dark, timeFormat: "twelve_hour", placeCursorAtEnd: false)
        _ = view.becomeFirstResponder()
        _ = view.measuredHeight(forWidth: 400)
        renderEditor(view)

        let paras = paragraphRanges(in: view.textStorage.string as NSString)
        view.selectedRange = paras[0].fullRange
        view.deleteBackward()
        _ = view.measuredHeight(forWidth: 400)
        _ = view.intrinsicContentSize
        view.refreshEmbeddedLayoutIfNeeded()
        pumpRunLoop()
        renderEditor(view)

        XCTAssertEqual(view.extractItemEdits(), [])
        view.removeFromSuperview()
    }

    func testCutSelectedTableDoesNotCrash() {
        let fixture = makeWiredEditorView()
        let view = fixture.0
        view.loadItems(
            [textItem(id: "a", text: "Before", indent: 0), tableOnlyItem(indent: 0)],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )
        renderEditor(view)

        let paras = paragraphRanges(in: view.textStorage.string as NSString)
        view.selectedRange = paras[1].fullRange
        view.cut(nil)
        renderEditor(view)

        XCTAssertFalse(view.extractItemEdits().contains { edit in
            edit.content.contains { if case .table = $0 { return true } else { return false } }
        })
    }

    func testPartialDeleteMergingTextIntoTableIsolatesGlyphWithoutCrash() {
        let fixture = makeWiredEditorView()
        let view = fixture.0
        view.loadItems(
            [textItem(id: "a", text: "Before", indent: 0), tableOnlyItem(indent: 0), textItem(id: "b", text: "After", indent: 0)],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )
        renderEditor(view)

        let paras = paragraphRanges(in: view.textStorage.string as NSString)
        // Delete "fore\n" so "Be" would merge onto the table's glyph line; the
        // deferred isolate backstop must split it back apart (and not crash).
        let start = paras[0].fullRange.location + 2
        let end = paras[1].fullRange.location
        view.selectedRange = NSRange(location: start, length: end - start)
        view.textStorage.replaceCharacters(in: NSRange(location: start, length: end - start), with: "")
        renderEditor(view)

        // The isolate pass is deferred (length changes are unsafe inside the edit
        // callback); pump the run loop so it runs, then re-render.
        let drained = expectation(description: "deferred isolate pass")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        renderEditor(view)

        // "Be" and the table end up on separate lines; the table survives.
        let edits = view.extractItemEdits()
        XCTAssertEqual(edits.first?.text, "Be")
        XCTAssertTrue(edits.contains { edit in
            edit.content.contains { if case .table = $0 { return true } else { return false } }
        })
    }

    func testSelectAllDeleteWithTableDoesNotCrash() {
        let fixture = makeWiredEditorView()
        let view = fixture.0
        view.loadItems(
            [textItem(id: "a", text: "Before", indent: 0), tableOnlyItem(indent: 0)],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )
        renderEditor(view)

        let whole = NSRange(location: 0, length: view.textStorage.length)
        view.selectedRange = whole
        view.textStorage.replaceCharacters(in: whole, with: "")
        renderEditor(view)

        XCTAssertEqual(view.extractItemEdits(), [])
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

    private func makeEditorView() -> (EditorTextView, EditorCoordinator) {
        let view = EditorTextView()
        let coordinator = EditorCoordinator()
        coordinator.view = view
        view.coordinator = coordinator
        return (view, coordinator)
    }

    /// Like `makeEditorView` but wired the way `SchemeTextView.makeUIView` does:
    /// the coordinator is the text-storage delegate (so a native edit runs the
    /// `didProcessEditing` → normalize/isolate pass) and the view has real bounds
    /// (so layout + `drawChrome` run). Used to reproduce edit-time crashes.
    private func makeWiredEditorView() -> (EditorTextView, EditorCoordinator) {
        let view = EditorTextView()
        let coordinator = EditorCoordinator()
        coordinator.view = view
        coordinator.theme = .dark
        view.coordinator = coordinator
        view.delegate = coordinator
        view.textStorage.delegate = coordinator
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 700)
        view.textContainer.size = CGSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        return (view, coordinator)
    }

    /// Forces layout + the custom `drawChrome` pass so a render-time crash (stale
    /// table geometry after an edit) surfaces in the test.
    private func renderEditor(_ view: EditorTextView) {
        view.layoutManager.ensureLayout(for: view.textContainer)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 700))
        _ = renderer.image { ctx in view.layer.render(in: ctx.cgContext) }
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

    private func richTableItem(indent: Int32) -> MobileItem {
        func cell(_ id: String, _ text: String) -> MobileTableCell {
            MobileTableCell(
                text: text,
                lines: [MobileCellLine(id: id, text: text, marker: "blank", done: false, start: nil, end: nil, media: [])]
            )
        }
        let table = MobileTable(
            columns: [
                MobileTableColumn(id: "c1", name: "A"),
                MobileTableColumn(id: "c2", name: "B")
            ],
            rows: [
                MobileTableRow(id: "r1", cells: [cell("r1c1", "1a"), cell("r1c2", "1b")]),
                MobileTableRow(id: "r2", cells: [cell("r2c1", "2a"), cell("r2c2", "2b")])
            ]
        )
        return MobileItem(
            id: "rich-table",
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
