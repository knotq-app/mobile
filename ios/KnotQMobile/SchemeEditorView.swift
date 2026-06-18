import SwiftUI
import UIKit

// MARK: - Attribute keys

extension NSAttributedString.Key {
    static let knotqLine = NSAttributedString.Key("knotqLine")
    /// Marks markdown marker characters (`*`, `**`, `==`, the leading `#`) so the
    /// layout manager can collapse them on lines that don't contain the caret.
    static let knotqMarker = NSAttributedString.Key("knotqMarker")
}

/// Inline markdown rendering constants shared across the editor.
enum EditorMarkdownStyle {
    /// Translucent gold highlight fill (Obsidian-style), matching the desktop
    /// editor. Kept semi-opaque so it tints the line without recoloring the
    /// text — highlighted text keeps its normal color on light and dark themes.
    static let highlightBackground = UIColor(hex: 0xFFD000).withAlphaComponent(0.4)
}

let editorRichClipboardType = "com.enigmadux.knotq.scheme-items.v1"
let editorRichClipboardFormat = "knotq.mobile.scheme_items.v1"

struct EditorRichClipboardPayload: Codable {
    var format = editorRichClipboardFormat
    var items: [EditorRichClipboardItem]
}

struct EditorRichClipboardItem: Codable {
    var text: String
    var marker: String
    var indent: Int32
    var done: Bool
    var start: String?
    var end: String?
    var notificationOffsetSecs: Int32?
    var repeatRule: String?
    var media: [EditorRichClipboardMedia]

    init(text: String, meta: LineMeta) {
        self.text = text
        marker = meta.marker.rawValue
        indent = Int32(meta.indent)
        done = meta.done
        start = meta.start
        end = meta.end
        notificationOffsetSecs = meta.notificationOffsetSecs
        repeatRule = meta.repeatRule
        media = meta.media.map(EditorRichClipboardMedia.init(media:))
    }

    func lineMeta(timeFormat: String) -> LineMeta {
        let marker = Marker(rawValue: marker) ?? .blank
        return LineMeta(
            marker: marker,
            indent: Int(indent),
            done: done,
            itemID: nil,
            annotation: MobileDate.annotationText(start: start, end: end, timeFormat: timeFormat),
            start: marker == .checkbox ? start : nil,
            end: marker == .checkbox ? end : nil,
            notificationOffsetSecs: marker == .checkbox ? notificationOffsetSecs : nil,
            repeatRule: marker == .checkbox ? repeatRule : nil,
            media: media.map(\.mobileMedia)
        )
    }

}

struct EditorRichClipboardMedia: Codable {
    var kind: String
    var path: String?
    var format: String
    var width: Int32?
    var height: Int32?

    init(media: MobileItemMedia) {
        kind = media.kind
        path = media.path
        format = media.format
        width = media.width
        height = media.height
    }

    var mobileMedia: MobileItemMedia {
        MobileItemMedia(kind: kind, path: path, format: format, width: width, height: height)
    }
}

// MARK: - Metrics

enum DesktopEditorMetrics {
    static let textLeftPad: CGFloat = 35
    static let markerSlot: CGFloat = 21
    static let indentWidth: CGFloat = 15
    static let checkboxSize: CGFloat = 14
    /// Nudges line markers down so they sit on the text's optical center the way
    /// they do on desktop; centering on the bare line fragment leaves them a
    /// hair high.
    static let markerVerticalNudge: CGFloat = 1
    static let textFontSize: CGFloat = 16
    static let textLineHeight: CGFloat = 22
    /// Line height for a block-only paragraph (table/image, no text). Collapses
    /// the empty text band so the block sits in place instead of below a full
    /// blank line, mirroring desktop's ~2px collapse. Kept non-zero so the line
    /// still lays out one fragment, stays tappable, and can host the caret.
    static let blockOnlyLineHeight: CGFloat = 2
    static let headingFontSize: CGFloat = 24
    static let headingLineHeight: CGFloat = 30
    static let annotationFontSize: CGFloat = 11
    static let annotationHeight: CGFloat = 14
    static let annotationBarGap: CGFloat = 8
    static let annotationTextGap: CGFloat = 7
    static let indentGuideXShift: CGFloat = 2
    static let imageTopGap: CGFloat = 8
    static let imageStackGap: CGFloat = 7
    static let imageMaxHeight: CGFloat = 300
    static let imageFallbackWidth: CGFloat = 320
    static let imageFallbackHeight: CGFloat = 180
    static let tableTopGap: CGFloat = 9
    static let tableStackGap: CGFloat = 10
    static let tableHeaderHeight: CGFloat = 30
    static let tableCellHeight: CGFloat = 36
    static let tableMinWidth: CGFloat = 170
    static let titleFontSize: CGFloat = 26
    static let titleLineHeight: CGFloat = 34
    static let titleBlockHeight: CGFloat = 44
}

// MARK: - Per-paragraph metadata

@objc final class LineMeta: NSObject {
    let marker: Marker
    let indent: Int
    let done: Bool
    let itemID: String?
    let annotation: String?
    let start: String?
    let end: String?
    let notificationOffsetSecs: Int32?
    let repeatRule: String?
    let media: [MobileItemMedia]
    let tables: [MobileTable]
    /// Transient editor-only marker for a paragraph that visually hosts the
    /// caret/text immediately before or after a table item. Extraction folds
    /// this paragraph back into the table item instead of saving it separately.
    let tableBoundaryItemID: String?
    let tableBoundarySide: String?
    /// The line's inlines in document order (text/image/table). Drives in-place
    /// block rendering so an image/table sits at its position relative to text
    /// rather than always trailing the paragraph. Empty for lines built outside
    /// the core (clipboard paste, fresh edits) — those fall back to the flat
    /// `media`/`tables` ordering.
    let content: [MobileInline]

    init(
        marker: Marker = .blank,
        indent: Int = 0,
        done: Bool = false,
        itemID: String? = nil,
        annotation: String? = nil,
        start: String? = nil,
        end: String? = nil,
        notificationOffsetSecs: Int32? = nil,
        repeatRule: String? = nil,
        media: [MobileItemMedia] = [],
        tables: [MobileTable] = [],
        tableBoundaryItemID: String? = nil,
        tableBoundarySide: String? = nil,
        content: [MobileInline] = []
    ) {
        self.marker = marker
        self.indent = indent
        self.done = done
        self.itemID = itemID
        self.annotation = annotation
        self.start = start
        self.end = end
        self.notificationOffsetSecs = notificationOffsetSecs
        self.repeatRule = repeatRule
        self.media = media
        self.tables = tables
        self.tableBoundaryItemID = tableBoundaryItemID
        self.tableBoundarySide = tableBoundarySide
        self.content = content
        super.init()
    }

    convenience init(item: MobileItem, timeFormat: String) {
        self.init(
            marker: Marker(rawValue: item.marker) ?? .blank,
            indent: Int(item.indent),
            done: item.done,
            itemID: item.id.isEmpty ? nil : item.id,
            annotation: MobileDate.annotationText(start: item.start, end: item.end, timeFormat: timeFormat),
            start: item.start,
            end: item.end,
            notificationOffsetSecs: item.notificationOffsetSecs,
            repeatRule: item.repeatRule,
            media: item.media,
            tables: item.tables,
            content: item.content
        )
    }

    /// True when the line carries a table/image block but no text — its text
    /// band should collapse so the block sits in place (mirrors desktop). When
    /// `content` is unavailable (paste/edit-built metas), falls back to "has a
    /// block and empty text", which the caller resolves against the line body.
    var hasBlockContent: Bool {
        !media.isEmpty || !tables.isEmpty
    }

    /// Whether the document-ordered content begins with a block (image/table)
    /// rather than text — i.e. there is no leading text band to host the caret
    /// on the same visual row as the block.
    var leadingContentIsBlock: Bool {
        switch content.first {
        case .image, .table: return true
        case .text, .none: return false
        }
    }

    func with(
        marker: Marker? = nil,
        indent: Int? = nil,
        done: Bool? = nil,
        itemID: String?? = nil,
        annotation: String?? = nil,
        start: String?? = nil,
        end: String?? = nil,
        notificationOffsetSecs: Int32?? = nil,
        repeatRule: String?? = nil,
        media: [MobileItemMedia]? = nil,
        tables: [MobileTable]? = nil,
        tableBoundaryItemID: String?? = nil,
        tableBoundarySide: String?? = nil,
        content: [MobileInline]? = nil
    ) -> LineMeta {
        LineMeta(
            marker: marker ?? self.marker,
            indent: indent ?? self.indent,
            done: done ?? self.done,
            itemID: itemID ?? self.itemID,
            annotation: annotation ?? self.annotation,
            start: start ?? self.start,
            end: end ?? self.end,
            notificationOffsetSecs: notificationOffsetSecs ?? self.notificationOffsetSecs,
            repeatRule: repeatRule ?? self.repeatRule,
            media: media ?? self.media,
            tables: tables ?? self.tables,
            tableBoundaryItemID: tableBoundaryItemID ?? self.tableBoundaryItemID,
            tableBoundarySide: tableBoundarySide ?? self.tableBoundarySide,
            content: content ?? self.content
        )
    }

    override func isEqual(_ other: Any?) -> Bool {
        guard let o = other as? LineMeta else { return false }
        return marker == o.marker
            && indent == o.indent
            && done == o.done
            && itemID == o.itemID
            && annotation == o.annotation
            && start == o.start
            && end == o.end
            && notificationOffsetSecs == o.notificationOffsetSecs
            && repeatRule == o.repeatRule
            && media == o.media
            && tables == o.tables
            && tableBoundaryItemID == o.tableBoundaryItemID
            && tableBoundarySide == o.tableBoundarySide
            && content == o.content
    }

    override var hash: Int {
        var h = Hasher()
        h.combine(marker.rawValue)
        h.combine(indent)
        h.combine(done)
        h.combine(itemID)
        h.combine(annotation)
        h.combine(start)
        h.combine(end)
        h.combine(notificationOffsetSecs)
        h.combine(repeatRule)
        h.combine(media)
        h.combine(tables)
        h.combine(tableBoundaryItemID)
        h.combine(tableBoundarySide)
        h.combine(content)
        return h.finalize()
    }

}

// MARK: - Attribute composition

enum EditorAttributes {
    /// `collapseTextBand` shrinks the line fragment to ~2px for a block-only
    /// line (table/image with empty leading text) so the block renders in place
    /// instead of below a full blank text row.
    static func paragraphStyle(meta: LineMeta, collapseTextBand: Bool = false) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let indent = CGFloat(meta.indent) * DesktopEditorMetrics.indentWidth
        let markerOffset = meta.marker == .blank ? CGFloat(0) : DesktopEditorMetrics.markerSlot
        style.firstLineHeadIndent = indent + markerOffset
        style.headIndent = indent
        if collapseTextBand {
            // Pin both bounds so the empty body lays out a single minimal-height
            // fragment; the block then sits at the paragraph's top.
            style.minimumLineHeight = DesktopEditorMetrics.blockOnlyLineHeight
            style.maximumLineHeight = DesktopEditorMetrics.blockOnlyLineHeight
        } else {
            style.minimumLineHeight = DesktopEditorMetrics.textLineHeight
        }
        style.paragraphSpacing = 0
        return style
    }

    static func bodyAttributes(meta: LineMeta, theme: KnotQTheme, collapseTextBand: Bool = false) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: DesktopEditorMetrics.textFontSize),
            .foregroundColor: UIColor(theme.textPrimary),
            .paragraphStyle: paragraphStyle(meta: meta, collapseTextBand: collapseTextBand),
            .knotqLine: meta
        ]
        if meta.done {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attrs[.foregroundColor] = UIColor(theme.textMuted)
        }
        return attrs
    }
}

/// Whether a paragraph's text band should collapse to ~2px: it carries a block
/// (table/image) that leads its content and has no body text to sit beside.
func shouldCollapseTextBand(body: String, meta: LineMeta) -> Bool {
    guard body.isEmpty, meta.hasBlockContent else { return false }
    // Prefer the precise document-ordered answer when content is available;
    // otherwise (paste/edit-built metas) any block on an empty line collapses.
    return meta.content.isEmpty ? true : meta.leadingContentIsBlock
}

// MARK: - Editor invariants
//
// The editor maintains three invariants over its text storage so every other
// operation can ignore edge cases:
//
//   I1. Storage is non-empty and the last character is "\n".
//       → there is always at least one paragraph and one line of meta.
//   I2. Every character (including the trailing "\n") carries a uniform
//       .knotqLine attribute over its paragraph.
//       → meta(of:in:) is total and unambiguous.
//   I3. The caret is clamped to [0, length - 1] (never past the trailing "\n").
//       → "typing on the last line" inserts onto that line, not a phantom line.
//
// The helpers below are the only sanctioned read/write API for meta + styling.
// Editing operations call `setLineMeta` after any mutation that changes meta.

func buildAttributedString(items: [MobileItem], theme: KnotQTheme, timeFormat: String) -> NSAttributedString {
    let result = NSMutableAttributedString()
    if items.isEmpty {
        // Invariant I1: storage is never empty; seed a single blank line.
        let attrs = EditorAttributes.bodyAttributes(meta: LineMeta(), theme: theme)
        result.append(NSAttributedString(string: "\n", attributes: attrs))
        return result
    }
    for item in items {
        let meta = LineMeta(item: item, timeFormat: timeFormat)
        if let split = splitTrailingTextAfterLeadingBlock(item: item, meta: meta) {
            appendEditorParagraph(body: "", meta: split.tableMeta, theme: theme, to: result)
            appendEditorParagraph(body: split.trailingText, meta: split.boundaryMeta, theme: theme, to: result)
        } else {
            appendEditorParagraph(body: item.text, meta: meta, theme: theme, to: result)
        }
    }
    return result
}

private func appendEditorParagraph(body: String, meta: LineMeta, theme: KnotQTheme, to result: NSMutableAttributedString) {
    let collapse = shouldCollapseTextBand(body: body, meta: meta)
    let attrs = EditorAttributes.bodyAttributes(meta: meta, theme: theme, collapseTextBand: collapse)
    let bodyLocation = result.length
    result.append(NSAttributedString(string: body, attributes: attrs))
    let bodyRange = NSRange(location: bodyLocation, length: (body as NSString).length)
    result.append(NSAttributedString(string: "\n", attributes: attrs))
    // Heading / *bold* / _italic_ styling lives here too — not just in
    // setLineMeta — so markdown renders correctly on the very first load
    // instead of staying plain until the first edit.
    applyInlineMarkdownStyling(body: body, bodyRange: bodyRange, in: result)
}

private func splitTrailingTextAfterLeadingBlock(item: MobileItem, meta: LineMeta) -> (tableMeta: LineMeta, boundaryMeta: LineMeta, trailingText: String)? {
    guard !item.content.isEmpty, let itemID = meta.itemID else { return nil }
    var blockContent: [MobileInline] = []
    var trailingText = ""
    var sawBlock = false

    for inline in item.content {
        switch inline {
        case let .text(text):
            if !sawBlock {
                return nil
            }
            trailingText += text
        case .image, .table:
            if !trailingText.isEmpty {
                return nil
            }
            sawBlock = true
            blockContent.append(inline)
        }
    }

    guard sawBlock, !trailingText.isEmpty else { return nil }
    let tableMeta = meta.with(
        media: mediaInlines(from: blockContent),
        tables: tableInlines(from: blockContent),
        content: blockContent
    )
    let boundaryMeta = LineMeta(
        marker: .blank,
        indent: meta.indent,
        tableBoundaryItemID: itemID,
        tableBoundarySide: "after"
    )
    return (tableMeta, boundaryMeta, trailingText)
}

/// Ensures invariants I1 and I2 hold. Inserts a trailing "\n" with the previous
/// paragraph's meta if missing; initializes empty storage with a single "\n".
@discardableResult
func ensureWellFormed(_ storage: NSTextStorage, theme: KnotQTheme) -> Bool {
    let ns = storage.string as NSString
    if ns.length == 0 {
        let attrs = EditorAttributes.bodyAttributes(meta: LineMeta(), theme: theme)
        storage.replaceCharacters(
            in: NSRange(location: 0, length: 0),
            with: NSAttributedString(string: "\n", attributes: attrs)
        )
        return true
    }
    if ns.character(at: ns.length - 1) != 10 {
        let m = lineMeta(at: ns.length - 1, in: storage)
        let attrs = EditorAttributes.bodyAttributes(meta: m, theme: theme)
        storage.replaceCharacters(
            in: NSRange(location: ns.length, length: 0),
            with: NSAttributedString(string: "\n", attributes: attrs)
        )
        return true
    }
    return false
}

/// Reads the .knotqLine attribute at `location`, with sensible fallbacks. Total.
func lineMeta(at location: Int, in storage: NSAttributedString) -> LineMeta {
    guard storage.length > 0 else { return LineMeta() }
    let probe = min(max(0, location), storage.length - 1)
    return (storage.attribute(.knotqLine, at: probe, effectiveRange: nil) as? LineMeta) ?? LineMeta()
}

/// Reads the meta of the paragraph containing `location`. With I1+I2, always
/// returns the well-defined meta of that paragraph.
func lineMeta(forParagraphAt location: Int, in storage: NSAttributedString) -> LineMeta {
    let para = editableParagraphRange(in: storage.string as NSString, at: location)
    return lineMeta(at: para.location, in: storage)
}

/// Reads a paragraph's meta by preferring its trailing "\n". Inline text
/// replacement — autocorrect, predictive insert, double-space-period — rewrites
/// a span inside the line body and can drop `.knotqLine` from the edited run,
/// but it never touches the paragraph's newline. Probing the newline first
/// keeps the line's marker/indent intact across those corrections.
func paragraphMeta(of fullRange: NSRange, in storage: NSAttributedString) -> LineMeta {
    if fullRange.length > 0 {
        let ns = storage.string as NSString
        let last = NSMaxRange(fullRange) - 1
        if last >= 0, last < ns.length, ns.character(at: last) == 10,
           let meta = storage.attribute(.knotqLine, at: last, effectiveRange: nil) as? LineMeta {
            return meta
        }
    }
    return lineMeta(at: fullRange.location, in: storage)
}

/// Returns the body text of `paragraphRange` (without trailing newline).
func bodyText(paragraphRange: NSRange, in storage: NSAttributedString) -> String {
    let ns = storage.string as NSString
    guard let safeRange = nonEmptyTextRange(paragraphRange, length: ns.length) else { return "" }
    let bodyLen = safeRange.length > 0 && ns.character(at: NSMaxRange(safeRange) - 1) == 10
        ? safeRange.length - 1
        : safeRange.length
    guard bodyLen > 0 else { return "" }
    return ns.substring(with: NSRange(location: safeRange.location, length: bodyLen))
}

/// Sets `meta` uniformly across `paragraphRange` (body + trailing newline) and
/// applies all derived styling (font, color, paragraph style, strikethrough,
/// heading, emphasis). The single sanctioned way to change meta on a line.
func setLineMeta(
    _ meta: LineMeta,
    onParagraph paragraphRange: NSRange,
    in storage: NSTextStorage,
    theme: KnotQTheme
) {
    guard let safeRange = nonEmptyTextRange(paragraphRange, length: storage.length) else { return }
    let body = bodyText(paragraphRange: safeRange, in: storage)
    let collapse = shouldCollapseTextBand(body: body, meta: meta)
    let attrs = EditorAttributes.bodyAttributes(meta: meta, theme: theme, collapseTextBand: collapse)
    storage.removeAttribute(.font, range: safeRange)
    storage.removeAttribute(.foregroundColor, range: safeRange)
    storage.removeAttribute(.backgroundColor, range: safeRange)
    storage.removeAttribute(.knotqMarker, range: safeRange)
    storage.removeAttribute(.paragraphStyle, range: safeRange)
    storage.removeAttribute(.strikethroughStyle, range: safeRange)
    storage.removeAttribute(.strikethroughColor, range: safeRange)
    storage.addAttributes(attrs, range: safeRange)
    let bodyRange = NSRange(
        location: safeRange.location,
        length: (body as NSString).length
    )
    applyInlineMarkdownStyling(body: body, bodyRange: bodyRange, in: storage)
}

/// Applies heading enlargement or `**…**`/`*…*`/`==…==` emphasis over a paragraph
/// body. Shared by `setLineMeta` and `buildAttributedString` so styling is
/// identical whether a line is edited or freshly loaded. Marker characters are
/// tagged `.knotqMarker` so the layout manager can collapse them off the caret.
func applyInlineMarkdownStyling(
    body: String,
    bodyRange: NSRange,
    in storage: NSMutableAttributedString,
    enlargeHeadings: Bool = true
) {
    guard bodyRange.length > 0 else { return }
    if isMarkdownHeading(body) {
        // The compact daily preview keeps headings at body size (bold) so a
        // larger font doesn't overflow its fixed row height.
        let headingSize = enlargeHeadings
            ? DesktopEditorMetrics.headingFontSize
            : DesktopEditorMetrics.textFontSize
        storage.addAttribute(
            .font,
            value: UIFont.systemFont(ofSize: headingSize, weight: .bold),
            range: bodyRange
        )
        if let markerLen = headingMarkerLength(body), markerLen > 0 {
            storage.addAttribute(
                .knotqMarker,
                value: true,
                range: NSRange(location: bodyRange.location, length: min(markerLen, bodyRange.length))
            )
        }
    } else {
        applyEmphasis(body: body, lineLocation: bodyRange.location, storage: storage)
    }
}

/// UTF-16 length of a heading's leading `#`/`## ` marker (including one trailing
/// space), or nil when `body` is not a heading.
private func headingMarkerLength(_ body: String) -> Int? {
    let ns = body as NSString
    let hash = UInt16(UInt8(ascii: "#"))
    var i = 0
    func isWhitespace(_ unit: unichar) -> Bool {
        Unicode.Scalar(unit).map { CharacterSet.whitespaces.contains($0) } ?? false
    }
    while i < ns.length, isWhitespace(ns.character(at: i)) { i += 1 }
    var hashes = 0
    while i < ns.length, ns.character(at: i) == hash { i += 1; hashes += 1 }
    guard hashes > 0 else { return nil }
    if i < ns.length, isWhitespace(ns.character(at: i)) { i += 1 }
    return i
}

private struct InlineStyle {
    var bold = false
    var italic = false
    var highlight = false
}

private enum InlineEmphasis {
    case bold, italic, highlight
    func apply(to style: inout InlineStyle) {
        switch self {
        case .bold: style.bold = true
        case .italic: style.italic = true
        case .highlight: style.highlight = true
        }
    }
}

/// The markdown delimiter starting at `index`, matched longest-first so `**`
/// wins over `*`. Mirrors the desktop parser: `**`/`__` bold, `*`/`_` italic,
/// `==` highlight.
private func openDelimiter(_ ns: NSString, at index: Int, limit: Int) -> (token: String, emphasis: InlineEmphasis)? {
    let candidates: [(String, InlineEmphasis)] = [
        ("**", .bold), ("__", .bold), ("==", .highlight), ("*", .italic), ("_", .italic),
    ]
    for (token, emphasis) in candidates where matchesToken(ns, token, at: index, limit: limit) {
        return (token, emphasis)
    }
    return nil
}

/// Emphasis pass matching the desktop parser. Delimiters are tagged
/// `.knotqMarker`; wrapped content is styled (and nesting parses recursively).
func applyEmphasis(body: String, lineLocation: Int, storage: NSMutableAttributedString) {
    let ns = body as NSString
    parseInlineEmphasis(
        ns: ns,
        range: NSRange(location: 0, length: ns.length),
        style: InlineStyle(),
        lineLocation: lineLocation,
        storage: storage
    )
}

private func parseInlineEmphasis(
    ns: NSString,
    range: NSRange,
    style: InlineStyle,
    lineLocation: Int,
    storage: NSMutableAttributedString
) {
    let end = NSMaxRange(range)
    var i = range.location
    var plainStart = i

    func flushPlain(upTo: Int) {
        if upTo > plainStart {
            applyInlineStyle(
                style,
                over: NSRange(location: lineLocation + plainStart, length: upTo - plainStart),
                storage: storage
            )
        }
    }

    while i < end {
        if let match = openDelimiter(ns, at: i, limit: end) {
            let tokenLen = (match.token as NSString).length
            let innerStart = i + tokenLen
            let searchLen = end - innerStart
            let close = searchLen > 0
                ? ns.range(of: match.token, options: [], range: NSRange(location: innerStart, length: searchLen))
                : NSRange(location: NSNotFound, length: 0)
            if close.location != NSNotFound {
                flushPlain(upTo: i)
                storage.addAttribute(.knotqMarker, value: true, range: NSRange(location: lineLocation + i, length: tokenLen))
                storage.addAttribute(.knotqMarker, value: true, range: NSRange(location: lineLocation + close.location, length: tokenLen))
                if close.location > innerStart {
                    var inner = style
                    match.emphasis.apply(to: &inner)
                    parseInlineEmphasis(
                        ns: ns,
                        range: NSRange(location: innerStart, length: close.location - innerStart),
                        style: inner,
                        lineLocation: lineLocation,
                        storage: storage
                    )
                }
                i = close.location + tokenLen
                plainStart = i
                continue
            }
        }
        i += 1
    }
    flushPlain(upTo: end)
}

private func matchesToken(_ ns: NSString, _ token: String, at index: Int, limit: Int) -> Bool {
    let t = token as NSString
    guard index + t.length <= limit else { return false }
    return ns.substring(with: NSRange(location: index, length: t.length)) == token
}

private func applyInlineStyle(_ style: InlineStyle, over range: NSRange, storage: NSMutableAttributedString) {
    if style.bold || style.italic {
        var traits: UIFontDescriptor.SymbolicTraits = []
        if style.bold { traits.insert(.traitBold) }
        if style.italic { traits.insert(.traitItalic) }
        let base = UIFont.systemFont(ofSize: DesktopEditorMetrics.textFontSize)
        let font = base.fontDescriptor.withSymbolicTraits(traits)
            .map { UIFont(descriptor: $0, size: DesktopEditorMetrics.textFontSize) } ?? base
        storage.addAttribute(.font, value: font, range: range)
    }
    if style.highlight {
        // Only the translucent background is applied; the text keeps its base
        // color (Obsidian-style), so it stays readable on light and dark themes.
        storage.addAttribute(.backgroundColor, value: EditorMarkdownStyle.highlightBackground, range: range)
    }
}

/// Clamps a caret position to [0, length - 1] under invariant I3. With I1 the
/// max caret position is the index immediately before the trailing "\n", i.e.
/// the end of the last visible line.
func clampedCaret(_ location: Int, in storage: NSAttributedString) -> Int {
    guard storage.length > 0 else { return 0 }
    return min(max(0, location), storage.length - 1)
}

func clampedTextRange(_ range: NSRange, length: Int) -> NSRange {
    guard length > 0 else { return NSRange(location: 0, length: 0) }
    guard range.location != NSNotFound else {
        return NSRange(location: length, length: 0)
    }
    let location = min(max(0, range.location), length)
    let rawEnd = range.length > 0 ? range.location + range.length : range.location
    let end = min(max(location, rawEnd), length)
    return NSRange(location: location, length: end - location)
}

func nonEmptyTextRange(_ range: NSRange, length: Int) -> NSRange? {
    let safeRange = clampedTextRange(range, length: length)
    guard safeRange.length > 0, safeRange.location < length else { return nil }
    return safeRange
}

func paragraphRangeCovering(_ range: NSRange, in ns: NSString) -> NSRange {
    guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
    let safeRange = clampedTextRange(range, length: ns.length)
    let startProbe = min(safeRange.location, ns.length - 1)
    let endProbe = min(
        safeRange.length > 0 ? NSMaxRange(safeRange) - 1 : safeRange.location,
        ns.length - 1
    )
    return NSUnionRange(
        ns.paragraphRange(for: NSRange(location: startProbe, length: 0)),
        ns.paragraphRange(for: NSRange(location: endProbe, length: 0))
    )
}

func extractEdits(from storage: NSAttributedString) -> [MobileItemEdit] {
    // With invariant I1, paragraphRanges yields one entry per line including
    // an empty trailing paragraph only when the user typed an extra "\n".
    let ns = storage.string as NSString
    let paragraphs = paragraphRanges(in: ns)
    var edits: [MobileItemEdit] = []
    var index = 0
    while index < paragraphs.count {
        let paragraph = paragraphs[index]
        let meta = lineMeta(at: paragraph.fullRange.location, in: storage)

        if meta.tableBoundarySide == "before",
           let itemID = meta.tableBoundaryItemID,
           index + 1 < paragraphs.count {
            let tableParagraph = paragraphs[index + 1]
            let tableMeta = lineMeta(at: tableParagraph.fullRange.location, in: storage)
            if tableMeta.itemID == itemID, tableMeta.hasBlockContent {
                edits.append(tableEdit(
                    tableParagraph: tableParagraph,
                    tableMeta: tableMeta,
                    beforeBody: paragraphBody(paragraph, in: ns),
                    afterBody: nil,
                    ns: ns
                ))
                index += 2
                continue
            }
        }

        if meta.hasBlockContent,
           index + 1 < paragraphs.count {
            let nextParagraph = paragraphs[index + 1]
            let nextMeta = lineMeta(at: nextParagraph.fullRange.location, in: storage)
            if nextMeta.tableBoundarySide == "after",
               nextMeta.tableBoundaryItemID == meta.itemID {
                edits.append(tableEdit(
                    tableParagraph: paragraph,
                    tableMeta: meta,
                    beforeBody: nil,
                    afterBody: paragraphBody(nextParagraph, in: ns),
                    ns: ns
                ))
                index += 2
                continue
            }
        }

        edits.append(plainEdit(paragraph: paragraph, meta: meta, ns: ns))
        index += 1
    }
    // A single blank-marker, empty-text line means "no items" (matches the
    // pre-invariant semantics for an empty document).
    if edits.count == 1,
       let only = edits.first,
       let paragraph = paragraphs.first {
        let meta = lineMeta(at: paragraph.fullRange.location, in: storage)
        if only.text.isEmpty,
           only.marker == "blank",
           only.indent == 0,
           !only.done,
           only.media.isEmpty,
           meta.tables.isEmpty {
        return []
        }
    }
    return edits
}

private func paragraphBody(_ paragraph: EditorParagraphRange, in ns: NSString) -> String {
    paragraph.lineRange.length > 0 ? ns.substring(with: paragraph.lineRange) : ""
}

private func plainEdit(paragraph: EditorParagraphRange, meta: LineMeta, ns: NSString) -> MobileItemEdit {
    let body = paragraphBody(paragraph, in: ns)
    return MobileItemEdit(
        id: meta.itemID,
        text: body,
        marker: meta.marker.rawValue,
        indent: Int32(meta.indent),
        done: meta.done,
        start: meta.start,
        end: meta.end,
        notificationOffsetSecs: meta.notificationOffsetSecs,
        repeatRule: meta.repeatRule,
        media: meta.media,
        content: editContent(body: body, meta: meta)
    )
}

private func tableEdit(
    tableParagraph: EditorParagraphRange,
    tableMeta: LineMeta,
    beforeBody: String?,
    afterBody: String?,
    ns: NSString
) -> MobileItemEdit {
    let tableBody = paragraphBody(tableParagraph, in: ns)
    let content = tableBoundaryContent(
        tableBody: tableBody,
        tableMeta: tableMeta,
        beforeBody: beforeBody,
        afterBody: afterBody
    )
    return MobileItemEdit(
        id: tableMeta.itemID,
        text: plainText(from: content),
        marker: tableMeta.marker.rawValue,
        indent: Int32(tableMeta.indent),
        done: tableMeta.done,
        start: tableMeta.start,
        end: tableMeta.end,
        notificationOffsetSecs: tableMeta.notificationOffsetSecs,
        repeatRule: tableMeta.repeatRule,
        media: mediaInlines(from: content),
        content: content
    )
}

private func editContent(body: String, meta: LineMeta) -> [MobileInline] {
    guard !meta.content.isEmpty || meta.hasBlockContent else {
        return []
    }
    return contentReplacingText(body, in: meta)
}

private func tableBoundaryContent(
    tableBody: String,
    tableMeta: LineMeta,
    beforeBody: String?,
    afterBody: String?
) -> [MobileInline] {
    var content = contentReplacingText(tableBody, in: tableMeta)
    if let beforeBody, !beforeBody.isEmpty {
        content.insert(.text(text: beforeBody), at: 0)
    }
    if let afterBody, !afterBody.isEmpty {
        content.append(.text(text: afterBody))
    }
    return content
}

private func contentReplacingText(_ body: String, in meta: LineMeta) -> [MobileInline] {
    var source = meta.content
    if source.isEmpty {
        source = meta.media.map { .image(media: $0) } + meta.tables.map { .table(table: $0) }
    }

    var replacedText = false
    var output: [MobileInline] = []
    for inline in source {
        switch inline {
        case .text:
            if !replacedText, !body.isEmpty {
                output.append(.text(text: body))
            }
            replacedText = true
        case .image, .table:
            output.append(inline)
        }
    }
    if !replacedText, !body.isEmpty {
        output.insert(.text(text: body), at: 0)
    }
    return output
}

private func plainText(from content: [MobileInline]) -> String {
    content.reduce(into: "") { result, inline in
        if case let .text(text) = inline {
            result += text
        }
    }
}

private func mediaInlines(from content: [MobileInline]) -> [MobileItemMedia] {
    content.compactMap { inline in
        if case let .image(media) = inline {
            return media
        }
        return nil
    }
}

private func tableInlines(from content: [MobileInline]) -> [MobileTable] {
    content.compactMap { inline in
        if case let .table(table) = inline {
            return table
        }
        return nil
    }
}

/// Convenience overload kept for the chrome-drawing path which still works
/// in lineRange (body-only) coordinates. With invariants I1+I2 this is a thin
/// alias for `lineMeta(at:)`.
func metaForLine(storage: NSAttributedString, lineRange: NSRange) -> LineMeta {
    lineMeta(at: lineRange.location, in: storage)
}

func isMarkdownHeading(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let first = trimmed.first, first == "#" else { return false }
    let hashes = trimmed.prefix { $0 == "#" }.count
    if trimmed.count == hashes { return true }
    let index = trimmed.index(trimmed.startIndex, offsetBy: hashes)
    return trimmed[index].isWhitespace
}

struct EditorParagraphRange {
    let lineRange: NSRange
    let fullRange: NSRange
}

func paragraphRanges(in ns: NSString, intersecting target: NSRange? = nil) -> [EditorParagraphRange] {
    guard ns.length > 0 else { return [] }
    var ranges: [EditorParagraphRange] = []
    var start = 0

    while start < ns.length {
        var end = start
        while end < ns.length && ns.character(at: end) != 10 {
            end += 1
        }

        let hasNewline = end < ns.length
        let lineRange = NSRange(location: start, length: end - start)
        let fullRange = NSRange(location: start, length: end - start + (hasNewline ? 1 : 0))
        if target.map({ rangesOverlapOrTouch(fullRange, $0) }) ?? true {
            ranges.append(EditorParagraphRange(lineRange: lineRange, fullRange: fullRange))
        }

        guard hasNewline else { break }
        start = end + 1
    }

    return ranges
}

func editableParagraphRange(in ns: NSString, at location: Int) -> NSRange {
    guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
    let probe = min(max(0, location), ns.length - 1)
    return ns.paragraphRange(for: NSRange(location: probe, length: 0))
}

func lineRange(from paragraphRange: NSRange, in ns: NSString) -> NSRange {
    let safeRange = clampedTextRange(paragraphRange, length: ns.length)
    var length = safeRange.length
    if length > 0 && ns.character(at: NSMaxRange(safeRange) - 1) == 10 {
        length -= 1
    }
    return NSRange(location: safeRange.location, length: length)
}

func rangesOverlapOrTouch(_ a: NSRange, _ b: NSRange) -> Bool {
    a.location <= NSMaxRange(b) && b.location <= NSMaxRange(a)
}

// MARK: - Outer SwiftUI views

struct SchemeEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var systemScheme
    let schemeID: String

    private var theme: KnotQTheme {
        KnotQTheme.resolve(mode: model.snapshot?.settings.themeMode, systemScheme: systemScheme)
    }

    var body: some View {
        if let scheme = model.scheme(id: schemeID) {
            IntegratedSchemeEditorPane(scheme: scheme, theme: theme, onBack: nil, onAdd: {}, usesNativeNavigation: true, autoFocusOnAppear: true)
        } else {
            EmptyState(title: "Scheme missing", detail: "It may have been archived or deleted.", theme: theme)
        }
    }
}
