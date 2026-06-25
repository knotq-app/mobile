import SwiftUI
import UIKit

extension EditorCoordinator {
    /// Desktop parity: backspace at col 0 of a line with a non-blank marker
    /// clears the marker first instead of joining lines. The user has to
    /// backspace a second time to actually merge with the previous line.
    func handleClearMarkerBackspace(in view: EditorTextView, deletionRange: NSRange) -> Bool {
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
    func handleBlockMergeGuard(in view: EditorTextView, deletionRange: NSRange) -> Bool {
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
    func handleTypingOnBlockLine(in view: EditorTextView, range: NSRange, text: String) -> Bool {
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
    func glyphLineMeta(in storage: NSTextStorage, paragraphRange: NSRange) -> LineMeta? {
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
    func reconciledBlockMeta(_ meta: LineMeta, paragraphRange: NSRange, in storage: NSTextStorage) -> LineMeta {
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
    func handleMergeParagraphs(in view: EditorTextView, deletionRange: NSRange) -> Bool {
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
    func handleAutoBulletUndo(in view: EditorTextView, deletionRange: NSRange) -> Bool {
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
    func handleEnter(in view: EditorTextView, at cursor: Int) -> Bool {
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

    func continuationMeta(_ meta: LineMeta) -> LineMeta {
        LineMeta(marker: meta.marker, indent: meta.indent, done: false, itemID: nil, annotation: nil)
    }

    // MARK: NSTextStorageDelegate

}
