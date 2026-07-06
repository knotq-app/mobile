import SwiftUI
import UIKit

extension EditorCoordinator {
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

        // Both deferred passes below exist only for block (image/table) glyphs.
        // Skip them for plain-text documents so a keystroke doesn't schedule a
        // full-document display invalidation plus a per-paragraph isolation scan
        // on every character — dead work that lands one runloop tick after the
        // glyph and reads as the caret/scroll "catching up" late.
        let hasBlocks = containsBlockObject(storage.string)

        // Refresh embedded block (table/image) rendering, but DEFERRED. Doing it
        // here invalidates display against a layout manager that hasn't yet
        // processed this edit; its `_boundingRectForGlyphRange` then reads
        // `characterAtIndex` past the new length (NSRangeException) — UIKit's
        // autocorrection replace is the reliable trigger. The whole call must
        // wait until the edit cycle finishes, like the isolate pass below.
        if hasBlocks, !embeddedDisplayRefreshPending {
            embeddedDisplayRefreshPending = true
            DispatchQueue.main.async { [weak self] in
                self?.embeddedDisplayRefreshPending = false
                self?.view?.invalidateEmbeddedBlockDisplay()
            }
        }

        // I4 backstop runs deferred (length changes are unsafe inside this
        // callback — they corrupt the layout manager and crash a later pass).
        if hasBlocks, !blockIsolationPending {
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
    func normalizeAffectedParagraphs(in storage: NSTextStorage, around editedRange: NSRange) {
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
    func runBlockIsolationPass() {
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
    func maybeAutoBulletize(at editLocation: Int) {
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

}
