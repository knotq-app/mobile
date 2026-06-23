import SwiftUI
import UIKit

private final class TransparentInputAccessoryView: UIInputView {
    init(frame: CGRect) {
        super.init(frame: frame, inputViewStyle: .default)
        allowsSelfSizing = true
        backgroundColor = .clear
        isOpaque = false
        insetsLayoutMarginsFromSafeArea = false
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: frame.height > 0 ? frame.height : 44)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        clearAccessoryChrome()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        clearAccessoryChrome()
    }

    private func clearAccessoryChrome() {
        var next: UIView? = self
        for _ in 0..<8 {
            next?.backgroundColor = .clear
            next?.isOpaque = false
            next = next?.superview
        }
    }
}


struct SchemeTextView: UIViewRepresentable {
    let controller: EditorController
    let items: [MobileItem]
    let timeFormat: String
    let theme: KnotQTheme
    let accent: Color
    let isScrollEnabled: Bool
    let textInsets: UIEdgeInsets
    let schemeTitle: String
    let showsTitle: Bool
    let titleEditable: Bool
    let titleValidator: (String) -> String?
    let onRenameTitle: (String) -> Void
    let onDate: () -> Void
    let onImageUpload: () -> Void
    let onInsertTable: () -> Void
    /// Persists an in-place cell edit (cell hit + new first-line text).
    let onTableCellCommit: (EditorTableCellHit, String) -> Void
    /// Row/column structure ops from the cell editor's accessory bar.
    let onTableInsertRow: (EditorTableCellHit, Int) -> Void
    let onTableDeleteRow: (EditorTableCellHit) -> Void
    let onTableInsertColumn: (EditorTableCellHit, Int) -> Void
    let onTableDeleteColumn: (EditorTableCellHit) -> Void
    let readOnly: Bool

    func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator()
    }

    func makeUIView(context: Context) -> EditorTextView {
        let view = EditorTextView()
        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.controller = controller
        coordinator.theme = theme
        coordinator.accentColor = UIColor(accent)
        coordinator.onDateRequested = onDate
        coordinator.onImageUploadRequested = onImageUpload
        coordinator.onInsertTableRequested = onInsertTable
        coordinator.readOnly = readOnly
        view.onTableCellCommit = onTableCellCommit
        view.onTableInsertRow = onTableInsertRow
        view.onTableDeleteRow = onTableDeleteRow
        view.onTableInsertColumn = onTableInsertColumn
        view.onTableDeleteColumn = onTableDeleteColumn
        view.coordinator = coordinator
        view.theme = theme
        view.accentColor = UIColor(accent)
        view.delegate = coordinator
        view.textStorage.delegate = coordinator
        view.backgroundColor = UIColor(theme.bgApp)
        view.textColor = UIColor(theme.textPrimary)
        view.font = .systemFont(ofSize: DesktopEditorMetrics.textFontSize)
        view.textContainerInset = textInsets
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byWordWrapping
        view.textContainer.widthTracksTextView = true
        view.isScrollEnabled = isScrollEnabled
        // When embedded with scrolling disabled (e.g. the Daily feed), let the
        // parent SwiftUI layout dictate width instead of UITextView insisting
        // on its intrinsic (effectively unbounded) width.
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.keyboardDismissMode = .none
        view.alwaysBounceVertical = true
        view.autocapitalizationType = .sentences
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.isEditable = !readOnly
        view.isSelectable = true
        view.configureTitle(title: schemeTitle, theme: theme, visible: showsTitle, editable: titleEditable, validator: titleValidator, onCommit: onRenameTitle)
        let checkboxTap = UITapGestureRecognizer(target: coordinator, action: #selector(EditorCoordinator.handleEditorTap(_:)))
        checkboxTap.delegate = coordinator
        checkboxTap.cancelsTouchesInView = false
        coordinator.checkboxTapRecognizer = checkboxTap
        view.addGestureRecognizer(checkboxTap)
        controller.view = view
        view.typingAttributes = EditorAttributes.bodyAttributes(meta: LineMeta(), theme: theme)
        // Populate storage before SwiftUI's first sizeThatFits pass so a
        // self-sizing (Daily feed) editor measures real content from frame one;
        // the pane's onAppear load runs only after layout.
        view.loadItems(items, theme: theme, timeFormat: timeFormat, placeCursorAtEnd: false)
        return view
    }

    func updateUIView(_ uiView: EditorTextView, context: Context) {
        let coordinator = context.coordinator
        let themeChanged = uiView.theme.isDark != theme.isDark
        coordinator.theme = theme
        coordinator.accentColor = UIColor(accent)
        coordinator.onDateRequested = onDate
        coordinator.onImageUploadRequested = onImageUpload
        coordinator.onInsertTableRequested = onInsertTable
        coordinator.readOnly = readOnly
        uiView.onTableCellCommit = onTableCellCommit
        uiView.onTableInsertRow = onTableInsertRow
        uiView.onTableDeleteRow = onTableDeleteRow
        uiView.onTableInsertColumn = onTableInsertColumn
        uiView.onTableDeleteColumn = onTableDeleteColumn
        uiView.theme = theme
        uiView.accentColor = UIColor(accent)
        uiView.backgroundColor = UIColor(theme.bgApp)
        uiView.textContainerInset = textInsets
        uiView.isScrollEnabled = isScrollEnabled
        uiView.keyboardDismissMode = .none
        uiView.isEditable = !readOnly
        uiView.isSelectable = true
        if themeChanged {
            uiView.restyleForTheme(theme)
        }
        if readOnly, uiView.inputAccessoryView != nil {
            uiView.inputAccessoryView = nil
        }
        uiView.configureTitle(title: schemeTitle, theme: theme, visible: showsTitle, editable: titleEditable, validator: titleValidator, onCommit: onRenameTitle)
        uiView.refreshEmbeddedLayoutIfNeeded(deferred: true)
        uiView.setNeedsDisplay()
    }

    /// Self-sizing for embedded (non-scrolling) editors: report the exact
    /// TextKit-measured height for the proposed width so the Daily feed lays
    /// days out without estimated heights. Scrolling editors keep the default
    /// fill-proposed-space behavior.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: EditorTextView, context: Context) -> CGSize? {
        guard !isScrollEnabled else { return nil }
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: uiView.measuredHeight(forWidth: width))
    }
}

// MARK: - Editor coordinator

@MainActor
final class EditorCoordinator: NSObject, UITextViewDelegate, @preconcurrency NSTextStorageDelegate, UIGestureRecognizerDelegate {
    weak var view: EditorTextView?
    weak var controller: EditorController?
    var theme: KnotQTheme = .dark
    var accentColor: UIColor = .systemBlue
    var onDateRequested: (() -> Void)?
    var onImageUploadRequested: (() -> Void)?
    var onInsertTableRequested: (() -> Void)?
    var readOnly = false
    weak var checkboxTapRecognizer: UITapGestureRecognizer?

    private var suppressDelegateDepth = 0
    private var autoBulletizePending = false
    private var blockIsolationPending = false
    private var embeddedDisplayRefreshPending = false
    fileprivate var autoBulletUndo: (lineLocation: Int, originalBody: String)?

    // Toolbar marker buttons keyed by Marker, so we can tint the active one.
    private var markerButtons: [Marker: UIButton] = [:]

    func suppress(_ block: () -> Void) {
        suppressDelegateDepth += 1
        defer { suppressDelegateDepth -= 1 }
        block()
    }

    func markDirty() {
        guard !readOnly else { return }
        controller?.isDirty = true
    }

    func refreshEmpty() {
        guard let view, let controller else { return }
        let empty = view.isEffectivelyEmpty()
        if controller.isEmpty != empty {
            controller.isEmpty = empty
        }
    }

    // MARK: UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        // Invariants are restored from `textStorage(_:didProcessEditing:...)`.
        markDirty()
        refreshEmpty()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        // I3: the caret is never past the trailing "\n". Clamp collapsed caret
        // to length - 1 so taps at the very end stay on the last visible line.
        if textView.selectedRange.length == 0 {
            let storage = textView.textStorage
            let maxCaret = max(0, storage.length - 1)
            if textView.selectedRange.location > maxCaret {
                textView.selectedRange = NSRange(location: maxCaret, length: 0)
                textView.typingAttributes = EditorAttributes.bodyAttributes(
                    meta: lineMeta(at: maxCaret, in: storage),
                    theme: theme
                )
            }
        }
        refreshToolbarActiveMarker(in: textView)
        // Reveal markers on the line the caret just moved to, hide the rest.
        (textView as? EditorTextView)?.refreshMarkerVisibility()
    }

    /// Highlights the toolbar marker button matching the caret's line.
    func refreshToolbarActiveMarker(in textView: UITextView) {
        let storage = textView.textStorage
        let caret = clampedCaret(textView.selectedRange.location, in: storage)
        let active = lineMeta(at: caret, in: storage).marker
        for (marker, button) in markerButtons {
            button.tintColor = UIColor(marker == active ? theme.textPrimary : theme.textDim)
        }
    }

    @objc func handleEditorTap(_ recognizer: UITapGestureRecognizer) {
        guard !readOnly else { return }
        guard recognizer.state == .ended, let view else { return }
        let point = recognizer.location(in: view)
        if let hit = view.tableCellHit(at: point) {
            // Edit the cell in place rather than opening a modal sheet.
            view.beginEditingTableCell(hit)
            return
        }
        // A tap outside any cell ends in-place cell editing (and flushes it).
        if view.isEditingTableCell {
            view.endTableCellEditing(commit: true)
        }
        if view.toggleCheckboxAt(point: point) {
            return
        }
        // A tap in a block's gutter (beside it) or the seam just above/below
        // places the caret before/after the block. UITextView ignores taps in
        // that empty margin, so do it ourselves.
        _ = view.placeCaretAtBlockEdge(at: point)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === checkboxTapRecognizer, !readOnly else { return false }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === checkboxTapRecognizer, let view else { return false }
        // Our checkbox/table tap and UITextView's built-in caret-positioning tap
        // are both single-tap recognizers. Without allowing them to recognize
        // simultaneously they are mutually exclusive and ours wins, so a single
        // tap on plain text (a no-op for us) stops moving the cursor and the only
        // way to position the caret is a long-press.
        //
        // On a table cell tap we take over caret placement and focus ourselves
        // (the in-place cell editor), so stay exclusive there to keep UITextView's
        // tap from fighting for first responder. Everywhere else, let both fire so
        // a tap positions the caret (and toggles a checkbox).
        let point = gestureRecognizer.location(in: view)
        if view.tableCellHit(at: point) != nil {
            return false
        }
        // Everywhere else (plain text AND a block's gutter/seam) stay simultaneous
        // so our recognizer reliably reaches `.ended` and runs `handleEditorTap`.
        // Going exclusive here would make *our* tap lose to UITextView's built-in
        // tap (a cell tap only "wins" because it steals first responder), so the
        // explicit gutter caret placement would never fire.
        return true
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard !readOnly else { return false }
        guard let view = textView as? EditorTextView else { return true }
        if text.isEmpty && range.length > 0, view.deleteSelectedBlockParagraphsIfNeeded(in: range) {
            autoBulletUndo = nil
            return false
        }
        if text == "\n" && range.length == 0 {
            return !handleEnter(in: view, at: range.location)
        }
        if text.isEmpty && range.length == 1 {
            if handleAutoBulletUndo(in: view, deletionRange: range) {
                return false
            }
            if handleClearMarkerBackspace(in: view, deletionRange: range) {
                return false
            }
            // Refuse a backspace that would merge a block (image/table) line with
            // a non-empty text line — the block stays alone on its line (I4). The
            // block's own glyph still deletes natively (it is one real character).
            if handleBlockMergeGuard(in: view, deletionRange: range) {
                return false
            }
            if handleMergeParagraphs(in: view, deletionRange: range) {
                return false
            }
        }
        // Typing a real character while the caret sits on a block line: redirect
        // it onto a fresh adjacent text line so the block keeps its own line (I4).
        if !text.isEmpty, range.length == 0, handleTypingOnBlockLine(in: view, range: range, text: text) {
            autoBulletUndo = nil
            return false
        }
        // Any non-backspace edit clears the pending auto-bullet undo.
        if !(text.isEmpty && range.length == 1) {
            autoBulletUndo = nil
        }
        return true
    }

    /// Desktop parity: backspace at col 0 of a line with a non-blank marker
    /// clears the marker first instead of joining lines. The user has to
    /// backspace a second time to actually merge with the previous line.
    private func handleClearMarkerBackspace(in view: EditorTextView, deletionRange: NSRange) -> Bool {
        let storage = view.textStorage
        let ns = storage.string as NSString
        // backspace at column 0 of paragraph P targets the prior "\n"; the
        // caret sits at P.location, deletionRange = (P.location - 1, 1).
        let caret = deletionRange.location + 1
        guard caret <= ns.length else { return false }
        let para = editableParagraphRange(in: ns, at: caret)
        guard caret == para.location, para.location > 0 else { return false }
        let meta = lineMeta(at: para.location, in: storage)
        guard meta.marker != .blank else { return false }
        let cleared = LineMeta(
            marker: .blank,
            indent: meta.indent,
            done: false,
            itemID: meta.itemID,
            annotation: nil,
            media: meta.media,
            tables: meta.tables
        )
        suppress {
            storage.beginEditing()
            setLineMeta(cleared, onParagraph: para, in: storage, theme: theme)
            storage.endEditing()
        }
        view.typingAttributes = EditorAttributes.bodyAttributes(meta: cleared, theme: theme)
        autoBulletUndo = nil
        markDirty()
        refreshEmpty()
        return true
    }

    /// Backspace at the very start of the document (column 0 of the first line).
    /// UITextView delivers no `shouldChangeTextIn` there — there is no prior
    /// character to delete — so `handleClearMarkerBackspace` never sees it and the
    /// first line's marker can't be cleared the way every other line's can. The
    /// `EditorTextView.deleteBackward` override routes that keystroke here so the
    /// first line clears its marker too, matching desktop and the rest of the doc.
    /// Returns true when it consumed the backspace (marker cleared).
    func handleClearMarkerAtDocumentStart(in view: EditorTextView) -> Bool {
        guard !readOnly else { return false }
        let selection = view.selectedRange
        guard selection.location == 0, selection.length == 0 else { return false }
        let storage = view.textStorage
        let para = editableParagraphRange(in: storage.string as NSString, at: 0)
        guard para.location == 0 else { return false }
        let meta = lineMeta(at: 0, in: storage)
        guard meta.marker != .blank else { return false }
        let cleared = LineMeta(
            marker: .blank,
            indent: meta.indent,
            done: false,
            itemID: meta.itemID,
            annotation: nil,
            media: meta.media,
            tables: meta.tables
        )
        suppress {
            storage.beginEditing()
            setLineMeta(cleared, onParagraph: para, in: storage, theme: theme)
            storage.endEditing()
        }
        view.typingAttributes = EditorAttributes.bodyAttributes(meta: cleared, theme: theme)
        autoBulletUndo = nil
        markDirty()
        refreshEmpty()
        return true
    }

    /// Refuses a backspace over the "\n" between two paragraphs when the merge
    /// would put a block (image/table) and text on the same line — the block
    /// stays alone on its line (invariant I4). A merge where the non-block side is
    /// empty is allowed (it just removes the blank line); the block's own glyph
    /// still deletes natively since it is a single real character. Returns true
    /// when it consumed (and dropped) the backspace.
    private func handleBlockMergeGuard(in view: EditorTextView, deletionRange: NSRange) -> Bool {
        let storage = view.textStorage
        let ns = storage.string as NSString
        guard deletionRange.length == 1,
              deletionRange.location < ns.length - 1,
              ns.character(at: deletionRange.location) == 10 else { return false }

        let paragraphs = paragraphRanges(in: ns)
        guard let upper = paragraphs.first(where: { NSMaxRange($0.fullRange) == deletionRange.location + 1 }),
              let lower = paragraphs.first(where: { $0.fullRange.location == deletionRange.location + 1 }) else {
            return false
        }
        let upperMeta = lineMeta(at: upper.fullRange.location, in: storage)
        let lowerMeta = lineMeta(at: lower.fullRange.location, in: storage)
        let upperEmpty = bodyText(paragraphRange: upper.fullRange, in: storage).isEmpty
        let lowerEmpty = bodyText(paragraphRange: lower.fullRange, in: storage).isEmpty

        if (upperMeta.hasBlockContent && !lowerEmpty) || (lowerMeta.hasBlockContent && !upperEmpty) {
            autoBulletUndo = nil
            return true
        }
        return false
    }

    /// Typing a character while the caret sits on a block (image/table) line: the
    /// character lands on a fresh blank line adjacent to the block — after it when
    /// the caret is past the glyph, before it otherwise — so the block keeps its
    /// own line (invariant I4). Returns true when it handled the keystroke.
    private func handleTypingOnBlockLine(in view: EditorTextView, range: NSRange, text: String) -> Bool {
        let storage = view.textStorage
        let ns = storage.string as NSString
        let para = editableParagraphRange(in: ns, at: range.location)
        let meta = lineMeta(at: para.location, in: storage)
        guard meta.hasBlockContent else { return false }

        // The block body is a single glyph at para.location; a caret past it
        // starts a line after the block, otherwise before it.
        let insertAfter = range.location > para.location
        let newMeta = LineMeta(marker: .blank, indent: meta.indent)
        let attrs = EditorAttributes.bodyAttributes(meta: newMeta, theme: theme)
        let insertionLocation = insertAfter ? NSMaxRange(para) : para.location
        suppress {
            storage.beginEditing()
            storage.replaceCharacters(
                in: NSRange(location: insertionLocation, length: 0),
                with: NSAttributedString(string: text + "\n", attributes: attrs)
            )
            let newPara = editableParagraphRange(in: storage.string as NSString, at: insertionLocation)
            setLineMeta(newMeta, onParagraph: newPara, in: storage, theme: theme)
            ensureWellFormed(storage, theme: theme)
            storage.endEditing()
        }
        let caret = clampedCaret(insertionLocation + (text as NSString).length, in: storage)
        view.selectedRange = NSRange(location: caret, length: 0)
        view.typingAttributes = attrs
        markDirty()
        refreshEmpty()
        view.invalidateEmbeddedBlockDisplay(reflow: true)
        return true
    }

    /// The line meta a block glyph in `paragraphRange` carries — its own
    /// `.knotqLine` (which in-place cell edits keep current), used to recover a
    /// block after a merge moved the glyph onto a paragraph whose meta lost it.
    /// Preferring the live line meta over the frozen `KnotQBlockAttachment`
    /// snapshot keeps both the latest cell text AND the block's item id (cell
    /// hit-testing is keyed by item id). Falls back to a meta synthesised from the
    /// attachment only if the glyph somehow lost its line meta.
    private func glyphLineMeta(in storage: NSTextStorage, paragraphRange: NSRange) -> LineMeta? {
        let ns = storage.string as NSString
        let end = min(NSMaxRange(paragraphRange), ns.length)
        var index = paragraphRange.location
        while index < end {
            if ns.character(at: index) == blockObjectScalar {
                if let meta = storage.attribute(.knotqLine, at: index, effectiveRange: nil) as? LineMeta,
                   meta.blockInline != nil {
                    return meta
                }
                if let attachment = storage.attribute(.attachment, at: index, effectiveRange: nil) as? KnotQBlockAttachment {
                    switch attachment.block {
                    case let .image(media): return LineMeta(media: [media], content: [attachment.block])
                    case let .table(table): return LineMeta(tables: [table], content: [attachment.block])
                    case .text: return nil
                    }
                }
            }
            index += 1
        }
        return nil
    }

    /// Reconciles a paragraph's meta to invariant I4: a paragraph that contains
    /// the block glyph must carry that block in its meta (recovered from the
    /// glyph's own line meta if a merge dropped it); a paragraph without the glyph
    /// must carry no block. Keeps the editor's view of a line and what it
    /// draws/extracts in sync after native edits.
    private func reconciledBlockMeta(_ meta: LineMeta, paragraphRange: NSRange, in storage: NSTextStorage) -> LineMeta {
        let hasGlyph = containsBlockObject(bodyText(paragraphRange: paragraphRange, in: storage))
        if hasGlyph {
            if meta.hasBlockContent { return meta }
            guard let glyphMeta = glyphLineMeta(in: storage, paragraphRange: paragraphRange),
                  let block = glyphMeta.blockInline else { return meta }
            // Carry over the block's OWN item id from the glyph's line meta. A
            // merge moved the glyph onto this line; keeping `meta`'s id (the upper
            // line's, often nil for a fresh line) leaves the table with no id, and
            // cell hit-testing — keyed by item id — silently fails, so cell taps
            // land the document caret before/after the table instead of in a cell.
            let base = meta.with(itemID: glyphMeta.itemID)
            switch block {
            case let .image(media): return base.with(media: [media], tables: [], content: [block])
            case let .table(table): return base.with(media: [], tables: [table], content: [block])
            case .text: return meta
            }
        }
        return meta.hasBlockContent ? meta.with(media: [], tables: [], content: []) : meta
    }

    /// Deleting the "\n" between two paragraphs merges the lower line *into* the
    /// upper one. Line meta is stored across every character of a paragraph
    /// including its trailing "\n", and a merged paragraph is read from that
    /// trailing newline — which belongs to the *lower* line. Left to UITextView,
    /// the merge would therefore inherit the lower line's meta and drop the upper
    /// line's marker, and when the upper line is empty (its "\n" is its only
    /// character) the upper meta is destroyed outright. We perform the merge here
    /// so the upper line's identity always wins, mirroring desktop.
    private func handleMergeParagraphs(in view: EditorTextView, deletionRange: NSRange) -> Bool {
        let storage = view.textStorage
        let ns = storage.string as NSString
        guard deletionRange.length == 1,
              deletionRange.location < ns.length,
              ns.character(at: deletionRange.location) == 10 else { return false }
        // Never delete the document's trailing "\n" (invariant I1); there is no
        // lower paragraph to merge in that case.
        guard deletionRange.location < ns.length - 1 else { return false }

        // The "\n" terminates the upper paragraph; capture its meta before the
        // delete removes it.
        let upperMeta = lineMeta(forParagraphAt: deletionRange.location, in: storage)
        let upperAttrs = EditorAttributes.bodyAttributes(meta: upperMeta, theme: theme)
        var mergedMeta = upperMeta
        suppress {
            storage.beginEditing()
            storage.replaceCharacters(
                in: deletionRange,
                with: NSAttributedString(string: "", attributes: upperAttrs)
            )
            let merged = editableParagraphRange(in: storage.string as NSString, at: deletionRange.location)
            // If the merge pulled a block glyph onto this line (e.g. removing a
            // blank line above a block), recover the block; if it dropped one,
            // clear stale block meta — keep meta and glyph in sync (I4).
            mergedMeta = reconciledBlockMeta(upperMeta, paragraphRange: merged, in: storage)
            setLineMeta(mergedMeta, onParagraph: merged, in: storage, theme: theme)
            storage.endEditing()
        }
        view.selectedRange = NSRange(location: deletionRange.location, length: 0)
        view.typingAttributes = EditorAttributes.bodyAttributes(meta: mergedMeta, theme: theme)
        autoBulletUndo = nil
        markDirty()
        refreshEmpty()
        view.invalidateEmbeddedBlockDisplay(reflow: true)
        return true
    }

    // MARK: - Edit handlers (called from shouldChangeTextIn)

    /// Backspace immediately after auto-bulletize → undo the conversion.
    /// Auto-bulletize left the caret at col 0 of the converted line; that
    /// backspace would otherwise delete the prior newline.
    private func handleAutoBulletUndo(in view: EditorTextView, deletionRange: NSRange) -> Bool {
        guard let undo = autoBulletUndo else { return false }
        guard deletionRange.location == undo.lineLocation - 1,
              deletionRange.length == 1 else {
            autoBulletUndo = nil
            return false
        }
        let storage = view.textStorage
        let paraRange = editableParagraphRange(in: storage.string as NSString, at: undo.lineLocation)
        let body = bodyText(paragraphRange: paraRange, in: storage)
        let bodyRange = NSRange(location: paraRange.location, length: (body as NSString).length)
        let restoredMeta = LineMeta()
        let attrs = EditorAttributes.bodyAttributes(meta: restoredMeta, theme: theme)
        suppress {
            storage.beginEditing()
            storage.replaceCharacters(in: bodyRange, with: NSAttributedString(string: undo.originalBody, attributes: attrs))
            let restored = editableParagraphRange(in: storage.string as NSString, at: paraRange.location)
            setLineMeta(restoredMeta, onParagraph: restored, in: storage, theme: theme)
            storage.endEditing()
        }
        view.selectedRange = NSRange(
            location: paraRange.location + (undo.originalBody as NSString).length,
            length: 0
        )
        view.typingAttributes = attrs
        autoBulletUndo = nil
        markDirty()
        refreshEmpty()
        return true
    }

    /// Enter: split the current paragraph and continue the marker on the new
    /// line. Empty marker lines are treated no differently from non-empty ones —
    /// pressing return duplicates the marker onto a fresh line rather than
    /// stripping it. With invariant I3 the caret is always within a real
    /// paragraph, so the "cursor past end of storage" edge case needs no
    /// special handling.
    private func handleEnter(in view: EditorTextView, at cursor: Int) -> Bool {
        let storage = view.textStorage
        let currentPara = editableParagraphRange(in: storage.string as NSString, at: cursor)
        let currentMeta = lineMeta(at: currentPara.location, in: storage)

        // A block (image/table) line can't be split — Enter adds a fresh blank
        // line adjacent to it (after the glyph if the caret is past it, before
        // otherwise) so the block keeps its own line (invariant I4).
        if currentMeta.hasBlockContent {
            let insertAfter = cursor > currentPara.location
            let blankMeta = LineMeta(marker: .blank, indent: currentMeta.indent)
            let blankAttrs = EditorAttributes.bodyAttributes(meta: blankMeta, theme: theme)
            let insertionLocation = insertAfter ? NSMaxRange(currentPara) : currentPara.location
            suppress {
                storage.beginEditing()
                storage.replaceCharacters(
                    in: NSRange(location: insertionLocation, length: 0),
                    with: NSAttributedString(string: "\n", attributes: blankAttrs)
                )
                let newPara = editableParagraphRange(in: storage.string as NSString, at: insertionLocation)
                setLineMeta(blankMeta, onParagraph: newPara, in: storage, theme: theme)
                storage.endEditing()
            }
            view.selectedRange = NSRange(location: insertionLocation, length: 0)
            view.typingAttributes = blankAttrs
            markDirty()
            refreshEmpty()
            view.invalidateEmbeddedBlockDisplay(reflow: true)
            return true
        }

        // Split the paragraph at the caret: old half keeps currentMeta, new half
        // gets continuation meta (fresh identity, same marker/indent/done-reset).
        let newMeta = continuationMeta(currentMeta)
        let oldAttrs = EditorAttributes.bodyAttributes(meta: currentMeta, theme: theme)
        let newAttrs = EditorAttributes.bodyAttributes(meta: newMeta, theme: theme)
        suppress {
            storage.beginEditing()
            storage.replaceCharacters(
                in: NSRange(location: cursor, length: 0),
                with: NSAttributedString(string: "\n", attributes: oldAttrs)
            )
            // Re-establish meta uniformly on both halves.
            let ns = storage.string as NSString
            let oldHalf = editableParagraphRange(in: ns, at: cursor)
            let newHalf = editableParagraphRange(in: ns, at: cursor + 1)
            setLineMeta(currentMeta, onParagraph: oldHalf, in: storage, theme: theme)
            setLineMeta(newMeta, onParagraph: newHalf, in: storage, theme: theme)
            storage.endEditing()
        }
        view.selectedRange = NSRange(location: cursor + 1, length: 0)
        view.typingAttributes = newAttrs
        markDirty()
        refreshEmpty()
        return true
    }

    private func continuationMeta(_ meta: LineMeta) -> LineMeta {
        LineMeta(marker: meta.marker, indent: meta.indent, done: false, itemID: nil, annotation: nil)
    }

    // MARK: NSTextStorageDelegate

    /// After any user edit we (a) re-establish invariants I1 + I2 and (b) try
    /// auto-bulletize. Programmatic edits (set marker, toggle indent, etc.)
    /// suppress this callback because they already maintain the invariants.
    func textStorage(_ storage: NSTextStorage, didProcessEditing actions: NSTextStorage.EditActions, range editedRange: NSRange, changeInLength delta: Int) {
        // Self-sizing (Daily feed) editors must re-measure after *any* storage
        // mutation — including suppressed programmatic ones (marker changes,
        // checkbox toggles, document loads) that never reach textViewDidChange.
        if let view, !view.isScrollEnabled {
            view.invalidateIntrinsicContentSize()
        }
        guard suppressDelegateDepth == 0 else { return }
        guard actions.contains(.editedCharacters) else { return }

        suppress {
            storage.beginEditing()
            ensureWellFormed(storage, theme: theme)
            normalizeAffectedParagraphs(in: storage, around: editedRange)
            storage.endEditing()
        }

        // Refresh embedded block (table/image) rendering, but DEFERRED. Doing it
        // here invalidates display against a layout manager that hasn't yet
        // processed this edit; its `_boundingRectForGlyphRange` then reads
        // `characterAtIndex` past the new length (NSRangeException) — UIKit's
        // autocorrection replace is the reliable trigger. The whole call must
        // wait until the edit cycle finishes, like the isolate pass below.
        if !embeddedDisplayRefreshPending {
            embeddedDisplayRefreshPending = true
            DispatchQueue.main.async { [weak self] in
                self?.embeddedDisplayRefreshPending = false
                self?.view?.invalidateEmbeddedBlockDisplay()
            }
        }

        // I4 backstop runs deferred (length changes are unsafe inside this
        // callback — they corrupt the layout manager and crash a later pass).
        if !blockIsolationPending {
            blockIsolationPending = true
            DispatchQueue.main.async { [weak self] in
                self?.runBlockIsolationPass()
            }
        }

        if !autoBulletizePending {
            autoBulletizePending = true
            let editLocation = editedRange.location
            DispatchQueue.main.async { [weak self] in
                self?.autoBulletizePending = false
                self?.maybeAutoBulletize(at: editLocation)
            }
        }
    }

    /// Re-applies meta + styling uniformly on every paragraph that overlaps the
    /// edit. Detects "cloned" paragraphs (where UITextView's attribute extension
    /// leaked an itemID/annotation from the previous paragraph) by reference
    /// equality of the .knotqLine value and resets identity on those.
    private func normalizeAffectedParagraphs(in storage: NSTextStorage, around editedRange: NSRange) {
        let ns = storage.string as NSString
        let editParaRange = paragraphRangeCovering(editedRange, in: ns)
        // Attribute-only fixups (no length change): mutating the storage *length*
        // from inside `didProcessEditing` corrupts the layout manager's glyph↔char
        // map (it later reads `characterAtIndex(length)` → NSRangeException). The
        // structural I4 fix (splitting a glyph off a mixed line) is therefore
        // deferred to `runBlockIsolationPass` after the edit cycle.
        for paragraph in paragraphRanges(in: ns, intersecting: editParaRange) {
            let fullRange = paragraph.fullRange
            guard fullRange.length > 0 else { continue }
            var meta = paragraphMeta(of: fullRange, in: storage)
            if fullRange.location > 0 {
                let prev = storage.attribute(.knotqLine, at: fullRange.location - 1, effectiveRange: nil) as? LineMeta
                if let prev, prev === meta {
                    // Cloned via attribute inheritance — fresh paragraph, reset identity.
                    meta = LineMeta(
                        marker: prev.marker,
                        indent: prev.indent,
                        done: false,
                        itemID: nil,
                        annotation: nil,
                        media: [],
                        tables: []
                    )
                }
            }
            // Keep block meta and the block glyph in sync after native edits: a
            // line that still has the glyph keeps/recovers its block; a line that
            // lost it (the glyph was deleted) drops the stale block meta (I4).
            meta = reconciledBlockMeta(meta, paragraphRange: fullRange, in: storage)
            setLineMeta(meta, onParagraph: fullRange, in: storage, theme: theme)
        }
    }

    /// Backstop for invariant I4: if a native edit (cross-block selection delete,
    /// plain paste, IME, drag) merged a block glyph onto a line with other
    /// characters, split every such glyph back onto its own line and re-reconcile.
    /// Runs **deferred** (off the `didProcessEditing` stack) because it changes the
    /// text length — doing that mid-edit corrupts the layout manager and crashes a
    /// later layout pass with an out-of-bounds `characterAtIndex`. The per-case
    /// guards keep precise carets in the common paths; this only fires for the rare
    /// ones, and it's a no-op (one cheap scan) when nothing is mixed.
    private func runBlockIsolationPass() {
        blockIsolationPending = false
        guard let view, !readOnly else { return }
        let storage = view.textStorage
        let scan = storage.string as NSString
        var insertionPoints: [Int] = []
        for paragraph in paragraphRanges(in: scan) {
            let line = paragraph.lineRange
            guard line.length > 1, containsBlockObject(scan.substring(with: line)) else { continue }
            // A "\n" goes between any two adjacent body chars where either is a
            // glyph, so every glyph ends up bracketed by line breaks.
            for i in line.location..<(NSMaxRange(line) - 1) where
                scan.character(at: i) == blockObjectScalar || scan.character(at: i + 1) == blockObjectScalar {
                insertionPoints.append(i + 1)
            }
        }
        guard !insertionPoints.isEmpty else { return }

        let blankAttrs = EditorAttributes.bodyAttributes(meta: LineMeta(), theme: theme)
        suppress {
            storage.beginEditing()
            // Right-to-left so earlier offsets stay valid as we insert.
            for location in insertionPoints.sorted(by: >) {
                storage.replaceCharacters(
                    in: NSRange(location: location, length: 0),
                    with: NSAttributedString(string: "\n", attributes: blankAttrs)
                )
            }
            // Restore each resulting line's meta (block lines recover their block
            // from the glyph's attachment; text lines drop any stale block meta).
            let ns = storage.string as NSString
            for paragraph in paragraphRanges(in: ns) {
                let fullRange = paragraph.fullRange
                guard fullRange.length > 0 else { continue }
                let meta = reconciledBlockMeta(paragraphMeta(of: fullRange, in: storage), paragraphRange: fullRange, in: storage)
                setLineMeta(meta, onParagraph: fullRange, in: storage, theme: theme)
            }
            storage.endEditing()
        }
        markDirty()
        refreshEmpty()
        view.invalidateEmbeddedBlockDisplay(reflow: true)
    }

    /// Detects "- ", "* ", or "N. " typed on a blank line and converts the
    /// marker. Runs asynchronously after the typing settles so the caret is in
    /// a consistent position.
    private func maybeAutoBulletize(at editLocation: Int) {
        guard let view else { return }
        let storage = view.textStorage
        let paraRange = editableParagraphRange(in: storage.string as NSString, at: editLocation)
        let body = bodyText(paragraphRange: paraRange, in: storage)
        guard !body.isEmpty else { return }
        let currentMeta = lineMeta(at: paraRange.location, in: storage)
        guard currentMeta.marker == .blank else { return }

        let newMarker: Marker
        if body == "- " || body == "* " {
            newMarker = .bullet
        } else if body.range(of: #"^\d+\.\s$"#, options: .regularExpression) != nil {
            newMarker = .numbered
        } else {
            return
        }

        autoBulletUndo = (lineLocation: paraRange.location, originalBody: body)
        let newMeta = currentMeta.with(marker: newMarker, done: false)
        let bodyRange = NSRange(location: paraRange.location, length: (body as NSString).length)
        let attrs = EditorAttributes.bodyAttributes(meta: newMeta, theme: theme)
        suppress {
            storage.beginEditing()
            storage.replaceCharacters(in: bodyRange, with: NSAttributedString(string: "", attributes: attrs))
            let updated = editableParagraphRange(in: storage.string as NSString, at: paraRange.location)
            setLineMeta(newMeta, onParagraph: updated, in: storage, theme: theme)
            storage.endEditing()
        }
        view.selectedRange = NSRange(location: paraRange.location, length: 0)
        view.typingAttributes = attrs
        markDirty()
    }

    // MARK: Toolbar

    func makeToolbar(for textView: UITextView) -> UIView {
        markerButtons.removeAll()
        let width = UIScreen.main.bounds.width
        let accessoryHeight: CGFloat = UIDevice.current.userInterfaceIdiom == .phone ? 58 : 44
        let bottomGap: CGFloat = UIDevice.current.userInterfaceIdiom == .phone ? 14 : 6
        let container = TransparentInputAccessoryView(frame: CGRect(x: 0, y: 0, width: width, height: accessoryHeight))
        container.autoresizingMask = [.flexibleWidth]
        container.backgroundColor = .clear
        container.isOpaque = false
        let dismissPan = UIPanGestureRecognizer(target: self, action: #selector(handleToolbarPan(_:)))
        dismissPan.cancelsTouchesInView = false
        container.addGestureRecognizer(dismissPan)

        // Liquid glass background (iOS 26+). Falls back to an ultra-thin
        // material so older OSes still render something readable above the
        // keyboard. The glass replaces per-button chip backgrounds; the bar
        // itself is the only floating surface.
        let backdrop: UIVisualEffectView
        if #available(iOS 26.0, *) {
            backdrop = UIVisualEffectView(effect: UIGlassEffect())
        } else {
            backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        }
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.backgroundColor = .clear
        backdrop.isOpaque = false
        backdrop.contentView.backgroundColor = .clear
        backdrop.layer.cornerRadius = 10
        backdrop.layer.cornerCurve = .continuous
        backdrop.clipsToBounds = true
        backdrop.layer.borderWidth = 1
        backdrop.layer.borderColor = UIColor(theme.borderOverlay).cgColor
        container.addSubview(backdrop)

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .clear
        // With a hardware keyboard the bar docks at the screen bottom, and the
        // automatic inset would add the home-indicator safe area, shifting the
        // icons up inside the glass. Pin them to the bar's own bounds instead.
        scroll.contentInsetAdjustmentBehavior = .never
        backdrop.contentView.addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.layoutMargins = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        stack.isLayoutMarginsRelativeArrangement = true
        // Without this, a docked hardware-keyboard bar adds the bottom safe
        // area to the stack's margins, pushing the icons up inside the glass.
        stack.insetsLayoutMarginsFromSafeArea = false
        scroll.insetsLayoutMarginsFromSafeArea = false
        scroll.addSubview(stack)

        // Desktop format-palette order, with dismiss-keyboard as the leftmost
        // glyph and section dividers between functional groups.
        let blank = markerButton(.blank, systemName: "text.alignleft")
        let checkbox = markerButton(.checkbox, systemName: "checkmark.square")
        let bullet = markerButton(.bullet, systemName: "list.bullet")
        let numbered = markerButton(.numbered, systemName: "list.number")
        [
            toolbarButton("keyboard.chevron.compact.down") { [weak textView] in textView?.resignFirstResponder() },
            separator(),
            blank, checkbox, bullet, numbered,
            separator(),
            toolbarButton("decrease.indent") { [weak self] in self?.view?.shiftCurrentIndent(-1, theme: self?.theme ?? .dark) },
            toolbarButton("increase.indent") { [weak self] in self?.view?.shiftCurrentIndent(1, theme: self?.theme ?? .dark) },
            separator(),
            toolbarButton("calendar.badge.clock") { [weak self] in self?.onDateRequested?() },
            separator(),
            toolbarButton("bold") { [weak self] in self?.view?.toggleWrappedMarkdown("**", theme: self?.theme ?? .dark) },
            toolbarButton("italic") { [weak self] in self?.view?.toggleWrappedMarkdown("_", theme: self?.theme ?? .dark) },
            toolbarButton("textformat.size") { [weak self] in self?.view?.toggleHeading(theme: self?.theme ?? .dark) },
            separator(),
            toolbarButton("photo.badge.plus") { [weak self] in
                guard let self else { return }
                self.controller?.prepareImageUploadTarget()
                self.onImageUploadRequested?()
            },
            toolbarButton("tablecells") { [weak self] in
                self?.onInsertTableRequested?()
            },
        ].forEach(stack.addArrangedSubview)

        var constraints: [NSLayoutConstraint] = [
            backdrop.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -bottomGap),
            scroll.leadingAnchor.constraint(equalTo: backdrop.contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: backdrop.contentView.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: backdrop.contentView.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: backdrop.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ]

        if UIDevice.current.userInterfaceIdiom == .pad {
            // iPad: hug the buttons and center the bar, but cap at the available
            // width so it falls back to a full-width scrolling bar (like iPhone)
            // when the buttons would overflow the screen.
            let hugContent = scroll.frameLayoutGuide.widthAnchor.constraint(equalTo: scroll.contentLayoutGuide.widthAnchor)
            hugContent.priority = .defaultHigh
            constraints += [
                backdrop.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                backdrop.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 8),
                backdrop.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
                hugContent
            ]
        } else {
            constraints += [
                backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8)
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return container
    }

    @objc private func handleToolbarPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: recognizer.view)
        guard recognizer.state == .ended || recognizer.state == .changed else { return }
        if translation.y > 22, translation.y > abs(translation.x) * 1.25 {
            _ = view?.resignFirstResponder()
        }
    }

    private func markerButton(_ marker: Marker, systemName: String) -> UIButton {
        let button = toolbarButton(systemName) { [weak self] in
            guard let self else { return }
            self.view?.setCurrentMarker(marker, theme: self.theme)
        }
        markerButtons[marker] = button
        return button
    }

    private func toolbarButton(_ systemName: String, _ action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold),
            forImageIn: .normal
        )
        button.tintColor = UIColor(theme.textDim)
        button.backgroundColor = .clear
        button.widthAnchor.constraint(equalToConstant: 38).isActive = true
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func separator() -> UIView {
        let view = UIView()
        view.backgroundColor = UIColor(theme.dividerSoft)
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return view
    }
}

// MARK: - EditorTextView
