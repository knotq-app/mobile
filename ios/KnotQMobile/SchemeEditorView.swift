import SwiftUI
import UIKit

// MARK: - Attribute keys

extension NSAttributedString.Key {
    static let knotqLine = NSAttributedString.Key("knotqLine")
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
            annotation: LineMeta.annotationText(start: start, end: end, timeFormat: timeFormat),
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
        media: [MobileItemMedia] = []
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
        super.init()
    }

    convenience init(item: MobileItem, timeFormat: String) {
        self.init(
            marker: Marker(rawValue: item.marker) ?? .blank,
            indent: Int(item.indent),
            done: item.done,
            itemID: item.id.isEmpty ? nil : item.id,
            annotation: LineMeta.annotationText(start: item.start, end: item.end, timeFormat: timeFormat),
            start: item.start,
            end: item.end,
            notificationOffsetSecs: item.notificationOffsetSecs,
            repeatRule: item.repeatRule,
            media: item.media
        )
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
        media: [MobileItemMedia]? = nil
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
            media: media ?? self.media
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
        return h.finalize()
    }

    static func annotationText(start: String?, end: String?, timeFormat: String) -> String? {
        let s = MobileDate.formatTime(start, timeFormat: timeFormat)
        let e = MobileDate.formatTime(end, timeFormat: timeFormat)
        switch (s, e) {
        case let (.some(s), .some(e)): return "\(s) → \(e)"
        case let (.some(s), .none): return "At \(s)"
        case let (.none, .some(e)): return "Due \(e)"
        default: return nil
        }
    }
}

// MARK: - Attribute composition

enum EditorAttributes {
    static func paragraphStyle(meta: LineMeta) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let indent = CGFloat(meta.indent) * DesktopEditorMetrics.indentWidth
        let markerOffset = meta.marker == .blank ? CGFloat(0) : DesktopEditorMetrics.markerSlot
        style.firstLineHeadIndent = indent + markerOffset
        style.headIndent = indent
        style.minimumLineHeight = DesktopEditorMetrics.textLineHeight
        style.paragraphSpacing = 0
        return style
    }

    static func bodyAttributes(meta: LineMeta, theme: KnotQTheme) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: DesktopEditorMetrics.textFontSize),
            .foregroundColor: UIColor(theme.textPrimary),
            .paragraphStyle: paragraphStyle(meta: meta),
            .knotqLine: meta
        ]
        if meta.done {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attrs[.foregroundColor] = UIColor(theme.textMuted)
        }
        return attrs
    }
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
        let attrs = EditorAttributes.bodyAttributes(meta: meta, theme: theme)
        let bodyLocation = result.length
        result.append(NSAttributedString(string: item.text, attributes: attrs))
        let bodyRange = NSRange(location: bodyLocation, length: (item.text as NSString).length)
        result.append(NSAttributedString(string: "\n", attributes: attrs))
        // Heading / *bold* / _italic_ styling lives here too — not just in
        // setLineMeta — so markdown renders correctly on the very first load
        // instead of staying plain until the first edit.
        applyInlineMarkdownStyling(body: item.text, bodyRange: bodyRange, in: result)
    }
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
    let bodyLen = paragraphRange.length > 0 && ns.character(at: NSMaxRange(paragraphRange) - 1) == 10
        ? paragraphRange.length - 1
        : paragraphRange.length
    guard bodyLen > 0 else { return "" }
    return ns.substring(with: NSRange(location: paragraphRange.location, length: bodyLen))
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
    guard paragraphRange.length > 0 else { return }
    let attrs = EditorAttributes.bodyAttributes(meta: meta, theme: theme)
    storage.removeAttribute(.font, range: paragraphRange)
    storage.removeAttribute(.foregroundColor, range: paragraphRange)
    storage.removeAttribute(.paragraphStyle, range: paragraphRange)
    storage.removeAttribute(.strikethroughStyle, range: paragraphRange)
    storage.removeAttribute(.strikethroughColor, range: paragraphRange)
    storage.addAttributes(attrs, range: paragraphRange)
    let body = bodyText(paragraphRange: paragraphRange, in: storage)
    let bodyRange = NSRange(
        location: paragraphRange.location,
        length: (body as NSString).length
    )
    applyInlineMarkdownStyling(body: body, bodyRange: bodyRange, in: storage)
}

/// Applies heading enlargement or `*…*`/`_…_` emphasis over a paragraph body.
/// Shared by `setLineMeta` and `buildAttributedString` so styling is identical
/// whether a line is edited or freshly loaded.
func applyInlineMarkdownStyling(body: String, bodyRange: NSRange, in storage: NSMutableAttributedString) {
    guard bodyRange.length > 0 else { return }
    if isMarkdownHeading(body) {
        storage.addAttribute(
            .font,
            value: UIFont.systemFont(ofSize: DesktopEditorMetrics.headingFontSize, weight: .bold),
            range: bodyRange
        )
    } else {
        applyEmphasis(body: body, lineLocation: bodyRange.location, storage: storage)
    }
}

/// Standard emphasis pass: `*…*` → bold, `_…_` → italic.
func applyEmphasis(body: String, lineLocation: Int, storage: NSMutableAttributedString) {
    let ns = body as NSString
    var i = 0
    while i < ns.length {
        let ch = ns.substring(with: NSRange(location: i, length: 1))
        if ch != "*" && ch != "_" { i += 1; continue }
        let searchRange = NSRange(location: i + 1, length: ns.length - i - 1)
        let close = ns.range(of: ch, options: [], range: searchRange)
        if close.location == NSNotFound { i += 1; continue }
        if close.location > i + 1 {
            let range = NSRange(location: lineLocation + i + 1, length: close.location - i - 1)
            let font: UIFont = ch == "*"
                ? .systemFont(ofSize: DesktopEditorMetrics.textFontSize, weight: .bold)
                : .italicSystemFont(ofSize: DesktopEditorMetrics.textFontSize)
            storage.addAttribute(.font, value: font, range: range)
        }
        i = close.location + 1
    }
}

/// Clamps a caret position to [0, length - 1] under invariant I3. With I1 the
/// max caret position is the index immediately before the trailing "\n", i.e.
/// the end of the last visible line.
func clampedCaret(_ location: Int, in storage: NSAttributedString) -> Int {
    guard storage.length > 0 else { return 0 }
    return min(max(0, location), storage.length - 1)
}

func extractEdits(from storage: NSAttributedString) -> [MobileItemEdit] {
    // With invariant I1, paragraphRanges yields one entry per line including
    // an empty trailing paragraph only when the user typed an extra "\n".
    let ns = storage.string as NSString
    let edits: [MobileItemEdit] = paragraphRanges(in: ns).map { paragraph in
        let meta = lineMeta(at: paragraph.fullRange.location, in: storage)
        let body = paragraph.lineRange.length > 0
            ? ns.substring(with: paragraph.lineRange)
            : ""
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
            media: meta.media
        )
    }
    // A single blank-marker, empty-text line means "no items" (matches the
    // pre-invariant semantics for an empty document).
    if edits.count == 1, let only = edits.first,
       only.text.isEmpty, only.marker == "blank", only.indent == 0, !only.done {
        return []
    }
    return edits
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
    var length = paragraphRange.length
    if length > 0 && ns.character(at: NSMaxRange(paragraphRange) - 1) == 10 {
        length -= 1
    }
    return NSRange(location: paragraphRange.location, length: length)
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
