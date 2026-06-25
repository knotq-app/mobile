import SwiftUI
import UIKit

extension EditorTextView {
    func drawChrome(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        renderedTableCellHits.removeAll()
        let storage = textStorage
        let ns = storage.string as NSString
        let paragraphs = paragraphRanges(in: ns)
        let metas: [LineMeta] = paragraphs.map { lineMeta(at: $0.fullRange.location, in: storage) }
        for index in paragraphs.indices {
            let paragraph = paragraphs[index]
            guard let geometry = paragraphGeometry(for: paragraph, origin: origin) else { continue }
            let glyphRange = geometry.glyphRange
            guard NSIntersectionRange(glyphRange, glyphsToShow).length > 0 else { continue }
            guard let firstFragment = geometry.fragments.first else { continue }
            let visualBounds = geometry.bounds
            let meta = metas[index]
            let previousMeta = index > 0 ? metas[index - 1] : nil
            let nextMeta = index + 1 < metas.count ? metas[index + 1] : nil
            let previousAnnotated = previousMeta?.annotation != nil
            let nextAnnotated = nextMeta?.annotation != nil
            // A block line's image/table occupies its line fragment (the
            // attachment glyph sized it), so no extra height is reserved here.
            let annotationHeight = meta.annotation == nil ? CGFloat(0) : DesktopEditorMetrics.annotationHeight
            let rowExtraHeight = annotationHeight
            let ordinal = meta.marker == .numbered ? numberedOrdinal(at: index, in: metas) : 1
            drawIndentGuides(
                meta: meta, previousMeta: previousMeta, nextMeta: nextMeta,
                firstFragment: firstFragment, visualBounds: visualBounds,
                rowExtraHeight: rowExtraHeight, context: context
            )
            drawMarker(meta: meta, ordinal: ordinal, fragment: firstFragment, context: context)
            if let annotation = meta.annotation {
                drawAnnotationBar(meta: meta, firstFragment: firstFragment, visualBounds: visualBounds, rowExtraHeight: rowExtraHeight, connectsToPrevious: previousAnnotated, connectsToNext: nextAnnotated, context: context)
                drawAnnotation(annotation, meta: meta, visualBounds: visualBounds, context: context)
            }
            // A block line: paint the image/table into its glyph's box. The box
            // is the line fragment (top-left at the head indent), matching the
            // size the attachment reserved during layout.
            if meta.hasBlockContent {
                drawBlock(meta: meta, firstFragment: firstFragment, paragraphRange: paragraph.fullRange, context: context)
            }
        }
    }

    /// The content-coordinate box for a block line's image/table: the head-indent
    /// x, the fragment top, and the size the attachment reserved. nil if the line
    /// carries no block.
    func blockRect(for meta: LineMeta, firstFragment: CGRect) -> CGRect? {
        guard let block = meta.blockInline else { return nil }
        let textLeft = firstFragment.minX
        let maxWidth = editorInlineBlockMaxWidth(textLeft: textLeft)
        guard maxWidth > 0 else { return nil }
        // The block is drawn inset below the fragment top by `blockVerticalPadding`
        // (its box height reserved that padding above and below); the gaps are the
        // before/after tap target. `attachmentBounds` and `blockEdgeCaret` mirror
        // this exactly.
        let top = firstFragment.minY + Self.blockVerticalPadding
        switch block {
        case let .image(media):
            let size = mediaDisplaySize(media, maxWidth: maxWidth)
            return CGRect(x: textLeft, y: top, width: size.width, height: size.height)
        case let .table(table):
            let height = tableHeight(table, maxWidth: maxWidth)
            return CGRect(x: textLeft, y: top, width: maxWidth, height: height)
        case .text:
            return nil
        }
    }

    /// Paints a block line's single image/table into `blockRect`, recording table
    /// cell hit rects so the in-place cell editor can position itself.
    func drawBlock(meta: LineMeta, firstFragment: CGRect, paragraphRange: NSRange, context: CGContext) {
        guard let block = meta.blockInline, let rect = blockRect(for: meta, firstFragment: firstFragment) else { return }
        switch block {
        case let .image(media):
            drawImageMedia(media, in: rect, context: context)
        case let .table(table):
            drawTable(table, itemID: meta.itemID, tableIndex: 0, in: rect, context: context)
        case .text:
            break
        }
    }

    /// Counts the current line as Nth where N = 1 + the number of consecutive
    /// prior Numbered siblings at the same indent (nested-deeper lines are
    /// transparent; anything at a shallower indent or a non-Numbered at the
    /// same indent ends the run). Mirrors desktop's `numbered_marker_ordinal`.
    func numberedOrdinal(at index: Int, in metas: [LineMeta]) -> Int {
        let currentIndent = metas[index].indent
        var ordinal = 1
        var i = index - 1
        while i >= 0 {
            let prev = metas[i]
            if prev.indent > currentIndent { i -= 1; continue }
            if prev.indent < currentIndent { break }
            if prev.marker != .numbered { break }
            ordinal += 1
            i -= 1
        }
        return ordinal
    }

    func drawIndentGuides(meta: LineMeta, previousMeta: LineMeta?, nextMeta: LineMeta?, firstFragment: CGRect, visualBounds: CGRect, rowExtraHeight: CGFloat, context: CGContext) {
        let indent = min(meta.indent, 8)
        guard indent > 0 else { return }
        context.setFillColor(UIColor(theme.dividerSoft).cgColor)
        let marker = markerRect(for: meta, fragment: firstFragment)
        let ownBarX = marker.minX - (DesktopEditorMetrics.annotationBarGap + DesktopEditorMetrics.indentGuideXShift)
        let rowHeight = visualBounds.maxY - firstFragment.minY + rowExtraHeight
        let guideMargin: CGFloat = 3
        for guideIndent in 1...indent {
            let previousHasGuide = min(previousMeta?.indent ?? 0, 8) >= guideIndent
            let nextHasGuide = min(nextMeta?.indent ?? 0, 8) >= guideIndent
            let topMargin = previousHasGuide ? 0 : guideMargin
            let bottomMargin = nextHasGuide ? 0 : guideMargin
            let levelOffset = CGFloat(indent - guideIndent) * DesktopEditorMetrics.indentWidth
            context.fill(CGRect(
                x: ownBarX - levelOffset,
                y: firstFragment.minY + topMargin,
                width: 1,
                height: max(1, rowHeight - topMargin - bottomMargin)
            ))
        }
    }

    func drawMarker(meta: LineMeta, ordinal: Int, fragment: CGRect, context: CGContext) {
        let rect = markerRect(for: meta, fragment: fragment)
        let chrome = theme.editorChromeColor
        switch meta.marker {
        case .blank:
            return
        case .bullet:
            context.setFillColor(chrome.cgColor)
            context.fillEllipse(in: rect.insetBy(dx: 4.5, dy: 4.5))
        case .numbered:
            let label = "\(ordinal)." as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: chrome
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: rect.maxX - size.width, y: rect.minY + (rect.height - size.height) / 2), withAttributes: attrs)
        case .checkbox:
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 3)
            (meta.done ? chrome : UIColor(theme.buttonBg)).setFill()
            path.fill()
            chrome.setStroke()
            path.lineWidth = 1
            path.stroke()
            if meta.done {
                let check = UIBezierPath()
                check.move(to: CGPoint(x: rect.minX + 3.2, y: rect.minY + 7.2))
                check.addLine(to: CGPoint(x: rect.minX + 5.8, y: rect.minY + 9.7))
                check.addLine(to: CGPoint(x: rect.maxX - 3.0, y: rect.minY + 4.3))
                UIColor(theme.bgApp).setStroke()
                check.lineWidth = 1.8
                check.stroke()
            }
        }
    }

    func drawAnnotationBar(meta: LineMeta, firstFragment: CGRect, visualBounds: CGRect, rowExtraHeight: CGFloat, connectsToPrevious: Bool, connectsToNext: Bool, context: CGContext) {
        let marker = markerRect(for: meta, fragment: firstFragment)
        let x = annotationGuideX(marker: marker)
        let top = connectsToPrevious ? firstFragment.minY : marker.minY
        let bottom = visualBounds.maxY + rowExtraHeight - (connectsToNext ? 0 : 3)
        context.setFillColor(theme.editorChromeColor.cgColor)
        context.fill(CGRect(x: x, y: top, width: 1, height: max(1, bottom - top)))
    }

    func drawAnnotation(_ annotation: String, meta: LineMeta, visualBounds: CGRect, context: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: DesktopEditorMetrics.annotationFontSize, weight: .medium),
            .foregroundColor: theme.editorChromeColor
        ]
        let marker = markerRect(for: meta, fragment: visualBounds)
        let x = annotationGuideX(marker: marker) + DesktopEditorMetrics.annotationTextGap
        let y = visualBounds.maxY - 1
        (annotation as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
    }

    // MARK: - Block rendering
    //
    // Single content per line: a block (image/table) is its own paragraph,
    // laid out as one `blockObjectChar` attachment glyph that reserves the
    // block's box (`KnotQBlockAttachment.attachmentBounds`). `drawChrome` paints
    // the image/table into that box via `blockRect`/`drawBlock` above.

    func drawImageMedia(_ media: MobileItemMedia, in rect: CGRect, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

        let path = UIBezierPath(roundedRect: rect, cornerRadius: 5)
        UIColor(theme.buttonBg).setFill()
        path.fill()
        UIColor(theme.divider).setStroke()
        path.lineWidth = 1
        path.stroke()

        path.addClip()
        if let image = imageForMedia(media), image.size.width > 2, image.size.height > 2 {
            image.draw(in: rect)
        } else {
            drawImageFallback(in: rect)
        }
    }

    func drawImageFallback(in rect: CGRect) {
        let inner = rect.insetBy(dx: 1, dy: 1)
        let size = inner.size
        UIColor(theme.bgModal).setFill()
        UIBezierPath(rect: inner).fill()

        UIColor(theme.accent).withAlphaComponent(0.16).setFill()
        UIBezierPath(ovalIn: CGRect(
            x: inner.maxX - size.width * 0.32,
            y: inner.minY + size.height * 0.12,
            width: size.width * 0.18,
            height: size.width * 0.18
        )).fill()

        UIColor(theme.divider).setFill()
        UIBezierPath(roundedRect: CGRect(
            x: inner.minX + size.width * 0.07,
            y: inner.minY + size.height * 0.16,
            width: size.width * 0.40,
            height: max(6, size.height * 0.07)
        ), cornerRadius: 4).fill()
        UIBezierPath(roundedRect: CGRect(
            x: inner.minX + size.width * 0.07,
            y: inner.minY + size.height * 0.32,
            width: size.width * 0.62,
            height: max(5, size.height * 0.05)
        ), cornerRadius: 4).fill()
        UIBezierPath(roundedRect: CGRect(
            x: inner.minX + size.width * 0.07,
            y: inner.minY + size.height * 0.45,
            width: size.width * 0.50,
            height: max(5, size.height * 0.05)
        ), cornerRadius: 4).fill()
        UIBezierPath(roundedRect: CGRect(
            x: inner.minX + size.width * 0.07,
            y: inner.maxY - size.height * 0.29,
            width: size.width * 0.70,
            height: max(18, size.height * 0.13)
        ), cornerRadius: 6).fill()

        let label = "Image" as NSString
        label.draw(
            at: CGPoint(x: inner.minX + size.width * 0.10, y: inner.maxY - size.height * 0.27),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: max(11, size.height * 0.07), weight: .semibold),
                .foregroundColor: UIColor(theme.textPrimary)
            ]
        )
    }

    func mediaDisplaySize(_ media: MobileItemMedia, maxWidth: CGFloat) -> CGSize {
        let rawWidth = media.width.map(CGFloat.init) ?? DesktopEditorMetrics.imageFallbackWidth
        let rawHeight = media.height.map(CGFloat.init) ?? DesktopEditorMetrics.imageFallbackHeight
        guard rawWidth > 0, rawHeight > 0, maxWidth > 0 else { return .zero }
        let scale = min(maxWidth / rawWidth, DesktopEditorMetrics.imageMaxHeight / rawHeight)
        let clampedScale = min(max(scale, 0.05), 1)
        return CGSize(width: rawWidth * clampedScale, height: rawHeight * clampedScale)
    }

    func imageForMedia(_ media: MobileItemMedia) -> UIImage? {
        guard let path = media.path, !path.isEmpty else { return nil }
        if let cached = imageCache[path] {
            return cached
        }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        imageCache[path] = image
        return image
    }

    func editorInlineBlockMaxWidth(textLeft: CGFloat) -> CGFloat {
        let referenceWidth = measurementWidth ?? bounds.width
        return max(120, referenceWidth - textLeft - textContainerInset.right - 8)
    }

    func tableHeight(_ table: MobileTable, maxWidth: CGFloat) -> CGFloat {
        let columnCount = tableColumnCount(table)
        guard columnCount > 0, maxWidth > 0 else {
            return DesktopEditorMetrics.tableHeaderHeight + DesktopEditorMetrics.tableCellHeight
        }
        let colWidth = maxWidth / CGFloat(columnCount)
        return DesktopEditorMetrics.tableHeaderHeight
            + tableRowHeights(table, columnWidth: colWidth).reduce(0, +)
    }

    func tableRowHeights(_ table: MobileTable, columnWidth: CGFloat) -> [CGFloat] {
        let rowCount = max(1, table.rows.count)
        let textWidth = max(1, columnWidth - 14)
        let attributes = tableTextAttributes(
            weight: .regular,
            color: UIColor(theme.textPrimary),
            lineBreakMode: .byWordWrapping
        )
        return (0..<rowCount).map { row in
            let rowData = row < table.rows.count ? table.rows[row] : nil
            var height = DesktopEditorMetrics.tableCellHeight
            for column in 0..<tableColumnCount(table) {
                let cell = rowData.flatMap { column < $0.cells.count ? $0.cells[column] : nil }
                let text = tableCellAttributedDisplayText(cell, attributes: attributes)
                let rect = text.boundingRect(
                    with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
                height = max(height, ceil(rect.height) + 14)
            }
            return height
        }
    }

    func tableCellDisplayText(_ cell: MobileTableCell?) -> String {
        guard let cell else { return "" }
        let lineText = cell.lines.map(\.text).joined(separator: "\n")
        return lineText.isEmpty ? cell.text : lineText
    }

    func drawTable(_ table: MobileTable, itemID: String?, tableIndex: Int, in rect: CGRect, context: CGContext) {
        let columnCount = tableColumnCount(table)
        guard columnCount > 0, rect.width > 0, rect.height > 0 else { return }

        context.saveGState()
        defer { context.restoreGState() }

        let path = UIBezierPath(roundedRect: rect, cornerRadius: 6)
        UIColor(theme.buttonBg).setFill()
        path.fill()
        UIColor(theme.divider).setStroke()
        path.lineWidth = 1
        path.stroke()
        path.addClip()

        let headerRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: DesktopEditorMetrics.tableHeaderHeight)
        UIColor(theme.bgModal).setFill()
        UIBezierPath(rect: headerRect).fill()

        let colWidth = rect.width / CGFloat(columnCount)
        let headerTextColor = UIColor(theme.isDark ? theme.textSoft : theme.textDim)
        let headerAttributes = tableTextAttributes(weight: .semibold, color: headerTextColor)
        let bodyAttributes = tableTextAttributes(
            weight: .regular,
            color: UIColor(theme.textPrimary),
            lineBreakMode: .byWordWrapping
        )
        let rowHeights = tableRowHeights(table, columnWidth: colWidth)

        for column in 0..<columnCount {
            let cellRect = CGRect(
                x: rect.minX + CGFloat(column) * colWidth,
                y: rect.minY,
                width: colWidth,
                height: DesktopEditorMetrics.tableHeaderHeight
            )
            let title = column < table.columns.count ? table.columns[column].name : "Column \(column + 1)"
            drawTableText(title, in: cellRect, attributes: headerAttributes)
            if let itemID {
                renderedTableCellHits.append(EditorTableCellHitRect(
                    rect: cellRect,
                    hit: EditorTableCellHit(
                        itemID: itemID,
                        tableIndex: tableIndex,
                        row: -1,
                        column: column,
                        text: title,
                        frame: cellRect
                    )
                ))
            }
        }

        var rowTop = rect.minY + DesktopEditorMetrics.tableHeaderHeight
        for row in 0..<max(1, table.rows.count) {
            let rowData = row < table.rows.count ? table.rows[row] : nil
            let rowHeight = rowHeights.indices.contains(row) ? rowHeights[row] : DesktopEditorMetrics.tableCellHeight
            for column in 0..<columnCount {
                let cellRect = CGRect(
                    x: rect.minX + CGFloat(column) * colWidth,
                    y: rowTop,
                    width: colWidth,
                    height: rowHeight
                )
                let cell = rowData.flatMap { column < $0.cells.count ? $0.cells[column] : nil }
                let text = tableCellDisplayText(cell)
                drawTableCellText(cell, in: cellRect, attributes: bodyAttributes)
                if let itemID, row < table.rows.count {
                    renderedTableCellHits.append(EditorTableCellHitRect(
                        rect: cellRect,
                        hit: EditorTableCellHit(
                            itemID: itemID,
                            tableIndex: tableIndex,
                            row: row,
                            column: column,
                            text: text,
                            frame: cellRect
                        )
                    ))
                }
            }
            rowTop += rowHeight
        }

        UIColor(theme.divider).setStroke()
        context.setLineWidth(1)
        for column in 1..<columnCount {
            let x = rect.minX + CGFloat(column) * colWidth
            context.move(to: CGPoint(x: x, y: rect.minY))
            context.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        var gridLineY = rect.minY + DesktopEditorMetrics.tableHeaderHeight
        context.move(to: CGPoint(x: rect.minX, y: gridLineY))
        context.addLine(to: CGPoint(x: rect.maxX, y: gridLineY))
        for rowHeight in rowHeights {
            gridLineY += rowHeight
            context.move(to: CGPoint(x: rect.minX, y: gridLineY))
            context.addLine(to: CGPoint(x: rect.maxX, y: gridLineY))
        }
        context.strokePath()
    }

    func tableTextAttributes(
        weight: UIFont.Weight,
        color: UIColor,
        lineBreakMode: NSLineBreakMode = .byTruncatingTail
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreakMode
        return [
            .font: UIFont.systemFont(ofSize: 13, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
    }

    func drawTableText(_ text: String, in rect: CGRect, attributes: [NSAttributedString.Key: Any]) {
        let inset = rect.insetBy(dx: 7, dy: 7)
        markdownDisplayAttributedString(body: text, attributes: attributes, baseFont: tableBaseFont(attributes))
            .draw(in: inset)
    }

    func drawTableCellText(
        _ cell: MobileTableCell?,
        in rect: CGRect,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let inset = rect.insetBy(dx: 7, dy: 7)
        tableCellAttributedDisplayText(cell, attributes: attributes).draw(in: inset)
    }

    func tableCellAttributedDisplayText(
        _ cell: MobileTableCell?,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        guard let cell else {
            return markdownDisplayAttributedString(body: "", attributes: attributes, baseFont: tableBaseFont(attributes))
        }
        guard !cell.lines.isEmpty else {
            return markdownDisplayAttributedString(body: cell.text, attributes: attributes, baseFont: tableBaseFont(attributes))
        }

        let result = NSMutableAttributedString()
        for (index, line) in cell.lines.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
            let lineText = NSMutableAttributedString(attributedString: markdownDisplayAttributedString(
                body: line.text,
                attributes: attributes,
                baseFont: tableBaseFont(attributes)
            ))
            if line.done, lineText.length > 0 {
                let lineRange = NSRange(location: 0, length: lineText.length)
                lineText.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: lineRange)
                lineText.addAttribute(.strikethroughColor, value: UIColor(theme.textDim), range: lineRange)
            }
            result.append(lineText)
        }
        return result.length > 0
            ? result
            : markdownDisplayAttributedString(body: cell.text, attributes: attributes, baseFont: tableBaseFont(attributes))
    }

    func tableBaseFont(_ attributes: [NSAttributedString.Key: Any]) -> UIFont {
        attributes[.font] as? UIFont ?? UIFont.systemFont(ofSize: 13)
    }

    func tableColumnCount(_ table: MobileTable) -> Int {
        max(1, max(table.columns.count, table.rows.map { $0.cells.count }.max() ?? 0))
    }

    /// Row/column counts for the block-line table owned by `itemID`, used to
    /// clamp Tab / arrow navigation to the grid. `tableIndex` is always 0 — a
    /// block line holds exactly one table.
}
