import XCTest
import UIKit
@testable import KnotQMobile

extension MarkerConcealmentTests {
    func pumpRunLoop() {
        let drained = expectation(description: "run loop drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    func exerciseDailyLayout(_ view: EditorTextView) {
        _ = view.measuredHeight(forWidth: 400)
        _ = view.intrinsicContentSize
        view.refreshEmbeddedLayoutIfNeeded()
        pumpRunLoop()
        _ = view.measuredHeight(forWidth: 400)
        renderEditor(view)
    }

    func applyTextReplacement(
        _ text: String,
        in range: NSRange? = nil,
        view: EditorTextView,
        coordinator: EditorCoordinator
    ) {
        let editRange = range ?? view.selectedRange
        if coordinator.textView(view, shouldChangeTextIn: editRange, replacementText: text) {
            let attributed = NSAttributedString(string: text, attributes: view.typingAttributes)
            view.textStorage.replaceCharacters(in: editRange, with: attributed)
            view.selectedRange = NSRange(
                location: editRange.location + (text as NSString).length,
                length: 0
            )
        }
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

    func testDailyTableNewlineTypingDeletionAndMarkerChangeDoesNotCrash() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        let fixture = makeWiredEditorView()
        let view = fixture.0
        let coordinator = fixture.1
        view.isScrollEnabled = false
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.loadItems(
            [textItem(id: "before", text: "Before", indent: 0), tableOnlyItem(indent: 0)],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )
        _ = view.becomeFirstResponder()
        exerciseDailyLayout(view)

        let paras = paragraphRanges(in: view.textStorage.string as NSString)
        view.selectedRange = NSRange(location: NSMaxRange(paras[1].lineRange), length: 0)
        applyTextReplacement("\n", view: view, coordinator: coordinator)
        exerciseDailyLayout(view)

        applyTextReplacement("daily table fallout", view: view, coordinator: coordinator)
        exerciseDailyLayout(view)

        for _ in 0..<5 {
            view.deleteBackward()
        }
        exerciseDailyLayout(view)

        view.setCurrentMarker(.checkbox, theme: .dark)
        exerciseDailyLayout(view)
        view.setCurrentMarker(.bullet, theme: .dark)
        exerciseDailyLayout(view)

        let edits = view.extractItemEdits()
        XCTAssertTrue(edits.contains { edit in
            edit.content.contains { if case .table = $0 { return true } else { return false } }
        })
        let typedLine = edits.first { $0.text.contains("daily table") }
        XCTAssertEqual(typedLine?.text, "daily table fa")
        XCTAssertEqual(typedLine?.marker, "bullet")
        view.removeFromSuperview()
    }

    /// Repro for the instant-insert crash: tapping the table toolbar button
    /// mutates the text storage synchronously (the toolbar lives in the keyboard
    /// input-accessory, so this fires while the text input session is live), and
    /// a later layout pass read `characterAtIndex(length)` on a stale glyph map.
    /// Insert a table at the end of a realistic document, then force the deferred
    /// layout/draw cycle and a follow-up edit.
    func testInsertTableBlockThroughToolbarPathDoesNotCrash() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        let fixture = makeWiredEditorView()
        let view = fixture.0
        let coordinator = fixture.1
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.loadItems(
            (0..<6).map { textItem(id: "line-\($0)", text: "Line number \($0) with some body text", indent: 0) },
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: true
        )
        XCTAssertTrue(view.becomeFirstResponder())
        renderEditor(view)

        // Exactly what the toolbar button does.
        view.insertTableBlock(itemID: UUID().uuidString, theme: .dark)
        renderEditor(view)
        pumpRunLoop()              // let UIKit's deferred layout/draw fire
        renderEditor(view)

        // Drive the *real* UIKit text-input path after the out-of-band insert.
        // UITextView's input interaction cached document offsets for the old
        // contents; insertText/deleteBackward use them, which is where the stale
        // map read `characterAtIndex(length)`.
        view.insertText("x")
        view.insertText("y")
        view.deleteBackward()
        renderEditor(view)
        pumpRunLoop()
        renderEditor(view)

        XCTAssertTrue(view.extractItemEdits().contains { edit in
            edit.content.contains { if case .table = $0 { return true } else { return false } }
        })
        view.removeFromSuperview()
    }

    /// Regression guard: inserting a table while marked text (in-progress
    /// autocorrect/IME composition) is live, then reconciling it, must not crash.
    func testInsertTableWithActiveMarkedTextDoesNotCrash() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let fixture = makeWiredEditorView()
        let view = fixture.0
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.loadItems(
            (0..<8).map { textItem(id: "line-\($0)", text: "Line number \($0) with body text", indent: 0) },
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: true
        )
        XCTAssertTrue(view.becomeFirstResponder())
        renderEditor(view)

        // Simulate an in-progress autocorrect/IME composition at the caret.
        view.selectedRange = NSRange(location: view.textStorage.length - 1, length: 0)
        view.insertText("teh")
        view.setMarkedText("teh", selectedRange: NSRange(location: 0, length: 3))
        renderEditor(view)

        // Tap the table button while marked text is live.
        view.insertTableBlock(itemID: UUID().uuidString, theme: .dark)
        renderEditor(view)

        // Now let the input session reconcile its (formerly stale) marked range.
        view.unmarkText()
        view.insertText("z")
        view.deleteBackward()
        renderEditor(view)
        pumpRunLoop()
        renderEditor(view)

        XCTAssertTrue(view.extractItemEdits().contains { edit in
            edit.content.contains { if case .table = $0 { return true } else { return false } }
        })
        view.removeFromSuperview()
    }

    /// Same path in the self-sizing Daily editor, which re-measures intrinsic
    /// size after every mutation — the other place the stale-map crash surfaced.
    func testInsertTableBlockInSelfSizingDailyEditorDoesNotCrash() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        let fixture = makeWiredEditorView()
        let view = fixture.0
        view.isScrollEnabled = false
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.loadItems(
            (0..<4).map { textItem(id: "line-\($0)", text: "Daily line \($0)", indent: 0) },
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: true
        )
        _ = view.becomeFirstResponder()
        _ = view.measuredHeight(forWidth: 400)
        renderEditor(view)

        view.insertTableBlock(itemID: UUID().uuidString, theme: .dark)
        exerciseDailyLayout(view)

        XCTAssertTrue(view.extractItemEdits().contains { edit in
            edit.content.contains { if case .table = $0 { return true } else { return false } }
        })
        view.removeFromSuperview()
    }

    /// Regression guard: fast typing on the line right after a table, driving the
    /// real UIKit input path (insertText / newline / deleteBackward) interleaved
    /// with the deferred isolate/bulletize/display passes, must not crash.
    func testFastTypingOnLineAfterTableDoesNotCrash() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let fixture = makeWiredEditorView()
        let view = fixture.0
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.loadItems(
            [textItem(id: "a", text: "Heading", indent: 0), tableOnlyItem(indent: 0)],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: true
        )
        XCTAssertTrue(view.becomeFirstResponder())
        renderEditor(view)

        // Land the caret right after the table and open a fresh line under it.
        view.selectedRange = NSRange(location: view.textStorage.length - 1, length: 0)
        view.insertText("\n")
        renderEditor(view)

        // Hammer the bottom line: chars, marker triggers, newlines, backspaces —
        // pumping the run loop mid-stream so the deferred passes interleave.
        let burst = Array("the quick brown fox - jumps\nover ")
        for (index, character) in burst.enumerated() {
            view.insertText(String(character))
            if index % 4 == 0 { pumpRunLoop() }
            if index % 7 == 0 { view.deleteBackward() }
            renderEditor(view)
        }
        for _ in 0..<15 { view.deleteBackward() }   // backspace toward the table
        pumpRunLoop()
        renderEditor(view)

        XCTAssertTrue(view.extractItemEdits().contains { edit in
            edit.content.contains { if case .table = $0 { return true } else { return false } }
        })
        view.removeFromSuperview()
    }

    /// The real production crash (fully symbolicated): `didProcessEditing` runs
    /// *before* the layout manager processes the edit, so invalidating embedded
    /// block display there forces `_boundingRectForGlyphRange` against a stale
    /// glyph map. A length-*reducing* edit (UIKit autocorrection's `delta -1`)
    /// leaves that map referencing char index == the new length, so TextKit reads
    /// `characterAtIndex(length)` and throws. Reproduced by a mid-document
    /// shrink-replace on a document containing a table.
    func testShrinkEditDuringProcessEditingWithTableDoesNotCrash() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let fixture = makeWiredEditorView()
        let view = fixture.0
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.loadItems(
            [
                textItem(id: "h", text: "Heading line at the top of the document", indent: 0),
                tableOnlyItem(indent: 0),
                textItem(id: "b", text: "the quick brown fox jumps over the lazy dog and keeps going long enough to wrap", indent: 0),
            ],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )
        XCTAssertTrue(view.becomeFirstResponder())
        renderEditor(view)   // lay out glyphs for the full (longer) content

        // Mimic an autocorrection accept: replace a mid-document word with a
        // shorter one (delta < 0), leaving content after it. Fires
        // didProcessEditing while the layout manager still has the old glyphs.
        let ns = view.textStorage.string as NSString
        let quick = ns.range(of: "quick")
        XCTAssertNotEqual(quick.location, NSNotFound)
        view.textStorage.replaceCharacters(in: quick, with: "quik")   // 5 -> 4 chars
        renderEditor(view)
        pumpRunLoop()
        renderEditor(view)
        view.removeFromSuperview()
    }

    func testTapBelowTrailingTableLandsCaretAfterBlock() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let fixture = makeWiredEditorView()
        let view = fixture.0
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.loadItems(
            [textItem(id: "a", text: "Before", indent: 0), tableOnlyItem(indent: 0)],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )
        renderEditor(view)

        let ns = view.textStorage.string as NSString
        let lastParagraph = ns.paragraphRange(for: NSRange(location: view.textStorage.length - 1, length: 0))
        let afterBlock = lastParagraph.location + 1

        // A tap far below everything resolves to the position right after the
        // block, not into the table.
        guard let position = view.closestPosition(to: CGPoint(x: 30, y: 4000)) else {
            XCTFail("expected a caret position below the table"); return
        }
        XCTAssertEqual(
            view.offset(from: view.beginningOfDocument, to: position),
            afterBlock,
            "tap below the trailing table should land right after the block"
        )
        view.removeFromSuperview()
    }

    func testGutterAndSeamTapsLandCaretBeforeOrAfterMidDocumentTable() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let fixture = makeWiredEditorView()
        let view = fixture.0
        // Mimic production insets so the table leaves real left/right gutters.
        view.textContainer.lineFragmentPadding = 0
        view.textContainerInset = UIEdgeInsets(top: 8, left: 35, bottom: 8, right: 24)
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.loadItems(
            [
                textItem(id: "before", text: "Before", indent: 0),
                tableOnlyItem(indent: 0),
                textItem(id: "after", text: "After", indent: 0),
            ],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )
        renderEditor(view)

        let ns = view.textStorage.string as NSString
        let tablePara = paragraphRanges(in: ns)[1]
        view.layoutManager.ensureLayout(for: view.textContainer)
        let glyphRange = view.layoutManager.glyphRange(forCharacterRange: tablePara.fullRange, actualCharacterRange: nil)
        let frag = view.layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let top = frag.minY + view.textContainerInset.top
        let bottom = frag.maxY + view.textContainerInset.top
        let midY = (top + bottom) / 2

        func offset(_ point: CGPoint) -> Int? {
            view.blockEdgeCaret(point).map { view.offset(from: view.beginningOfDocument, to: $0) }
        }
        let before = tablePara.fullRange.location
        let after = before + 1

        XCTAssertEqual(offset(CGPoint(x: 6, y: midY)), before, "left gutter → before the table")
        XCTAssertEqual(offset(CGPoint(x: 384, y: midY)), after, "right gutter → after the table")
        XCTAssertEqual(offset(CGPoint(x: 195, y: top - 4)), before, "seam just above → before the table")
        XCTAssertEqual(offset(CGPoint(x: 195, y: bottom + 4)), after, "seam just below → after the table")
        // The padding above/below the table (inside its own line fragment) is a
        // full-width before/after target, not just the thin seam at the edge.
        let pad = EditorTextView.blockVerticalPadding
        XCTAssertEqual(offset(CGPoint(x: 195, y: top + pad - 2)), before, "inside top padding → before the table")
        XCTAssertEqual(offset(CGPoint(x: 195, y: bottom - pad + 2)), after, "inside bottom padding → after the table")
        view.removeFromSuperview()
    }

    func testHandleEditorTapInGutterMovesCaretBeforeOrAfterTable() {
        final class FakeTap: UITapGestureRecognizer {
            var point: CGPoint = .zero
            override func location(in view: UIView?) -> CGPoint { point }
            override var state: UIGestureRecognizer.State {
                get { .ended }
                set {}
            }
        }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let fixture = makeWiredEditorView()
        let view = fixture.0
        let coordinator = fixture.1
        view.textContainer.lineFragmentPadding = 0
        view.textContainerInset = UIEdgeInsets(top: 8, left: 35, bottom: 8, right: 24)
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.loadItems(
            [
                textItem(id: "before", text: "Before", indent: 0),
                tableOnlyItem(indent: 0),
                textItem(id: "after", text: "After", indent: 0),
            ],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )
        renderEditor(view)

        let ns = view.textStorage.string as NSString
        let tablePara = paragraphRanges(in: ns)[1]
        view.layoutManager.ensureLayout(for: view.textContainer)
        let glyphRange = view.layoutManager.glyphRange(forCharacterRange: tablePara.fullRange, actualCharacterRange: nil)
        let frag = view.layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let midY = (frag.minY + frag.maxY) / 2 + view.textContainerInset.top

        let tap = FakeTap()
        tap.point = CGPoint(x: 6, y: midY)
        coordinator.handleEditorTap(tap)
        XCTAssertEqual(view.selectedRange, NSRange(location: tablePara.fullRange.location, length: 0),
                       "a left-gutter tap should move the caret before the table")

        tap.point = CGPoint(x: 384, y: midY)
        coordinator.handleEditorTap(tap)
        XCTAssertEqual(view.selectedRange, NSRange(location: tablePara.fullRange.location + 1, length: 0),
                       "a right-gutter tap should move the caret after the table")
        view.removeFromSuperview()
    }

    func testTapBelowTrailingTextLineIsUnchanged() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let fixture = makeWiredEditorView()
        let view = fixture.0
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.loadItems(
            [textItem(id: "a", text: "Only text", indent: 0)],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )
        renderEditor(view)
        // No trailing block: a below-content tap is left to UITextView (lands at
        // the end of the text line), so closestPosition still returns a position.
        XCTAssertNotNil(view.closestPosition(to: CGPoint(x: 30, y: 4000)))
        view.removeFromSuperview()
    }

    /// Regression guard: merging a table onto the (empty) line above must keep the
    /// cell text. In-place cell edits patch the line's `.knotqLine` meta but NOT
    /// the frozen `KnotQBlockAttachment`, so block recovery on merge must read the
    /// live meta (which `glyphBlockInline` now prefers over the attachment).
    func testMergingEditedTableOntoEmptyLinePreservesCellText() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let fixture = makeWiredEditorView()
        let view = fixture.0
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.loadItems(
            [textItem(id: "empty", text: "", indent: 0), richTableItem(indent: 0)],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )
        XCTAssertTrue(view.becomeFirstResponder())
        renderEditor(view)

        // Edit a cell in place so the line meta diverges from the attachment.
        guard let hit = view.tableCellHit(itemID: "rich-table", tableIndex: 0, row: 0, column: 0) else {
            XCTFail("expected an editable cell"); return
        }
        view.beginEditingTableCell(hit)
        guard let cellField = firstEmbeddedTextView(in: view) else {
            XCTFail("expected the in-place cell field"); return
        }
        cellField.text = "EDITED"
        view.endTableCellEditing(commit: true)
        renderEditor(view)

        // Merge the table up onto the empty line (backspace at its start).
        let paragraphs = paragraphRanges(in: view.textStorage.string as NSString)
        view.selectedRange = NSRange(location: paragraphs[1].fullRange.location, length: 0)
        view.deleteBackward()
        renderEditor(view)

        let edits = view.extractItemEdits()
        let tableEdit = edits.first { edit in
            edit.content.contains { if case .table = $0 { return true } else { return false } }
        }
        guard case let .table(table)? = tableEdit?.content.first else {
            XCTFail("merged line should still hold a table"); return
        }
        XCTAssertEqual(
            table.rows.first?.cells.first?.text, "EDITED",
            "the edited cell text must survive merging the table onto the line above"
        )
    }

    /// After merging a table onto a fresh (uncommitted, nil-id) line, its cells
    /// must still be tappable. Cell hit-testing is keyed by item id; if the merge
    /// leaves the table with the upper line's nil id, taps fall through to the
    /// document caret (landing before/after the table) instead of editing a cell.
    func testCellsStayHittableAfterMergingTableOntoFreshLine() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let fixture = makeWiredEditorView()
        let view = fixture.0
        window.addSubview(view)
        window.makeKeyAndVisible()
        // The first item has an empty id -> its line meta itemID is nil, like a
        // fresh line created with Return that hasn't round-tripped the model.
        view.loadItems(
            [textItem(id: "", text: "", indent: 0), richTableItem(indent: 0)],
            theme: .dark,
            timeFormat: "twelve_hour",
            placeCursorAtEnd: false
        )
        XCTAssertTrue(view.becomeFirstResponder())
        renderEditor(view)

        let paragraphs = paragraphRanges(in: view.textStorage.string as NSString)
        view.selectedRange = NSRange(location: paragraphs[1].fullRange.location, length: 0)
        view.deleteBackward()
        renderEditor(view)

        // The merged line keeps the table's own identity, so its cells hit-test.
        let mergedParagraphs = paragraphRanges(in: view.textStorage.string as NSString)
        XCTAssertEqual(
            lineMeta(at: mergedParagraphs[0].fullRange.location, in: view.textStorage).itemID,
            "rich-table",
            "merged table line must keep the table's item id, not the fresh line's nil id"
        )
        XCTAssertNotNil(
            view.tableCellHit(itemID: "rich-table", tableIndex: 0, row: 0, column: 0),
            "the table's cells must remain hittable after the merge"
        )
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

}
