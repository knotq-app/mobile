import ImageIO
import SwiftUI
import UIKit

extension EditorTextView {
    func drawChrome(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        renderedTableCellHits.removeAll()
        let storage = textStorage
        let ns = storage.string as NSString
        guard glyphsToShow.length > 0, ns.length > 0 else { return }
        // TextKit gives this callback a glyph range, while editor metadata is
        // character/paragraph based. Restrict the metadata scan to the visible
        // character slice; adjacent paragraphs are read directly below for
        // annotation continuity and list numbering.
        let charactersToShow = editorLayoutManager.characterRange(
            forGlyphRange: glyphsToShow,
            actualGlyphRange: nil
        )
        let paragraphs = paragraphRanges(in: ns, intersecting: charactersToShow)
        guard !paragraphs.isEmpty else { return }
        let metas: [LineMeta] = paragraphs.map { lineMeta(at: $0.fullRange.location, in: storage) }
        for index in paragraphs.indices {
            let paragraph = paragraphs[index]
            guard let geometry = paragraphGeometry(for: paragraph, origin: origin) else { continue }
            let glyphRange = geometry.glyphRange
            guard NSIntersectionRange(glyphRange, glyphsToShow).length > 0 else { continue }
            guard let firstFragment = geometry.fragments.first else { continue }
            let visualBounds = geometry.bounds
            let meta = metas[index]
            let previousMeta: LineMeta?
            if index > 0 {
                previousMeta = metas[index - 1]
            } else if paragraph.fullRange.location > 0 {
                previousMeta = lineMeta(
                    forParagraphAt: paragraph.fullRange.location - 1,
                    in: storage
                )
            } else {
                previousMeta = nil
            }
            let nextMeta: LineMeta?
            let nextLocation = NSMaxRange(paragraph.fullRange)
            if index + 1 < metas.count {
                nextMeta = metas[index + 1]
            } else if nextLocation < ns.length {
                nextMeta = lineMeta(forParagraphAt: nextLocation, in: storage)
            } else {
                nextMeta = nil
            }
            let previousAnnotated = previousMeta?.annotation != nil
            let nextAnnotated = nextMeta?.annotation != nil
            // A block line's image/table occupies its line fragment (the
            // attachment glyph sized it), so no extra height is reserved here.
            let annotationHeight = meta.annotation == nil ? CGFloat(0) : DesktopEditorMetrics.annotationHeight
            let rowExtraHeight = annotationHeight
            let ordinal = meta.marker == .numbered
                ? numberedOrdinal(for: paragraph, meta: meta, in: ns, storage: storage)
                : 1
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
    /// same indent ends the run). This walks source paragraphs rather than
    /// assuming the visible draw slice starts at the beginning of the list.
    func numberedOrdinal(
        for paragraph: EditorParagraphRange,
        meta: LineMeta,
        in ns: NSString,
        storage: NSAttributedString
    ) -> Int {
        let currentIndent = meta.indent
        var ordinal = 1
        var cursor = paragraph.fullRange.location
        while cursor > 0 {
            let previousParagraph = ns.paragraphRange(
                for: NSRange(location: cursor - 1, length: 0)
            )
            let previous = paragraphMeta(of: previousParagraph, in: storage)
            if previous.indent > currentIndent {
                cursor = previousParagraph.location
                continue
            }
            if previous.indent < currentIndent || previous.marker != .numbered { break }
            ordinal += 1
            cursor = previousParagraph.location
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
            context.setStrokeColor(chrome.cgColor)
            switch bulletGlyph(family: meta.markerFamily, depth: meta.indent) {
            case .circle: context.setLineWidth(1.5); context.strokeEllipse(in: rect.insetBy(dx: 3.5, dy: 3.5))
            case .square: context.fill(CGRect(x: rect.midX - 2.5, y: rect.midY - 2.5, width: 5, height: 5))
            case .dash: context.fill(CGRect(x: rect.minX + 1, y: rect.midY - 1, width: rect.width - 2, height: 2))
            case .disc: context.fillEllipse(in: rect.insetBy(dx: 4.5, dy: 4.5))
            }
        case .numbered:
            let label = "\(numberLabel(numberGlyph(family: meta.markerFamily, depth: meta.indent), ordinal: ordinal))." as NSString
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

    private enum BulletGlyph { case disc, circle, square, dash }

    /// Mirrors `MarkerFamily::glyph_at` in shared/model/src/item.rs: a family
    /// is a glyph SEQUENCE indexed by indent depth, cycling once nesting runs
    /// deeper than the sequence. `discs`/`rings`/`squares`/`dashes` are
    /// one-entry sequences (same glyph at every depth); "standard" and
    /// "alternating" are the ones that actually vary.
    private func bulletGlyph(family: String, depth: Int) -> BulletGlyph {
        let sequence: [BulletGlyph]
        switch family {
        case "discs": sequence = [.disc]
        case "rings": sequence = [.circle]
        case "squares": sequence = [.square]
        case "dashes": sequence = [.dash]
        case "alternating": sequence = [.disc, .circle]
        default: sequence = [.disc, .circle, .square]
        }
        return sequence[max(0, depth) % sequence.count]
    }

    private enum NumberGlyph { case decimal, lowerAlpha, upperAlpha, lowerRoman, upperRoman }

    /// Mirrors `MarkerFamily::glyph_at` for numbered families: "standard"
    /// cycles 1./a./i., "outline" cycles the classic I./A./1./a./i. sequence,
    /// and the rest are fixed at every depth.
    private func numberGlyph(family: String, depth: Int) -> NumberGlyph {
        let sequence: [NumberGlyph]
        switch family {
        case "decimal": sequence = [.decimal]
        case "alpha": sequence = [.lowerAlpha]
        case "roman": sequence = [.lowerRoman]
        case "outline": sequence = [.upperRoman, .upperAlpha, .decimal, .lowerAlpha, .lowerRoman]
        default: sequence = [.decimal, .lowerAlpha, .lowerRoman]
        }
        return sequence[max(0, depth) % sequence.count]
    }

    private func numberLabel(_ glyph: NumberGlyph, ordinal: Int) -> String {
        switch glyph {
        case .decimal: return "\(ordinal)"
        case .lowerAlpha: return alphabeticOrdinal(ordinal, upper: false)
        case .upperAlpha: return alphabeticOrdinal(ordinal, upper: true)
        case .lowerRoman: return romanOrdinal(ordinal, upper: false)
        case .upperRoman: return romanOrdinal(ordinal, upper: true)
        }
    }

    /// 1 -> a, 26 -> z, 27 -> aa, spreadsheet-column style. Mirrors
    /// `alphabetic_ordinal` in shared/model/src/item.rs exactly.
    private func alphabeticOrdinal(_ ordinal: Int, upper: Bool) -> String {
        guard ordinal > 0 else { return "0" }
        let base: UInt8 = upper ? 65 : 97 // 'A' / 'a'
        var n = ordinal
        var out: [UInt8] = []
        while n > 0 {
            let rem = (n - 1) % 26
            out.append(base + UInt8(rem))
            n = (n - 1) / 26
        }
        return String(decoding: out.reversed(), as: UTF8.self)
    }

    private static let romanNumeralTable: [(Int, String)] = [
        (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
        (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
        (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")
    ]

    /// Mirrors `roman_ordinal` in shared/model/src/item.rs: falls back to the
    /// plain decimal past 3,999 rather than a wall of `m`s.
    private func romanOrdinal(_ ordinal: Int, upper: Bool) -> String {
        guard ordinal > 0, ordinal <= 3_999 else { return "\(ordinal)" }
        var n = ordinal
        var out = ""
        for (value, numeral) in Self.romanNumeralTable {
            while n >= value {
                out += numeral
                n -= value
            }
        }
        return upper ? out.uppercased() : out
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
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let maxPixelSize = max(1, Int(ceil(max(rect.width, rect.height) * scale)))
        if let image = cachedImageForMedia(media, maxPixelSize: maxPixelSize), image.size.width > 2, image.size.height > 2 {
            image.draw(in: rect)
        } else {
            requestImageForMedia(media, maxPixelSize: maxPixelSize)
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

    func imageForMedia(_ media: MobileItemMedia, maxPixelSize: Int? = nil) -> UIImage? {
        guard let path = media.path, !path.isEmpty else { return nil }
        let boundedPixelSize = maxPixelSize.map { max(1, $0) }
        let cacheKey = "\(path)\u{1f}\(boundedPixelSize ?? 0)" as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }
        let image = Self.decodeImage(at: path, maxPixelSize: boundedPixelSize)
        guard let image else { return nil }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        imageCache.setObject(image, forKey: cacheKey, cost: cost)
        return image
    }

    /// Draw-time cache lookup. Unlike `imageForMedia`, this method never
    /// decodes a file and is therefore safe to call from NSLayoutManager's
    /// synchronous background-drawing pass.
    func cachedImageForMedia(_ media: MobileItemMedia, maxPixelSize: Int? = nil) -> UIImage? {
        guard let path = media.path, !path.isEmpty else { return nil }
        let boundedPixelSize = maxPixelSize.map { max(1, $0) }
        let cacheKey = "\(path)\u{1f}\(boundedPixelSize ?? 0)" as NSString
        return imageCache.object(forKey: cacheKey)
    }

    /// Starts a single bounded thumbnail decode for a draw-time cache miss.
    /// The fallback is painted immediately; the editor invalidates its display
    /// after the thumbnail arrives, so a camera-sized image cannot stall the
    /// user's first frame.
    func requestImageForMedia(_ media: MobileItemMedia, maxPixelSize: Int) {
        guard let path = media.path, !path.isEmpty else { return }
        let boundedPixelSize = max(1, maxPixelSize)
        let cacheKey = "\(path)\u{1f}\(boundedPixelSize)"
        guard imageCache.object(forKey: cacheKey as NSString) == nil else { return }

        imageLoadsLock.lock()
        let inserted = imageLoadsInFlight.insert(cacheKey).inserted
        imageLoadsLock.unlock()
        guard inserted else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = Self.decodeImage(at: path, maxPixelSize: boundedPixelSize)
            let cost = image?.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            DispatchQueue.main.async {
                guard let self else { return }
                self.imageLoadsLock.lock()
                self.imageLoadsInFlight.remove(cacheKey)
                self.imageLoadsLock.unlock()
                if let image {
                    self.imageCache.setObject(image, forKey: cacheKey as NSString, cost: cost)
                    self.setNeedsDisplay()
                }
            }
        }
    }

    nonisolated private static func decodeImage(at path: String, maxPixelSize: Int?) -> UIImage? {
        if let maxPixelSize,
           let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(
               source,
               0,
               [
                   kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceCreateThumbnailWithTransform: true,
                   kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
               ] as CFDictionary
           ) {
            return UIImage(cgImage: thumbnail)
        }
        // Keep the old behavior for unsupported/corrupt formats so a
        // thumbnailing failure still gets the same fallback/error path.
        return UIImage(contentsOfFile: path)
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
