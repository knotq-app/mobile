import SwiftUI
import UIKit

extension EditorTextView {
    func copyRichSelectionToPasteboard(paragraphs: [EditorParagraphRange]? = nil) -> Bool {
        guard let paragraphs = paragraphs ?? richSelectedParagraphs(), !paragraphs.isEmpty else {
            return false
        }
        let ns = textStorage.string as NSString
        let items = paragraphs.map { paragraph in
            let meta = lineMeta(at: paragraph.fullRange.location, in: textStorage)
            return EditorRichClipboardItem(text: bodyText(paragraphRange: paragraph.fullRange, in: textStorage), meta: meta)
        }
        let plain = paragraphs
            .map { paragraph in
                paragraph.lineRange.length > 0 ? ns.substring(with: paragraph.lineRange) : ""
            }
            .joined(separator: "\n")
        guard !items.isEmpty,
              let data = try? JSONEncoder().encode(EditorRichClipboardPayload(items: items)) else {
            return false
        }
        UIPasteboard.general.setItems([[
            "public.utf8-plain-text": plain,
            editorRichClipboardType: data
        ]])
        return true
    }

    func pasteRichItemsFromPasteboard() -> Bool {
        guard let data = UIPasteboard.general.data(forPasteboardType: editorRichClipboardType),
              let payload = try? JSONDecoder().decode(EditorRichClipboardPayload.self, from: data),
              payload.format == editorRichClipboardFormat,
              !payload.items.isEmpty else {
            return false
        }
        if selectedRange.length > 0, richSelectedParagraphs() == nil {
            return false
        }

        let replaceRange = richPasteReplacementRange()
        let attributed = attributedString(forRichItems: payload.items)
        guard attributed.length > 0 else { return false }
        coordinator?.suppress {
            textStorage.beginEditing()
            textStorage.replaceCharacters(in: replaceRange, with: attributed)
            ensureWellFormed(textStorage, theme: theme)
            assignBlockAttachmentOwners()
            textStorage.endEditing()
        }
        let caret = clampedCaret(replaceRange.location + max(0, attributed.length - 1), in: textStorage)
        selectedRange = NSRange(location: caret, length: 0)
        typingAttributes = EditorAttributes.bodyAttributes(
            meta: lineMeta(at: caret, in: textStorage),
            theme: theme
        )
        coordinator?.markDirty()
        coordinator?.refreshEmpty()
        invalidateEmbeddedBlockDisplay(reflow: true)
        setNeedsDisplay()
        return true
    }

    func attributedString(forRichItems items: [EditorRichClipboardItem]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for item in items {
            let meta = item.lineMeta(timeFormat: timeFormat)
            // A block item pastes as its own block paragraph (single content per
            // line); its stored `text` is just the sentinel glyph and is ignored.
            if meta.hasBlockContent {
                result.append(makeBlockAttributedParagraph(meta: meta, theme: theme))
                continue
            }
            let attrs = EditorAttributes.bodyAttributes(meta: meta, theme: theme)
            let bodyLocation = result.length
            result.append(NSAttributedString(string: item.text, attributes: attrs))
            let bodyRange = NSRange(location: bodyLocation, length: (item.text as NSString).length)
            result.append(NSAttributedString(string: "\n", attributes: attrs))
            applyInlineMarkdownStyling(body: item.text, bodyRange: bodyRange, in: result)
        }
        return result
    }

    func richSelectedParagraphs() -> [EditorParagraphRange]? {
        richParagraphs(in: selectedRange)
    }

    @discardableResult
    func deleteSelectedBlockParagraphsIfNeeded(in range: NSRange? = nil) -> Bool {
        guard isEditable else { return false }
        let target = range ?? selectedRange
        guard let paragraphs = richParagraphs(in: target), !paragraphs.isEmpty else {
            return false
        }
        let deletedItemIDs = Set(paragraphs.compactMap { paragraph in
            lineMeta(at: paragraph.fullRange.location, in: textStorage).itemID
        })
        guard paragraphs.contains(where: { paragraph in
            lineMeta(at: paragraph.fullRange.location, in: textStorage).hasBlockContent
        }) else {
            return false
        }
        if let editor = activeCellEditor, deletedItemIDs.contains(editor.hit.itemID) {
            endTableCellEditing(commit: false)
        }
        deleteWholeParagraphs(paragraphs)
        return true
    }

    func richParagraphs(in range: NSRange) -> [EditorParagraphRange]? {
        guard range.length > 0 else { return nil }
        let ns = textStorage.string as NSString
        guard ns.length > 0,
              range.location >= 0,
              NSMaxRange(range) <= ns.length else {
            return nil
        }
        let all = paragraphRanges(in: ns)
        guard let startIndex = all.firstIndex(where: { $0.fullRange.location == range.location }) else {
            return nil
        }
        let end = NSMaxRange(range)
        for index in startIndex..<all.count {
            let paragraph = all[index]
            if end == NSMaxRange(paragraph.lineRange) || end == NSMaxRange(paragraph.fullRange) {
                return Array(all[startIndex...index])
            }
            if end < NSMaxRange(paragraph.fullRange) {
                return nil
            }
        }
        return nil
    }

    func richPasteReplacementRange() -> NSRange {
        if let paragraphs = richSelectedParagraphs(),
           let first = paragraphs.first,
           let last = paragraphs.last {
            return NSRange(location: first.fullRange.location, length: NSMaxRange(last.fullRange) - first.fullRange.location)
        }

        let ns = textStorage.string as NSString
        let caret = clampedCaret(selectedRange.location, in: textStorage)
        let paragraph = editableParagraphRange(in: ns, at: caret)
        let line = lineRange(from: paragraph, in: ns)
        if line.length == 0 {
            return paragraph
        }
        if caret <= paragraph.location {
            return NSRange(location: paragraph.location, length: 0)
        }
        return NSRange(location: NSMaxRange(paragraph), length: 0)
    }

    func deleteWholeParagraphs(_ paragraphs: [EditorParagraphRange]) {
        guard let first = paragraphs.first, let last = paragraphs.last else { return }
        let deleteRange = NSRange(
            location: first.fullRange.location,
            length: NSMaxRange(last.fullRange) - first.fullRange.location
        )
        coordinator?.suppress {
            textStorage.beginEditing()
            textStorage.replaceCharacters(in: deleteRange, with: NSAttributedString(string: ""))
            ensureWellFormed(textStorage, theme: theme)
            textStorage.endEditing()
        }
        let caret = clampedCaret(deleteRange.location, in: textStorage)
        selectedRange = NSRange(location: caret, length: 0)
        typingAttributes = EditorAttributes.bodyAttributes(meta: lineMeta(at: caret, in: textStorage), theme: theme)
        coordinator?.markDirty()
        coordinator?.refreshEmpty()
        invalidateEmbeddedBlockDisplay(reflow: true)
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    func shiftCurrentIndent(_ delta: Int, theme: KnotQTheme) {
        let para = editableParagraphRange(in: textStorage.string as NSString, at: selectedRange.location)
        let old = lineMeta(at: para.location, in: textStorage)
        let new = old.with(indent: max(0, min(8, old.indent + delta)))
        applyMeta(new, paragraphRange: para, theme: theme)
    }

    func toggleWrappedMarkdown(_ delimiter: String, theme: KnotQTheme) {
        let ns = textStorage.string as NSString
        let target: NSRange
        if selectedRange.length > 0 {
            target = selectedRange
        } else {
            let para = editableParagraphRange(in: ns, at: selectedRange.location)
            target = lineRange(from: para, in: ns)
        }
        guard target.location <= ns.length, NSMaxRange(target) <= ns.length else { return }
        let selected = target.length > 0 ? ns.substring(with: target) : ""
        let dlen = delimiter.count
        let wasWrapped = selected.count >= dlen * 2
            && selected.hasPrefix(delimiter)
            && selected.hasSuffix(delimiter)
        let replacement = wasWrapped
            ? String(selected.dropFirst(dlen).dropLast(dlen))
            : "\(delimiter)\(selected)\(delimiter)"
        let meta = lineMeta(at: target.location, in: textStorage)
        let attrs = EditorAttributes.bodyAttributes(meta: meta, theme: theme)
        textStorage.replaceCharacters(
            in: target,
            with: NSAttributedString(string: replacement, attributes: attrs)
        )
        let newLength = (replacement as NSString).length
        let caret: NSRange
        if selectedRange.length > 0 {
            caret = NSRange(location: target.location, length: newLength)
        } else if !wasWrapped {
            caret = NSRange(location: target.location + (delimiter as NSString).length, length: 0)
        } else {
            caret = NSRange(location: target.location + newLength, length: 0)
        }
        selectedRange = caret
        coordinator?.markDirty()
        setNeedsDisplay()
    }

    func toggleHeading(theme: KnotQTheme) {
        let ns = textStorage.string as NSString
        let para = editableParagraphRange(in: ns, at: selectedRange.location)
        let lineText = bodyText(paragraphRange: para, in: textStorage)
        let leading = lineText.prefix { $0 == " " || $0 == "\t" }
        let afterLeading = String(lineText.dropFirst(leading.count))
        let hashes = afterLeading.prefix { $0 == "#" }.count
        let isHeading: Bool = {
            guard hashes > 0 else { return false }
            if afterLeading.count == hashes { return true }
            let idx = afterLeading.index(afterLeading.startIndex, offsetBy: hashes)
            return afterLeading[idx].isWhitespace
        }()
        let meta = lineMeta(at: para.location, in: textStorage)
        let attrs = EditorAttributes.bodyAttributes(meta: meta, theme: theme)
        let savedSelection = selectedRange
        let leadingLen = (leading as NSString).length
        if isHeading {
            var removeLen = hashes
            let nsAfter = afterLeading as NSString
            if nsAfter.length > hashes {
                let ch = nsAfter.character(at: hashes)
                if ch == 32 || ch == 9 { removeLen += 1 }
            }
            textStorage.replaceCharacters(
                in: NSRange(location: para.location + leadingLen, length: removeLen),
                with: NSAttributedString(string: "", attributes: attrs)
            )
            selectedRange = NSRange(
                location: max(para.location, savedSelection.location - removeLen),
                length: savedSelection.length
            )
        } else {
            let insertion = "# "
            textStorage.replaceCharacters(
                in: NSRange(location: para.location + leadingLen, length: 0),
                with: NSAttributedString(string: insertion, attributes: attrs)
            )
            selectedRange = NSRange(
                location: savedSelection.location + (insertion as NSString).length,
                length: savedSelection.length
            )
        }
        coordinator?.markDirty()
        setNeedsDisplay()
    }

    /// Single internal entry point used by every "change just the meta" action
    /// (set marker, shift indent, toggle checkbox). Suppresses the textStorage
    /// delegate because we already maintain the invariants here.
    func applyMeta(_ meta: LineMeta, paragraphRange: NSRange, theme: KnotQTheme) {
        coordinator?.suppress {
            textStorage.beginEditing()
            setLineMeta(meta, onParagraph: paragraphRange, in: textStorage, theme: theme)
            textStorage.endEditing()
        }
        typingAttributes = EditorAttributes.bodyAttributes(meta: meta, theme: theme)
        coordinator?.markDirty()
        coordinator?.refreshToolbarActiveMarker(in: self)
        invalidateEmbeddedBlockDisplay(reflow: true)
    }

    @discardableResult
    func toggleCheckboxAt(point: CGPoint) -> Bool {
        let ns = textStorage.string as NSString
        guard let lineRange = checkboxLineRange(at: point) else { return false }
        let para = ns.paragraphRange(for: lineRange)
        let old = lineMeta(at: para.location, in: textStorage)
        applyMeta(old.with(done: !old.done), paragraphRange: para, theme: theme)
        return true
    }

    func checkboxLineRange(at point: CGPoint) -> NSRange? {
        let ns = textStorage.string as NSString
        let origin = CGPoint(x: textContainerInset.left, y: textContainerInset.top)
        for paragraph in paragraphRanges(in: ns) {
            let characterRange = paragraph.lineRange.length > 0 ? paragraph.lineRange : paragraph.fullRange
            guard characterRange.length > 0 else { continue }
            let glyphRange = self.layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
            guard self.layoutManager.numberOfGlyphs > 0, glyphRange.location < self.layoutManager.numberOfGlyphs else { continue }
            let fragment = self.layoutManager.lineFragmentUsedRect(forGlyphAt: glyphRange.location, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
            let meta = metaForLine(storage: self.textStorage, lineRange: paragraph.lineRange)
            guard meta.marker == .checkbox else { continue }
            let rect = self.markerRect(for: meta, fragment: fragment).insetBy(dx: -8, dy: -8)
            if rect.contains(point) {
                return paragraph.lineRange
            }
        }
        return nil
    }

}
