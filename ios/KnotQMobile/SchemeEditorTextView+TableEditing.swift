import SwiftUI
import UIKit

extension EditorTextView {
    func tableDimensions(itemID: String, tableIndex: Int) -> (rows: Int, columns: Int)? {
        guard let meta = metaForItem(itemID),
              case let .table(table)? = meta.blockInline else { return nil }
        return (table.rows.count, tableColumnCount(table))
    }

    func metaForItem(_ itemID: String) -> LineMeta? {
        let ns = textStorage.string as NSString
        for paragraph in paragraphRanges(in: ns) {
            let meta = lineMeta(at: paragraph.fullRange.location, in: textStorage)
            if meta.itemID == itemID { return meta }
        }
        return nil
    }

    func tableCellHit(at point: CGPoint) -> EditorTableCellHit? {
        // No slack: cells tile their grid exactly, and a tap just past the grid's
        // outer edge belongs to the caret before/after the table (`blockEdgeCaret`),
        // not to the nearest cell. Growing the cell rects here would swallow those
        // gutter taps and make placing the caret beside a table unreliable.
        if let recorded = renderedTableCellHits.last(where: { $0.rect.contains(point) }) {
            return recorded.hit
        }
        // Fallback: recompute the grid geometry when the cell hasn't been drawn
        // yet (e.g. off-screen). Mirrors `drawBlock`/`drawTable`.
        return enumerateTableCells { hit in
            hit.frame.contains(point) ? hit : nil
        }
    }

    /// Looks up a specific cell's current hit (with its frame) for Tab / arrow
    /// navigation. Prefers a recorded rect; recomputes geometry otherwise.
    func tableCellHit(itemID: String, tableIndex: Int, row: Int, column: Int) -> EditorTableCellHit? {
        if let recorded = renderedTableCellHits.last(where: {
            $0.hit.itemID == itemID && $0.hit.tableIndex == tableIndex && $0.hit.row == row && $0.hit.column == column
        }) {
            return recorded.hit
        }
        return enumerateTableCells { hit in
            (hit.itemID == itemID && hit.tableIndex == tableIndex && hit.row == row && hit.column == column) ? hit : nil
        }
    }

    /// Walks every table cell, invoking `match` with each cell's hit (frame in
    /// content coordinates); returns the first non-nil result. The geometry
    /// mirrors `drawTable` exactly, so a hit found this way lands on the rect the
    /// cell is drawn at. Each block line holds at most one table (tableIndex 0).
    func enumerateTableCells(_ match: (EditorTableCellHit) -> EditorTableCellHit?) -> EditorTableCellHit? {
        let ns = textStorage.string as NSString
        let origin = CGPoint(x: textContainerInset.left, y: textContainerInset.top)
        for paragraph in paragraphRanges(in: ns) {
            let meta = lineMeta(at: paragraph.fullRange.location, in: textStorage)
            guard let itemID = meta.itemID,
                  case let .table(table)? = meta.blockInline,
                  let geometry = paragraphGeometry(for: paragraph, origin: origin),
                  let firstFragment = geometry.fragments.first,
                  let rect = blockRect(for: meta, firstFragment: firstFragment) else { continue }
            if let result = matchTableCells(table: table, itemID: itemID, in: rect, match: match) {
                return result
            }
        }
        return nil
    }

    /// Visits the header + body cells of `table` laid out in `rect` (the table's
    /// block box), in the same geometry `drawTable` paints.
    func matchTableCells(
        table: MobileTable,
        itemID: String,
        in rect: CGRect,
        match: (EditorTableCellHit) -> EditorTableCellHit?
    ) -> EditorTableCellHit? {
        let columnCount = tableColumnCount(table)
        guard columnCount > 0, rect.width > 0 else { return nil }
        let colWidth = rect.width / CGFloat(columnCount)
        for column in 0..<columnCount {
            let cellRect = CGRect(
                x: rect.minX + CGFloat(column) * colWidth,
                y: rect.minY,
                width: colWidth,
                height: DesktopEditorMetrics.tableHeaderHeight
            )
            let title = column < table.columns.count ? table.columns[column].name : "Column \(column + 1)"
            let hit = EditorTableCellHit(
                itemID: itemID, tableIndex: 0, row: -1, column: column, text: title, frame: cellRect
            )
            if let result = match(hit) { return result }
        }
        var bodyY = rect.minY + DesktopEditorMetrics.tableHeaderHeight
        let rowHeights = tableRowHeights(table, columnWidth: colWidth)
        for row in 0..<table.rows.count {
            let rowHeight = rowHeights.indices.contains(row) ? rowHeights[row] : DesktopEditorMetrics.tableCellHeight
            for column in 0..<columnCount {
                let cellRect = CGRect(
                    x: rect.minX + CGFloat(column) * colWidth,
                    y: bodyY,
                    width: colWidth,
                    height: rowHeight
                )
                let cell = column < table.rows[row].cells.count ? table.rows[row].cells[column] : nil
                let hit = EditorTableCellHit(
                    itemID: itemID, tableIndex: 0, row: row, column: column,
                    text: tableCellDisplayText(cell), frame: cellRect
                )
                if let result = match(hit) { return result }
            }
            bodyY += rowHeight
        }
        return nil
    }

    // MARK: - In-place table cell editing

    var isEditingTableCell: Bool { activeCellEditor != nil }

    /// True when a structural table change (insert/delete row/column) is waiting
    /// for the document to reload before retargeting the cell editor — the one
    /// case where a mid-edit reload must still run.
    var hasPendingCellFocus: Bool { pendingCellFocus != nil }

    /// Starts (or moves) the in-place editor over `hit`. Resigns the document's
    /// own keyboard so the cell field owns input, and focuses it.
    func beginEditingTableCell(_ hit: EditorTableCellHit) {
        guard isEditable else { return }
        // The cell field becoming first responder hands input off from the
        // document automatically; no manual resign needed.
        if let editor = activeCellEditor {
            activeCellEditorWasDocumentBacked = tableCellExists(hit)
            editor.retarget(to: hit)
            editor.focus()
            return
        }
        let editor = EditorTableCellEditor(hit: hit, theme: theme)
        editor.onCommit = { [weak self] hit, text, reason in
            self?.handleCellCommit(hit, text: text, reason: reason)
        }
        editor.onFlush = { [weak self] hit, text in
            // Persist only — never tears the editor down (the caller is reusing it).
            self?.onTableCellCommit?(hit, text)
            self?.applyTableCellEditOptimistically(hit, text: text)
        }
        editor.onRequestEnd = { [weak self] in
            // Dismiss already flushed; tear the overlay down without re-committing.
            self?.endTableCellEditing(commit: false)
        }
        editor.onStructureAction = { [weak self] hit, action in
            self?.handleCellStructureAction(hit, action: action)
        }
        addSubview(editor)
        activeCellEditor = editor
        activeCellEditorWasDocumentBacked = tableCellExists(hit)
        editor.focus()
    }

    /// Tears down the active cell editor. Pass `commit: true` to flush its text
    /// first (used when the document is committed / loses focus).
    func endTableCellEditing(commit: Bool) {
        guard let editor = activeCellEditor else { return }
        // Editing is ending for real, so any queued post-reload retarget is moot.
        pendingCellFocus = nil
        let shouldCommit = commit && (!activeCellEditorWasDocumentBacked || tableCellExists(editor.hit))
        if shouldCommit {
            editor.commit(reason: nil)
        } else {
            editor.discardOnEndEditing()
        }
        activeCellEditor = nil
        activeCellEditorWasDocumentBacked = false
        editor.field.resignFirstResponder()
        editor.removeFromSuperview()
    }

    func tableCellExists(_ hit: EditorTableCellHit) -> Bool {
        guard let dims = tableDimensions(itemID: hit.itemID, tableIndex: hit.tableIndex),
              hit.column >= 0,
              hit.column < dims.columns else {
            return false
        }
        if hit.isHeader {
            return true
        }
        return hit.row >= 0 && hit.row < dims.rows
    }

    func endStaleCellEditorIfNeeded() {
        guard pendingCellFocus == nil,
              activeCellEditorWasDocumentBacked,
              let editor = activeCellEditor else { return }
        if !tableCellExists(editor.hit) {
            endTableCellEditing(commit: false)
        }
    }

    func handleCellStructureAction(_ hit: EditorTableCellHit, action: EditorCellStructureAction) {
        // Queue the cell to land on once the grid reloads, then run the op. The
        // editor stays mounted; `loadItems` retargets it via `pendingCellFocus`
        // so the keyboard never collapses between structural edits.
        pendingCellFocus = structureFocusTarget(for: hit, action: action)
        switch action {
        case .insertRowAbove:
            onTableInsertRow?(hit, hit.row)
        case .insertRowBelow:
            onTableInsertRow?(hit, hit.row + 1)
        case .deleteRow: onTableDeleteRow?(hit)
        case .insertColumnLeft:
            onTableInsertColumn?(hit, hit.column)
        case .insertColumnRight:
            onTableInsertColumn?(hit, hit.column + 1)
        case .deleteColumn: onTableDeleteColumn?(hit)
        }
    }

    /// Which cell the editor should occupy after `action` reshapes the grid.
    /// Inserts land on the freshly created row/column; deletes land on the cell
    /// that slides into the deleted one's place. If the target no longer exists
    /// (e.g. the last row/column was deleted) `consumePendingCellFocusIfNeeded`
    /// resolves to nil and ends editing gracefully.
    func structureFocusTarget(for hit: EditorTableCellHit, action: EditorCellStructureAction) -> (itemID: String, tableIndex: Int, row: Int, column: Int) {
        switch action {
        case .insertRowAbove:
            return (hit.itemID, hit.tableIndex, hit.row, hit.column)
        case .insertRowBelow:
            return (hit.itemID, hit.tableIndex, hit.row + 1, hit.column)
        case .insertColumnLeft:
            return (hit.itemID, hit.tableIndex, hit.row, hit.column)
        case .insertColumnRight:
            return (hit.itemID, hit.tableIndex, hit.row, hit.column + 1)
        case .deleteRow:
            return (hit.itemID, hit.tableIndex, hit.row, hit.column)
        case .deleteColumn:
            return (hit.itemID, hit.tableIndex, hit.row, hit.column)
        }
    }

    /// After a reload triggered by a structural change, move the still-mounted
    /// cell editor onto the queued target using freshly computed geometry. The
    /// recorded hit rects predate the change, so drop them and let the lookup fall
    /// back to the document-order recompute. Ends editing if the target is gone.
    func consumePendingCellFocusIfNeeded() {
        guard let target = pendingCellFocus else { return }
        pendingCellFocus = nil
        guard activeCellEditor != nil else { return }
        layoutManager.ensureLayout(for: textContainer)
        renderedTableCellHits.removeAll()
        if let hit = tableCellHit(itemID: target.itemID, tableIndex: target.tableIndex, row: target.row, column: target.column) {
            activeCellEditor?.retarget(to: hit)
            activeCellEditor?.focus()
        } else {
            endTableCellEditing(commit: false)
        }
    }

    func handleCellCommit(_ hit: EditorTableCellHit, text: String, reason: EditorCellCommitReason) {
        if text != hit.text {
            onTableCellCommit?(hit, text)
            // Show the edit on the drawn cell immediately; the model round-trip
            // reloads later and reconciles to the same value.
            applyTableCellEditOptimistically(hit, text: text)
        }
        switch reason {
        case .resign:
            // The model write reloads the document; just drop the editor.
            activeCellEditor?.removeFromSuperview()
            activeCellEditor = nil
            activeCellEditorWasDocumentBacked = false
        case .moveDown:
            moveCellEditor(from: hit, rowDelta: 1, columnDelta: 0, textChanged: text != hit.text)
        case .moveNext:
            moveCellEditor(from: hit, rowDelta: 0, columnDelta: 1, textChanged: text != hit.text)
        case .movePrevious:
            moveCellEditor(from: hit, rowDelta: 0, columnDelta: -1, textChanged: text != hit.text)
        }
    }

    /// Patch the drawn table cell (or header) for `hit` to `text` right away, so
    /// the edit is visible before the model write reloads the document. The
    /// reload then reconciles to the authoritative value (a no-op when equal).
    func applyTableCellEditOptimistically(_ hit: EditorTableCellHit, text: String) {
        let ns = textStorage.string as NSString
        for paragraph in paragraphRanges(in: ns) {
            let meta = lineMeta(at: paragraph.fullRange.location, in: textStorage)
            guard meta.itemID == hit.itemID else { continue }
            guard let newMeta = meta.patchingTable(
                tableIndex: hit.tableIndex,
                row: hit.row,
                column: hit.column,
                isHeader: hit.isHeader,
                text: text
            ) else { continue }
            coordinator?.suppress {
                textStorage.beginEditing()
                setLineMeta(newMeta, onParagraph: paragraph.fullRange, in: textStorage, theme: theme)
                textStorage.endEditing()
            }
            invalidateEmbeddedBlockDisplay(reflow: true)
            return
        }
    }

    /// Moves the editor to a neighboring cell, wrapping across rows for Tab and
    /// clamping at the grid edges. When the text changed, the model write will
    /// reload the document and recompute geometry; we re-resolve the target hit
    /// on the next runloop so it lands on the freshly drawn rect.
    func moveCellEditor(from hit: EditorTableCellHit, rowDelta: Int, columnDelta: Int, textChanged: Bool) {
        guard let dims = tableDimensions(itemID: hit.itemID, tableIndex: hit.tableIndex), dims.rows > 0, dims.columns > 0 else {
            endTableCellEditing(commit: false)
            return
        }
        var row = hit.row
        var column = hit.column
        if columnDelta != 0 {
            // Tab / Shift-Tab: advance linearly across the grid, wrapping rows.
            var linear = (row + 1) * dims.columns + column + columnDelta
            let total = (dims.rows + 1) * dims.columns
            if linear < 0 || linear >= total {
                // Past either end — stop editing rather than wrap out of bounds.
                endTableCellEditing(commit: false)
                return
            }
            linear = max(0, min(total - 1, linear))
            row = linear / dims.columns - 1
            column = linear % dims.columns
        } else {
            row += rowDelta
            if row < -1 || row >= dims.rows {
                endTableCellEditing(commit: false)
                return
            }
        }

        let targetRow = row
        let targetColumn = column
        let focusNeighbor: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, let editor = self.activeCellEditor else { return }
            if let next = self.tableCellHit(itemID: hit.itemID, tableIndex: hit.tableIndex, row: targetRow, column: targetColumn) {
                editor.retarget(to: next)
                // Tab/arrow into a cell selects the whole cell (desktop parity).
                editor.focusSelectingAll()
            } else {
                self.endTableCellEditing(commit: false)
            }
        }

        if textChanged {
            // Defer until the model write + reload settle so geometry is current.
            DispatchQueue.main.async(execute: focusNeighbor)
        } else {
            focusNeighbor()
        }
    }

    func annotationGuideX(marker: CGRect) -> CGFloat {
        marker.minX - (DesktopEditorMetrics.annotationBarGap + DesktopEditorMetrics.indentGuideXShift)
    }

    func markerRect(for meta: LineMeta, fragment: CGRect) -> CGRect {
        CGRect(
            x: textContainerInset.left + CGFloat(meta.indent) * DesktopEditorMetrics.indentWidth,
            y: fragment.minY + (fragment.height - DesktopEditorMetrics.checkboxSize) / 2
                + DesktopEditorMetrics.markerVerticalNudge,
            width: DesktopEditorMetrics.checkboxSize,
            height: DesktopEditorMetrics.checkboxSize
        )
    }

    func annotationSpacingAfterGlyph(at glyphIndex: Int) -> CGFloat {
        let ns = textStorage.string as NSString
        guard glyphIndex >= 0,
              glyphIndex < layoutManager.numberOfGlyphs,
              ns.length > 0 else { return 0 }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < ns.length else { return 0 }
        let paragraphRange = ns.paragraphRange(for: NSRange(location: characterIndex, length: 0))
        let line = lineRange(from: paragraphRange, in: ns)
        let meta = metaForLine(storage: textStorage, lineRange: line)
        // A block line's image/table is sized by its attachment glyph, so only a
        // date annotation reserves extra space below the line here.
        guard meta.annotation != nil else { return 0 }
        let spacing = DesktopEditorMetrics.annotationHeight
        let lastContentCharacter = line.length > 0 ? NSMaxRange(line) - 1 : paragraphRange.location
        return characterIndex >= lastContentCharacter ? spacing : 0
    }

    func paragraphGeometry(for paragraph: EditorParagraphRange, origin: CGPoint) -> (glyphRange: NSRange, fragments: [CGRect], bounds: CGRect)? {
        let characterRange = paragraph.lineRange.length > 0 ? paragraph.lineRange : paragraph.fullRange
        guard let safeCharacterRange = nonEmptyTextRange(characterRange, length: textStorage.length) else { return nil }
        let rawGlyphRange = layoutManager.glyphRange(forCharacterRange: safeCharacterRange, actualCharacterRange: nil)
        let numberOfGlyphs = layoutManager.numberOfGlyphs
        guard numberOfGlyphs > 0, rawGlyphRange.location < numberOfGlyphs else { return nil }
        // Clamp to the live glyph count. If a deferred draw runs against a
        // layout that hasn't fully regenerated after an edit, the mapped range
        // can extend past the current glyphs; enumerating it would make TextKit
        // read a character index at/after the string end (NSRangeException).
        let glyphRange = NSRange(
            location: rawGlyphRange.location,
            length: min(rawGlyphRange.length, numberOfGlyphs - rawGlyphRange.location)
        )
        var fragments: [CGRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, fragmentGlyphRange, _ in
            guard NSIntersectionRange(fragmentGlyphRange, glyphRange).length > 0 else { return }
            fragments.append(usedRect.offsetBy(dx: origin.x, dy: origin.y))
        }
        guard let first = fragments.first else { return nil }
        let bounds = fragments.dropFirst().reduce(first) { $0.union($1) }
        return (glyphRange, fragments, bounds)
    }
}
