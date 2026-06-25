import SwiftUI
import UIKit

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
        appendEditorParagraph(body: item.text, meta: meta, theme: theme, to: result)
    }
    return result
}

private func appendEditorParagraph(body: String, meta: LineMeta, theme: KnotQTheme, to result: NSMutableAttributedString) {
    // Single content per line: a block (image/table) is its own paragraph,
    // rendered as one `blockObjectChar` attachment glyph with no body text.
    if meta.hasBlockContent {
        result.append(makeBlockAttributedParagraph(meta: meta, theme: theme))
        return
    }
    let attrs = EditorAttributes.bodyAttributes(meta: meta, theme: theme)
    let bodyLocation = result.length
    result.append(NSAttributedString(string: body, attributes: attrs))
    let bodyRange = NSRange(location: bodyLocation, length: (body as NSString).length)
    result.append(NSAttributedString(string: "\n", attributes: attrs))
    // Heading / *bold* / _italic_ styling lives here too — not just in
    // setLineMeta — so markdown renders correctly on the very first load
    // instead of staying plain until the first edit.
    applyInlineMarkdownStyling(body: body, bodyRange: bodyRange, in: result)
}

/// A block paragraph: a single `blockObjectChar` carrying a `KnotQBlockAttachment`
/// (which reserves the block's layout box) plus the line meta, followed by the
/// paragraph's trailing "\n". The attachment's `owner` is wired up by the text
/// view after the storage is installed so it can size itself against the live
/// container width.
func makeBlockAttributedParagraph(meta: LineMeta, theme: KnotQTheme) -> NSAttributedString {
    let attrs = EditorAttributes.bodyAttributes(meta: meta, theme: theme)
    let result = NSMutableAttributedString()
    let attachment = KnotQBlockAttachment(block: meta.blockInline ?? .text(text: ""), indent: meta.indent)
    let glyph = NSMutableAttributedString(attachment: attachment)
    glyph.addAttributes(attrs, range: NSRange(location: 0, length: glyph.length))
    result.append(glyph)
    result.append(NSAttributedString(string: "\n", attributes: attrs))
    return result
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
    let attrs = EditorAttributes.bodyAttributes(meta: meta, theme: theme)
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

/// Re-applies theme-derived attributes to the existing editor storage without
/// replacing the document text. Used when iOS appearance changes so dirty edits
/// keep their content while foreground colors move to the new theme.
func restyleEditorStorage(_ storage: NSTextStorage, theme: KnotQTheme) {
    guard storage.length > 0 else {
        _ = ensureWellFormed(storage, theme: theme)
        return
    }

    let ns = storage.string as NSString
    let paragraphs = paragraphRanges(in: ns)
    for paragraph in paragraphs {
        let meta = paragraphMeta(of: paragraph.fullRange, in: storage)
        setLineMeta(meta, onParagraph: paragraph.fullRange, in: storage, theme: theme)
    }
    _ = ensureWellFormed(storage, theme: theme)
}

/// Applies heading enlargement or `**...**`/`*...*`/`==...==`/`~~...~~` emphasis over a paragraph
/// body. Shared by `setLineMeta` and `buildAttributedString` so styling is
/// identical whether a line is edited or freshly loaded. Marker characters are
/// tagged `.knotqMarker` so the layout manager can collapse them off the caret.
func applyInlineMarkdownStyling(
    body: String,
    bodyRange: NSRange,
    in storage: NSMutableAttributedString,
    enlargeHeadings: Bool = true,
    baseFont: UIFont = UIFont.systemFont(ofSize: DesktopEditorMetrics.textFontSize)
) {
    guard bodyRange.length > 0 else { return }
    if isMarkdownHeading(body) {
        // The compact daily preview keeps headings at body size (bold) so a
        // larger font doesn't overflow its fixed row height.
        let headingFont = enlargeHeadings
            ? UIFont.systemFont(ofSize: DesktopEditorMetrics.headingFontSize, weight: .bold)
            : styledInlineFont(baseFont: baseFont, bold: true, italic: false)
        storage.addAttribute(
            .font,
            value: headingFont,
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
        applyEmphasis(body: body, lineLocation: bodyRange.location, storage: storage, baseFont: baseFont)
    }
}

func markdownDisplayAttributedString(
    body: String,
    attributes: [NSAttributedString.Key: Any],
    enlargeHeadings: Bool = false,
    removeMarkers: Bool = true,
    baseFont: UIFont? = nil
) -> NSAttributedString {
    let displayText = body.isEmpty ? " " : body
    let storage = NSMutableAttributedString(string: displayText, attributes: attributes)
    let effectiveBaseFont = baseFont
        ?? attributes[.font] as? UIFont
        ?? UIFont.systemFont(ofSize: DesktopEditorMetrics.textFontSize)
    let ns = displayText as NSString
    for paragraph in paragraphRanges(in: ns) where paragraph.lineRange.length > 0 {
        let line = ns.substring(with: paragraph.lineRange)
        applyInlineMarkdownStyling(
            body: line,
            bodyRange: paragraph.lineRange,
            in: storage,
            enlargeHeadings: enlargeHeadings,
            baseFont: effectiveBaseFont
        )
    }
    if removeMarkers {
        removeMarkdownMarkerCharacters(from: storage)
    }
    return storage
}

private func removeMarkdownMarkerCharacters(from storage: NSMutableAttributedString) {
    guard storage.length > 0 else { return }
    var ranges: [NSRange] = []
    storage.enumerateAttribute(.knotqMarker, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
        if value != nil { ranges.append(range) }
    }
    for range in ranges.reversed() {
        storage.deleteCharacters(in: range)
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
    var strikethrough = false
}

private enum InlineEmphasis {
    case bold, italic, highlight, strikethrough
    func apply(to style: inout InlineStyle) {
        switch self {
        case .bold: style.bold = true
        case .italic: style.italic = true
        case .highlight: style.highlight = true
        case .strikethrough: style.strikethrough = true
        }
    }
}

/// The markdown delimiter starting at `index`, matched longest-first so `**`
/// wins over `*`. Mirrors the desktop parser: `**`/`__` bold, `*`/`_` italic,
/// `==` highlight, `~~` strikethrough.
private func openDelimiter(_ ns: NSString, at index: Int, limit: Int) -> (token: String, emphasis: InlineEmphasis)? {
    let candidates: [(String, InlineEmphasis)] = [
        ("**", .bold), ("__", .bold), ("==", .highlight), ("~~", .strikethrough), ("*", .italic), ("_", .italic),
    ]
    for (token, emphasis) in candidates where matchesToken(ns, token, at: index, limit: limit) {
        return (token, emphasis)
    }
    return nil
}

/// Emphasis pass matching the desktop parser. Delimiters are tagged
/// `.knotqMarker`; wrapped content is styled (and nesting parses recursively).
func applyEmphasis(
    body: String,
    lineLocation: Int,
    storage: NSMutableAttributedString,
    baseFont: UIFont = UIFont.systemFont(ofSize: DesktopEditorMetrics.textFontSize)
) {
    let ns = body as NSString
    parseInlineEmphasis(
        ns: ns,
        range: NSRange(location: 0, length: ns.length),
        style: InlineStyle(),
        lineLocation: lineLocation,
        storage: storage,
        baseFont: baseFont
    )
}

private func parseInlineEmphasis(
    ns: NSString,
    range: NSRange,
    style: InlineStyle,
    lineLocation: Int,
    storage: NSMutableAttributedString,
    baseFont: UIFont
) {
    let end = NSMaxRange(range)
    var i = range.location
    var plainStart = i

    func flushPlain(upTo: Int) {
        if upTo > plainStart {
            applyInlineStyle(
                style,
                over: NSRange(location: lineLocation + plainStart, length: upTo - plainStart),
                storage: storage,
                baseFont: baseFont
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
                        storage: storage,
                        baseFont: baseFont
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

private func applyInlineStyle(
    _ style: InlineStyle,
    over range: NSRange,
    storage: NSMutableAttributedString,
    baseFont: UIFont
) {
    guard range.length > 0 else { return }
    if style.bold || style.italic {
        storage.addAttribute(
            .font,
            value: styledInlineFont(baseFont: baseFont, bold: style.bold, italic: style.italic),
            range: range
        )
    }
    if style.highlight {
        // Only the translucent background is applied; the text keeps its base
        // color (Obsidian-style), so it stays readable on light and dark themes.
        storage.addAttribute(.backgroundColor, value: EditorMarkdownStyle.highlightBackground, range: range)
    }
    if style.strikethrough {
        storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        if let color = storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor {
            storage.addAttribute(.strikethroughColor, value: color, range: range)
        }
    }
}

private func styledInlineFont(baseFont: UIFont, bold: Bool, italic: Bool) -> UIFont {
    var traits = baseFont.fontDescriptor.symbolicTraits
    if bold { traits.insert(.traitBold) }
    if italic { traits.insert(.traitItalic) }
    guard let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits) else {
        return baseFont
    }
    return UIFont(descriptor: descriptor, size: baseFont.pointSize)
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
    // Single content per line: each paragraph is exactly one item — a text line
    // (its body) or a block line (one `blockObjectChar` carrying an image/table).
    let ns = storage.string as NSString
    let paragraphs = paragraphRanges(in: ns)
    let edits: [MobileItemEdit] = paragraphs.map { paragraph in
        plainEdit(paragraph: paragraph, meta: lineMeta(at: paragraph.fullRange.location, in: storage), ns: ns)
    }
    // A single blank-marker, empty-text line means "no items" (matches the
    // pre-invariant semantics for an empty document).
    if edits.count == 1, let only = edits.first {
        if only.text.isEmpty,
           only.marker == "blank",
           only.indent == 0,
           !only.done,
           only.media.isEmpty,
           only.content.isEmpty {
            return []
        }
    }
    return edits
}

private func paragraphBody(_ paragraph: EditorParagraphRange, in ns: NSString) -> String {
    paragraph.lineRange.length > 0 ? ns.substring(with: paragraph.lineRange) : ""
}

private func plainEdit(paragraph: EditorParagraphRange, meta: LineMeta, ns: NSString) -> MobileItemEdit {
    // A block line carries no text — its body is the sentinel glyph — so it is
    // sent as content (image/table) which the core stores block-wins.
    if meta.hasBlockContent {
        let content = blockEditContent(meta)
        return MobileItemEdit(
            id: meta.itemID,
            text: "",
            marker: meta.marker.rawValue,
            indent: Int32(meta.indent),
            done: meta.done,
            start: meta.start,
            end: meta.end,
            notificationOffsetSecs: meta.notificationOffsetSecs,
            repeatRule: meta.repeatRule,
            media: mediaInlines(from: content),
            content: content
        )
    }
    return MobileItemEdit(
        id: meta.itemID,
        text: paragraphBody(paragraph, in: ns),
        marker: meta.marker.rawValue,
        indent: Int32(meta.indent),
        done: meta.done,
        start: meta.start,
        end: meta.end,
        notificationOffsetSecs: meta.notificationOffsetSecs,
        repeatRule: meta.repeatRule,
        media: [],
        content: []
    )
}

/// The single block inline (image/table) a block line carries, as a one-element
/// content list for the core (which collapses to single content anyway).
private func blockEditContent(_ meta: LineMeta) -> [MobileInline] {
    if let block = meta.blockInline {
        return [block]
    }
    return meta.media.map { .image(media: $0) } + meta.tables.map { .table(table: $0) }
}

func mediaInlines(from content: [MobileInline]) -> [MobileItemMedia] {
    content.compactMap { inline in
        if case let .image(media) = inline {
            return media
        }
        return nil
    }
}

func tableInlines(from content: [MobileInline]) -> [MobileTable] {
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

