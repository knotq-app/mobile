import SwiftUI
import UIKit

// MARK: - Theme helpers

extension KnotQTheme {
    var editorChromeColor: UIColor {
        UIColor(hex: isDark ? 0xb8c9e8 : 0x536a8f)
    }
}


struct EditorTableCellHitRect {
    let rect: CGRect
    let hit: EditorTableCellHit
}

/// A `blockObjectChar` glyph reserves its image/table's full layout box on its
/// own line via `attachmentBounds`; the box is then painted (and hit-tested) by
/// the text view in `drawChrome`. The attachment carries no image of its own —
/// it is a sizing spacer + a real glyph so the caret, selection, and backspace
/// treat the block as a single character.

private final class EditorInlineTitleView: UIView, UITextFieldDelegate {
    let textField = UITextField()
    let errorLabel = UILabel()
    var committedTitle = ""
    var validator: ((String) -> String?)?
    var onCommit: ((String) -> Void)?
    var normalTintColor: UIColor = .systemBlue
    var errorTintColor: UIColor = .systemRed

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        textField.borderStyle = .none
        textField.font = .systemFont(ofSize: DesktopEditorMetrics.titleFontSize, weight: .bold)
        textField.returnKeyType = .done
        textField.enablesReturnKeyAutomatically = false
        textField.clearButtonMode = .never
        textField.autocorrectionType = .no
        textField.smartDashesType = .no
        textField.smartQuotesType = .no
        textField.delegate = self
        textField.addTarget(self, action: #selector(textDidChange), for: .editingChanged)
        addSubview(textField)

        errorLabel.font = .systemFont(ofSize: 11, weight: .medium)
        errorLabel.numberOfLines = 1
        addSubview(errorLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, theme: KnotQTheme, visible: Bool, editable: Bool, validator: @escaping (String) -> String?, onCommit: @escaping (String) -> Void) {
        self.validator = validator
        self.onCommit = onCommit
        isHidden = !visible
        textField.textColor = UIColor(theme.textPrimary)
        normalTintColor = UIColor(theme.accent)
        errorTintColor = UIColor(theme.danger)
        errorLabel.textColor = errorTintColor
        textField.isUserInteractionEnabled = visible && editable
        if !textField.isFirstResponder {
            committedTitle = title
            textField.text = title
        }
        if (!visible || !editable), textField.isFirstResponder {
            textField.resignFirstResponder()
        }
        updateError()
    }

    func focusAndSelectTitle() {
        guard textField.isUserInteractionEnabled else { return }
        textField.becomeFirstResponder()
        textField.selectAll(nil)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textField.frame = CGRect(x: 0, y: 0, width: bounds.width, height: DesktopEditorMetrics.titleLineHeight)
        errorLabel.frame = CGRect(x: 0, y: DesktopEditorMetrics.titleLineHeight - 1, width: bounds.width, height: 13)
    }

    @objc private func textDidChange() {
        updateError()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        commitTitle()
        textField.resignFirstResponder()
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        commitTitle()
    }

    func commitTitle() {
        let draft = textField.text ?? ""
        let validationError = validator?(draft)
        updateError(validationError)
        guard validationError == nil, draft != committedTitle else { return }
        committedTitle = draft
        onCommit?(draft)
    }

    func updateError(_ validationError: String? = nil) {
        let error = validationError ?? validator?(textField.text ?? "")
        errorLabel.text = error
        errorLabel.isHidden = error == nil
        textField.tintColor = error == nil ? normalTintColor : errorTintColor
    }
}

final class EditorTextView: UITextView {
    var theme: KnotQTheme = .dark { didSet { setNeedsDisplay() } }
    var accentColor: UIColor = .systemBlue { didSet { setNeedsDisplay() } }
    var timeFormat = "twelve_hour"
    weak var coordinator: EditorCoordinator?

    private let inlineTitleView = EditorInlineTitleView()
    let editorLayoutManager: EditorLayoutManager
    var imageCache: [String: UIImage] = [:]
    var renderedTableCellHits: [EditorTableCellHitRect] = []
    /// The in-place table cell editor, present only while a cell is being edited.
    var activeCellEditor: EditorTableCellEditor?
    var activeCellEditorWasDocumentBacked = false
    /// A cell to re-focus once the next document reload settles. Set right before a
    /// model mutation that reloads the document and changes table geometry (a
    /// row/column structural change). `loadItems` consumes it after layout so the
    /// in-place editor lands on the freshly drawn cell instead of a stale rect —
    /// and the keyboard stays up across the change.
    var pendingCellFocus: (itemID: String, tableIndex: Int, row: Int, column: Int)?
    /// Persists a committed cell-line edit (wired by the coordinator to the
    /// model's `setTableCellLineText`).
    var onTableCellCommit: ((EditorTableCellHit, String) -> Void)?
    /// Table structure ops invoked from the cell editor's keyboard accessory
    /// (row/column at the edited cell). Each takes the active cell hit.
    var onTableInsertRow: ((EditorTableCellHit, Int) -> Void)?
    var onTableDeleteRow: ((EditorTableCellHit) -> Void)?
    var onTableInsertColumn: ((EditorTableCellHit, Int) -> Void)?
    var onTableDeleteColumn: ((EditorTableCellHit) -> Void)?

    init() {
        let textStorage = NSTextStorage()
        let layoutManager = EditorLayoutManager()
        let textContainer = NSTextContainer(size: .zero)
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        editorLayoutManager = layoutManager
        super.init(frame: .zero, textContainer: textContainer)
        layoutManager.editorTextView = self
        addSubview(inlineTitleView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var lastIntrinsicWidth: CGFloat = 0
    var measurementWidth: CGFloat?
    var cachedFitSize = CGSize(width: -1, height: -1)

    override func invalidateIntrinsicContentSize() {
        cachedFitSize = CGSize(width: -1, height: -1)
        super.invalidateIntrinsicContentSize()
    }

    /// Exact content height for a proposed layout width; drives the Daily
    /// feed's self-sizing sections. Media/annotation spacing is routed through
    /// `measurementWidth` so image scaling matches the width being proposed
    /// rather than the (possibly stale or zero) current bounds.
    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        if cachedFitSize.width == width { return cachedFitSize.height }
        measurementWidth = width
        defer { measurementWidth = nil }
        let fitted = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = ceil(fitted.height)
        cachedFitSize = CGSize(width: width, height: height)
        return height
    }

    override func becomeFirstResponder() -> Bool {
        // The formatting toolbar is built on demand: the Daily feed mounts an
        // editor per day while scrolling, and only a focused one shows it.
        if isEditable, inputAccessoryView == nil, let coordinator {
            inputAccessoryView = coordinator.makeToolbar(for: self)
        }
        let became = super.becomeFirstResponder()
        if became {
            coordinator?.refreshToolbarActiveMarker(in: self)
            refreshMarkerVisibility(force: true)
            refreshEmbeddedLayoutIfNeeded(deferred: true)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            // Collapse every marker once editing ends for a clean preview.
            refreshMarkerVisibility(force: true)
        }
        return resigned
    }

    /// Reveals markdown markers on the caret's line(s) and collapses them
    /// elsewhere (all markers when not editing). Re-renders only the lines whose
    /// visibility changed unless `force` is set.
    func refreshMarkerVisibility(force: Bool = false) {
        guard textStorage.length > 0 else { return }
        let revealed: NSRange
        if isFirstResponder {
            let ns = textStorage.string as NSString
            let sel = selectedRange
            let startLoc = clampedCaret(sel.location, in: textStorage)
            let endProbe = NSMaxRange(sel) > sel.location ? NSMaxRange(sel) - 1 : sel.location
            let endLoc = clampedCaret(endProbe, in: textStorage)
            let startPara = editableParagraphRange(in: ns, at: startLoc)
            let endPara = editableParagraphRange(in: ns, at: endLoc)
            revealed = NSUnionRange(startPara, endPara)
        } else {
            revealed = NSRange(location: 0, length: 0)
        }
        if editorLayoutManager.setRevealedRange(revealed, force: force) {
            setNeedsDisplay()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutInlineTitleView()
        // With scrolling disabled (Daily feed), recompute intrinsic height after
        // the parent grants a width — otherwise wrapping is calculated against
        // an unbounded container and the text never breaks.
        if !isScrollEnabled, bounds.width != lastIntrinsicWidth {
            lastIntrinsicWidth = bounds.width
            refreshEmbeddedLayoutIfNeeded()
        }
    }

    func refreshEmbeddedLayoutIfNeeded(deferred: Bool = false) {
        guard !isScrollEnabled else { return }
        if deferred {
            DispatchQueue.main.async { [weak self] in
                self?.refreshEmbeddedLayoutIfNeeded()
            }
            return
        }
        invalidateIntrinsicContentSize()
        layoutManager.ensureLayout(for: textContainer)
        if contentOffset != .zero {
            setContentOffset(.zero, animated: false)
        }
        setNeedsDisplay()
    }

    func invalidateEmbeddedBlockDisplay(reflow: Bool = false) {
        cachedFitSize = CGSize(width: -1, height: -1)
        renderedTableCellHits.removeAll()
        guard textStorage.length > 0 else {
            setNeedsDisplay(bounds)
            return
        }
        let range = NSRange(location: 0, length: textStorage.length)
        if reflow {
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        }
        layoutManager.invalidateDisplay(forCharacterRange: range)
        setNeedsDisplay(bounds)
    }

    override var intrinsicContentSize: CGSize {
        guard !isScrollEnabled else { return super.intrinsicContentSize }
        let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        let fitted = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        // Defer width to the parent layout; only height is meaningful here.
        return CGSize(width: UIView.noIntrinsicMetric, height: fitted.height)
    }

    /// How far past a block's line-fragment edges a tap still resolves to the
    /// caret right before/after the block — the slack that extends the target into
    /// the neighbouring text lines on top of `blockVerticalPadding`.
    static let blockEdgeTapMargin: CGFloat = 12

    /// Empty space reserved above and below a block (image/table) inside its own
    /// line fragment. It gives the block breathing room AND, crucially, a real
    /// full-width strip to tap for the caret before/after it: without it the block
    /// fills its line edge-to-edge and the only "before/after" target is a sliver.
    /// Most of the before/after tap target comes from this (genuinely empty) space
    /// rather than `blockEdgeTapMargin`, which steals from the neighbouring lines.
    static let blockVerticalPadding: CGFloat = 16

    /// Resolve a tap near a block (image/table) line to the caret right before or
    /// after the block, mirroring desktop: the block fills its line, so a tap in
    /// the gutter left of it lands *before* it, right of it lands *after* it; a
    /// tap just above lands before, just below lands after (the last block owns
    /// all the empty space beneath it, where there is no text line to catch the
    /// tap). Cell taps fall through to the in-place cell editor instead.
    override func closestPosition(to point: CGPoint) -> UITextPosition? {
        if let edge = blockEdgeCaret(point) {
            return edge
        }
        return super.closestPosition(to: point)
    }

    /// Move the document caret to the block edge a gutter/seam tap addresses, and
    /// return true when the tap was one. UITextView's own tap recognizer ignores
    /// taps that land in the empty margin beside the text (the whole left/right
    /// gutter of a near-full-width block), so `closestPosition` is never consulted
    /// there — the tap handler calls this to place the caret explicitly instead.
    @discardableResult
    func placeCaretAtBlockEdge(at point: CGPoint) -> Bool {
        guard let position = blockEdgeCaret(point) else { return false }
        if !isFirstResponder { _ = becomeFirstResponder() }
        let offset = offset(from: beginningOfDocument, to: position)
        selectedRange = NSRange(location: offset, length: 0)
        return true
    }

    func blockEdgeCaret(_ point: CGPoint) -> UITextPosition? {
        let length = textStorage.length
        guard length > 0 else { return nil }
        // A tap on a table cell must reach the in-place cell editor, not the caret.
        guard tableCellHit(at: point) == nil else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let ns = textStorage.string as NSString
        let margin = Self.blockEdgeTapMargin
        let origin = CGPoint(x: textContainerInset.left, y: textContainerInset.top)
        let paragraphs = paragraphRanges(in: ns)
        for (index, paragraph) in paragraphs.enumerated() {
            let meta = lineMeta(at: paragraph.fullRange.location, in: textStorage)
            guard meta.hasBlockContent,
                  let geometry = paragraphGeometry(for: paragraph, origin: origin),
                  let firstFragment = geometry.fragments.first,
                  let rect = blockRect(for: meta, firstFragment: firstFragment) else { continue }
            // The vertical band this block answers for: its whole line fragment
            // (which includes the padding above/below the block) plus a margin into
            // the neighbouring text lines — or everything below it for the last
            // block (no text line beneath to catch the tap). `rect` is the block's
            // drawn box (inset within the fragment by the padding); the padding
            // strips between the fragment edges and `rect` are the generous,
            // full-width before/after target the user taps.
            let fragment = geometry.bounds
            let isLast = index == paragraphs.count - 1
            let bandTop = fragment.minY - margin
            let bandBottom = isLast ? .greatestFiniteMagnitude : fragment.maxY + margin
            guard point.y >= bandTop, point.y <= bandBottom else { continue }
            let beforeGlyph: Bool
            if point.y < rect.minY {
                beforeGlyph = true                  // above the block (or top padding)
            } else if point.y > rect.maxY {
                beforeGlyph = false                 // below the block (or bottom padding)
            } else {
                beforeGlyph = point.x < rect.midX   // in a side gutter: nearest edge
            }
            let offset = beforeGlyph
                ? paragraph.fullRange.location
                : min(paragraph.fullRange.location + 1, length)
            return position(from: beginningOfDocument, offset: offset)
        }
        return nil
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        let offset = offset(from: beginningOfDocument, to: position)
        var rect = super.caretRect(for: position)
        rect.size.width = 2
        // On a block line, span the caret over the image/table itself — its drawn
        // box, NOT the full line fragment, which now also includes the empty
        // tap padding above and below. Without this the caret would extend well
        // past the block into that padding.
        let caret = clampedCaret(offset, in: textStorage)
        if lineMeta(at: caret, in: textStorage).hasBlockContent {
            let ns = textStorage.string as NSString
            let paragraph = ns.paragraphRange(for: NSRange(location: min(caret, ns.length - 1), length: 0))
            let origin = CGPoint(x: textContainerInset.left, y: textContainerInset.top)
            if let para = paragraphRanges(in: ns).first(where: { $0.fullRange.location == paragraph.location }),
               let geometry = paragraphGeometry(for: para, origin: origin),
               let firstFragment = geometry.fragments.first,
               let box = blockRect(for: lineMeta(at: paragraph.location, in: textStorage), firstFragment: firstFragment) {
                rect.origin.y = box.minY
                rect.size.height = box.height
            }
            return rect
        }
        let textHeight = caretLineIsHeading(at: offset)
            ? DesktopEditorMetrics.headingLineHeight
            : DesktopEditorMetrics.textLineHeight
        if rect.height > textHeight {
            rect.size.height = textHeight
        }
        return rect
    }

    /// A line is a heading when its run carries the enlarged heading font.
    /// Probe both sides of the caret so it is detected at either line edge.
    func caretLineIsHeading(at offset: Int) -> Bool {
        let length = textStorage.length
        guard length > 0 else { return false }
        for probe in [offset, offset - 1] where probe >= 0 && probe < length {
            if let font = textStorage.attribute(.font, at: probe, effectiveRange: nil) as? UIFont,
               font.pointSize >= DesktopEditorMetrics.headingFontSize - 0.5 {
                return true
            }
        }
        return false
    }

    func configureTitle(title: String, theme: KnotQTheme, visible: Bool, editable: Bool, validator: @escaping (String) -> String?, onCommit: @escaping (String) -> Void) {
        inlineTitleView.configure(title: title, theme: theme, visible: visible, editable: editable, validator: validator, onCommit: onCommit)
        setNeedsLayout()
    }

    func focusTitle() {
        inlineTitleView.focusAndSelectTitle()
    }

    func layoutInlineTitleView() {
        let left = max(18, textContainerInset.left)
        let right = max(18, textContainerInset.right)
        let top = max(0, textContainerInset.top - DesktopEditorMetrics.titleBlockHeight + 4)
        inlineTitleView.frame = CGRect(
            x: left,
            y: top,
            width: max(0, bounds.width - left - right),
            height: DesktopEditorMetrics.titleBlockHeight
        )
    }

    func loadItems(_ items: [MobileItem], theme: KnotQTheme, timeFormat: String, placeCursorAtEnd: Bool) {
        let savedSelection = selectedRange
        self.theme = theme
        self.timeFormat = timeFormat
        coordinator?.suppress {
            let attributed = buildAttributedString(items: items, theme: theme, timeFormat: timeFormat)
            textStorage.setAttributedString(attributed)
            ensureWellFormed(textStorage, theme: theme)
            assignBlockAttachmentOwners()
        }
        let length = textStorage.length
        // I3: caret never past length - 1 (the trailing "\n").
        let targetLocation = placeCursorAtEnd
            ? max(0, length - 1)
            : clampedCaret(savedSelection.location, in: textStorage)
        selectedRange = NSRange(location: targetLocation, length: 0)
        typingAttributes = EditorAttributes.bodyAttributes(
            meta: lineMeta(at: targetLocation, in: textStorage),
            theme: theme
        )
        layoutManager.ensureLayout(for: textContainer)
        refreshMarkerVisibility(force: true)
        if placeCursorAtEnd {
            if isScrollEnabled {
                scrollRangeToVisible(NSRange(location: targetLocation, length: 0))
                // On first open the text view often has no real bounds yet, so the
                // initial scroll lands nowhere. Re-scroll to the end once layout has
                // settled so we reliably open at the very bottom of the document.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isScrollEnabled else { return }
                    self.scrollRangeToVisible(NSRange(location: max(0, self.textStorage.length - 1), length: 0))
                }
            }
        }
        refreshEmbeddedLayoutIfNeeded(deferred: true)
        setNeedsDisplay()
        coordinator?.markClean()
        endStaleCellEditorIfNeeded()
        consumePendingCellFocusIfNeeded()
    }

    func restyleForTheme(_ theme: KnotQTheme) {
        let savedSelection = selectedRange
        self.theme = theme
        coordinator?.suppress {
            textStorage.beginEditing()
            restyleEditorStorage(textStorage, theme: theme)
            textStorage.endEditing()
        }
        let targetLocation = clampedCaret(savedSelection.location, in: textStorage)
        let targetLength = min(
            savedSelection.length,
            max(0, textStorage.length - targetLocation)
        )
        selectedRange = NSRange(location: targetLocation, length: targetLength)
        typingAttributes = EditorAttributes.bodyAttributes(
            meta: lineMeta(at: targetLocation, in: textStorage),
            theme: theme
        )
        layoutManager.ensureLayout(for: textContainer)
        refreshMarkerVisibility(force: true)
        refreshEmbeddedLayoutIfNeeded(deferred: true)
        setNeedsDisplay()
    }

    func extractItemEdits() -> [MobileItemEdit] {
        coordinator?.suppress {
            textStorage.beginEditing()
            ensureWellFormed(textStorage, theme: theme)
            textStorage.endEditing()
        }
        return extractEdits(from: textStorage)
    }

    func isEffectivelyEmpty() -> Bool {
        // With invariant I1, "empty" = one paragraph (the trailing "\n") with
        // blank marker and zero indent.
        let ns = textStorage.string as NSString
        let paragraphs = paragraphRanges(in: ns)
        guard paragraphs.count <= 1 else { return false }
        guard let only = paragraphs.first else { return true }
        let body = bodyText(paragraphRange: only.fullRange, in: textStorage)
        let m = lineMeta(at: only.fullRange.location, in: textStorage)
        return body.isEmpty
            && m.marker == .blank
            && m.indent == 0
            && m.annotation == nil
            && m.media.isEmpty
            && m.tables.isEmpty
    }

    func appendTaskLine(theme: KnotQTheme) {
        let storage = textStorage
        let meta = LineMeta(marker: .checkbox)
        let attrs = EditorAttributes.bodyAttributes(meta: meta, theme: theme)
        var lineStart = storage.length
        coordinator?.suppress {
            storage.beginEditing()
            ensureWellFormed(storage, theme: theme)
            // Append a new line just before the final trailing "\n" so it lives
            // as its own paragraph with the new marker.
            lineStart = storage.length
            storage.replaceCharacters(
                in: NSRange(location: storage.length, length: 0),
                with: NSAttributedString(string: "\n", attributes: attrs)
            )
            let para = editableParagraphRange(in: storage.string as NSString, at: lineStart)
            setLineMeta(meta, onParagraph: para, in: storage, theme: theme)
            storage.endEditing()
        }
        selectedRange = NSRange(location: lineStart, length: 0)
        typingAttributes = attrs
        coordinator?.markDirty()
        if !isFirstResponder {
            _ = becomeFirstResponder()
        }
        setNeedsDisplay()
    }

    func currentLineItemID() -> String? {
        lineMeta(at: clampedCaret(selectedRange.location, in: textStorage), in: textStorage).itemID
    }

    /// Inserts an image as its own block line (single content per line). An empty
    /// plain line at the caret is converted in place; otherwise the image lands on
    /// a fresh block line just after the caret's line. The caret then moves past
    /// the block so typing continues below it.
    func attachImageMedia(_ media: MobileItemMedia, at location: Int?, theme: KnotQTheme) {
        let caret = clampedCaret(location ?? selectedRange.location, in: textStorage)
        let paragraph = editableParagraphRange(in: textStorage.string as NSString, at: caret)
        let old = lineMeta(at: paragraph.location, in: textStorage)
        let blockMeta = LineMeta(
            marker: .blank,
            indent: old.indent,
            media: [media],
            content: [.image(media: media)]
        )
        let blockParagraph = makeBlockAttributedParagraph(meta: blockMeta, theme: theme)
        let body = bodyText(paragraphRange: paragraph, in: textStorage)
        let replacesEmptyLine = body.isEmpty
            && !old.hasBlockContent
            && old.marker == .blank
            && old.annotation == nil
        let insertionLocation = replacesEmptyLine ? paragraph.location : NSMaxRange(paragraph)

        coordinator?.suppress {
            textStorage.beginEditing()
            if replacesEmptyLine {
                textStorage.replaceCharacters(in: paragraph, with: blockParagraph)
            } else {
                textStorage.replaceCharacters(
                    in: NSRange(location: insertionLocation, length: 0),
                    with: blockParagraph
                )
            }
            ensureWellFormed(textStorage, theme: theme)
            assignBlockAttachmentOwners()
            textStorage.endEditing()
        }

        let caretTarget = clampedCaret(insertionLocation + blockParagraph.length, in: textStorage)
        selectedRange = NSRange(location: caretTarget, length: 0)
        typingAttributes = EditorAttributes.bodyAttributes(
            meta: lineMeta(at: caretTarget, in: textStorage),
            theme: theme
        )
        coordinator?.markDirty()
        coordinator?.refreshEmpty()
        invalidateEmbeddedBlockDisplay(reflow: true)
        invalidateIntrinsicContentSize()
    }

    /// Inserts a fresh table block at the caret, rendered immediately so the
    /// table is visible the instant the toolbar button is tapped — no snapshot
    /// round-trip. `itemID` is the caller-minted id the eager `insert_table`
    /// command persists under, so the in-place cell editor can address this
    /// table's cells/rows right away. Mirrors `attachImageMedia`; the block
    /// persists through the normal document commit (`extractEdits` →
    /// `replaceSchemeItems`), which matches the item by `itemID`.
    func insertTableBlock(itemID: String, theme: KnotQTheme) {
        let table = MobileTable.freshEmpty()
        let caret = clampedCaret(selectedRange.location, in: textStorage)
        let paragraph = editableParagraphRange(in: textStorage.string as NSString, at: caret)
        let old = lineMeta(at: paragraph.location, in: textStorage)
        let blockMeta = LineMeta(
            marker: .blank,
            indent: old.indent,
            itemID: itemID,
            tables: [table],
            content: [.table(table: table)]
        )
        let blockParagraph = makeBlockAttributedParagraph(meta: blockMeta, theme: theme)
        let body = bodyText(paragraphRange: paragraph, in: textStorage)
        let replacesEmptyLine = body.isEmpty
            && !old.hasBlockContent
            && old.marker == .blank
            && old.annotation == nil
        let insertionLocation = replacesEmptyLine ? paragraph.location : NSMaxRange(paragraph)

        coordinator?.suppress {
            textStorage.beginEditing()
            if replacesEmptyLine {
                textStorage.replaceCharacters(in: paragraph, with: blockParagraph)
            } else {
                textStorage.replaceCharacters(
                    in: NSRange(location: insertionLocation, length: 0),
                    with: blockParagraph
                )
            }
            ensureWellFormed(textStorage, theme: theme)
            assignBlockAttachmentOwners()
            textStorage.endEditing()
        }

        let caretTarget = clampedCaret(insertionLocation + blockParagraph.length, in: textStorage)
        selectedRange = NSRange(location: caretTarget, length: 0)
        typingAttributes = EditorAttributes.bodyAttributes(
            meta: lineMeta(at: caretTarget, in: textStorage),
            theme: theme
        )
        coordinator?.markDirty()
        coordinator?.refreshEmpty()
        invalidateEmbeddedBlockDisplay(reflow: true)
        invalidateIntrinsicContentSize()
    }

    /// Points every `KnotQBlockAttachment` in the storage at this view so it can
    /// size its layout box against the live container width. Called after any
    /// edit that introduces block glyphs (load, paste, image insert).
    func assignBlockAttachmentOwners() {
        guard textStorage.length > 0 else { return }
        textStorage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: textStorage.length)
        ) { value, _, _ in
            (value as? KnotQBlockAttachment)?.owner = self
        }
    }

    /// Layout-box size for an image block at the given indent (scaled to fit the
    /// available content width). Used by `KnotQBlockAttachment.attachmentBounds`.
    func blockDisplaySize(forImage media: MobileItemMedia, indent: Int) -> CGSize {
        let size = mediaDisplaySize(media, maxWidth: blockMaxWidth(indent: indent))
        return CGSize(width: size.width, height: size.height + 2 * Self.blockVerticalPadding)
    }

    /// Layout-box size for a table block at the given indent (full content width,
    /// height from wrapped rows). Used by `KnotQBlockAttachment.attachmentBounds`.
    /// Includes `blockVerticalPadding` above and below so the block sits in its
    /// line with breathing room (and a tappable before/after strip).
    func blockDisplaySize(forTable table: MobileTable, indent: Int) -> CGSize {
        let maxWidth = blockMaxWidth(indent: indent)
        return CGSize(width: maxWidth, height: tableHeight(table, maxWidth: maxWidth) + 2 * Self.blockVerticalPadding)
    }

    func blockMaxWidth(indent: Int) -> CGFloat {
        let textLeft = textContainerInset.left + CGFloat(indent) * DesktopEditorMetrics.indentWidth
        return editorInlineBlockMaxWidth(textLeft: textLeft)
    }

    override func copy(_ sender: Any?) {
        if copyRichSelectionToPasteboard() {
            return
        }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        guard isEditable else {
            copy(sender)
            return
        }
        if let paragraphs = richSelectedParagraphs(), copyRichSelectionToPasteboard(paragraphs: paragraphs) {
            deleteWholeParagraphs(paragraphs)
            return
        }
        super.cut(sender)
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        if pasteRichItemsFromPasteboard() {
            return
        }
        super.paste(sender)
    }

    override func deleteBackward() {
        if deleteSelectedBlockParagraphsIfNeeded() {
            return
        }
        // Backspace at column 0 of the first line: UITextView won't fire
        // shouldChangeTextIn here (nothing precedes the caret), so clear the
        // first line's marker directly instead of silently doing nothing.
        if coordinator?.handleClearMarkerAtDocumentStart(in: self) == true {
            return
        }
        if applySelfSizingBackspace() {
            return
        }
        super.deleteBackward()
    }

    func applySelfSizingBackspace() -> Bool {
        guard !isScrollEnabled, markedTextRange == nil, let coordinator else { return false }
        let selection = selectedRange
        guard selection.length == 0, selection.location > 0 else { return false }
        let deletionRange = NSRange(location: selection.location - 1, length: 1)
        let ns = textStorage.string as NSString
        guard deletionRange.location < ns.length else { return false }
        let deletedCharacter = ns.character(at: deletionRange.location)

        if coordinator.textView(self, shouldChangeTextIn: deletionRange, replacementText: "") == false {
            return true
        }
        guard deletedCharacter != 10, deletedCharacter != blockObjectScalar else { return false }

        coordinator.suppress {
            textStorage.beginEditing()
            textStorage.replaceCharacters(in: deletionRange, with: "")
            ensureWellFormed(textStorage, theme: theme)
            textStorage.endEditing()
        }
        let caret = clampedCaret(deletionRange.location, in: textStorage)
        selectedRange = NSRange(location: caret, length: 0)
        typingAttributes = EditorAttributes.bodyAttributes(
            meta: lineMeta(at: caret, in: textStorage),
            theme: theme
        )
        coordinator.markDirty()
        coordinator.refreshEmpty()
        refreshMarkerVisibility(force: true)
        invalidateEmbeddedBlockDisplay(reflow: true)
        return true
    }

    // MARK: - Hardware-keyboard shortcuts
    //
    // Mirror the desktop editor's keymap for an iPad-with-keyboard (and Stage
    // Manager) experience: Tab/Shift-Tab indent, ⌘B/⌘I/⌘J formatting, and
    // ⌘1–⌘4 markers. These only fire while the document text view is first
    // responder; the in-place cell editor owns its own Tab handling.
    override var keyCommands: [UIKeyCommand]? {
        guard isEditable else { return nil }
        let commands = [
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleIndentKeyCommand)),
            UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(handleOutdentKeyCommand)),
            UIKeyCommand(input: "b", modifierFlags: .command, action: #selector(handleBoldKeyCommand)),
            UIKeyCommand(input: "i", modifierFlags: .command, action: #selector(handleItalicKeyCommand)),
            UIKeyCommand(input: "j", modifierFlags: .command, action: #selector(handleHeadingKeyCommand)),
            UIKeyCommand(input: "1", modifierFlags: .command, action: #selector(handleMarkerBlankKeyCommand)),
            UIKeyCommand(input: "2", modifierFlags: .command, action: #selector(handleMarkerCheckboxKeyCommand)),
            UIKeyCommand(input: "3", modifierFlags: .command, action: #selector(handleMarkerBulletKeyCommand)),
            UIKeyCommand(input: "4", modifierFlags: .command, action: #selector(handleMarkerNumberedKeyCommand)),
        ]
        for command in commands {
            command.wantsPriorityOverSystemBehavior = true
        }
        return commands
    }

    @objc private func handleIndentKeyCommand() { shiftCurrentIndent(1, theme: theme) }
    @objc private func handleOutdentKeyCommand() { shiftCurrentIndent(-1, theme: theme) }
    @objc private func handleBoldKeyCommand() { toggleWrappedMarkdown("**", theme: theme) }
    @objc private func handleItalicKeyCommand() { toggleWrappedMarkdown("_", theme: theme) }
    @objc private func handleHeadingKeyCommand() { toggleHeading(theme: theme) }
    @objc private func handleMarkerBlankKeyCommand() { setCurrentMarker(.blank, theme: theme) }
    @objc private func handleMarkerCheckboxKeyCommand() { setCurrentMarker(.checkbox, theme: theme) }
    @objc private func handleMarkerBulletKeyCommand() { setCurrentMarker(.bullet, theme: theme) }
    @objc private func handleMarkerNumberedKeyCommand() { setCurrentMarker(.numbered, theme: theme) }

    func setCurrentMarker(_ marker: Marker, theme: KnotQTheme) {
        let para = editableParagraphRange(in: textStorage.string as NSString, at: selectedRange.location)
        let old = lineMeta(at: para.location, in: textStorage)
        let newDone = (marker == .checkbox && old.marker == .checkbox) ? !old.done : false
        let new = LineMeta(
            marker: marker,
            indent: old.indent,
            done: newDone,
            itemID: old.itemID,
            annotation: marker == .checkbox ? old.annotation : nil,
            start: marker == .checkbox ? old.start : nil,
            end: marker == .checkbox ? old.end : nil,
            notificationOffsetSecs: marker == .checkbox ? old.notificationOffsetSecs : nil,
            repeatRule: marker == .checkbox ? old.repeatRule : nil,
            media: old.media,
            tables: old.tables
        )
        applyMeta(new, paragraphRange: para, theme: theme)
    }


}
