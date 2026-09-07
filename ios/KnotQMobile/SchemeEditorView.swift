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

/// A block (image/table) line carries exactly this single object-replacement
/// character as its body; the block itself is laid out + drawn through a
/// `KnotQBlockAttachment` glyph occupying its own line. Mirrors the desktop
/// editor's `TABLE_OBJECT_CHAR` (`\u{fffc}`) so both platforms model a block
/// line identically: single content per line, the block alone on its line.
let blockObjectChar = "\u{fffc}"
let blockObjectScalar: unichar = 0xFFFC

/// Whether `text` (a paragraph body) contains a block object glyph.
func containsBlockObject(_ text: String) -> Bool {
    text.utf16.contains(blockObjectScalar)
}


extension MobileTable {
    /// A fresh table matching the core's `Table::new(rows, cols)`: `columns`
    /// columns named "Column N", `rows` data rows, each cell a single blank
    /// line. Every id is a freshly minted UUID string so the table round-trips
    /// cleanly through the core (which parses each id) when the editor commits.
    static func freshEmpty(rows: Int = 2, columns: Int = 2) -> MobileTable {
        let columnCount = max(1, columns)
        let columnDefs = (0..<columnCount).map { index in
            MobileTableColumn(id: UUID().uuidString, name: "Column \(index + 1)")
        }
        let rowDefs = (0..<max(1, rows)).map { _ in
            MobileTableRow(
                id: UUID().uuidString,
                cells: (0..<columnCount).map { _ in
                    MobileTableCell(
                        text: "",
                        lines: [MobileCellLine(
                            id: UUID().uuidString,
                            text: "",
                            marker: "blank",
                            done: false,
                            start: nil,
                            end: nil,
                            media: []
                        )]
                    )
                }
            )
        }
        return MobileTable(columns: columnDefs, rows: rowDefs)
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
    static let imageMaxHeight: CGFloat = 300
    static let imageFallbackWidth: CGFloat = 320
    static let imageFallbackHeight: CGFloat = 180
    static let tableHeaderHeight: CGFloat = 30
    static let tableCellHeight: CGFloat = 36
    static let titleFontSize: CGFloat = 26
    static let titleLineHeight: CGFloat = 34
    static let titleBlockHeight: CGFloat = 44
}

// MARK: - Per-paragraph metadata

@objc final class LineMeta: NSObject {
    let marker: Marker
    let markerFamily: String
    let indent: Int
    let done: Bool
    // var (not let) solely for `adoptItemID` below; treat as immutable elsewhere.
    private(set) var itemID: String?
    let annotation: String?
    let start: String?
    let end: String?
    let notificationOffsetSecs: Int32?
    let repeatRule: String?
    let media: [MobileItemMedia]
    let tables: [MobileTable]
    /// The line's single content kind, expressed as inlines so the CRDT/wire
    /// bridge stays uniform: `[.text]`, `[.image]`, or `[.table]`. A block line
    /// (image/table) is drawn through its `KnotQBlockAttachment` glyph; a text
    /// line uses its body. Empty for lines built outside the core (fresh edits)
    /// — those fall back to the flat `media`/`tables`/body.
    let content: [MobileInline]

    init(
        marker: Marker = .blank,
        markerFamily: String = "standard",
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
        content: [MobileInline] = []
    ) {
        self.marker = marker
        self.markerFamily = markerFamily
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
        self.content = content
        super.init()
    }

    convenience init(item: MobileItem, timeFormat: String) {
        self.init(
            marker: Marker(rawValue: item.marker.split(separator: ".", maxSplits: 1).first.map(String.init) ?? item.marker) ?? .blank,
            markerFamily: item.marker.split(separator: ".", maxSplits: 1).dropFirst().first.map(String.init) ?? "standard",
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

    /// Fills in the core-minted item id after a live flush created this line's
    /// item. Mutates IN PLACE — every character of the line shares this one
    /// instance (invariant I2), so adoption needs no text-storage write at all.
    /// That is the point: in TextKit any attribute edit (even a same-value one)
    /// invalidates the paragraph's layout, and this runs on exactly the line
    /// the user is typing on when the flush completes. Only ever fills a nil id.
    func adoptItemID(_ id: String) {
        guard itemID == nil else { return }
        itemID = id
    }

    /// True when the line is a block line (its single content is an image or
    /// table). Such a line's body is exactly one `blockObjectChar`; the block is
    /// laid out + drawn via its `KnotQBlockAttachment` glyph.
    var hasBlockContent: Bool {
        !media.isEmpty || !tables.isEmpty
    }

    /// The single image/table this block line draws, preferring the ordered
    /// `content` (table-over-image when both somehow coexist) and falling back to
    /// the flat `tables`/`media` for metas built outside the core. nil for a
    /// plain text line.
    var blockInline: MobileInline? {
        for inline in content {
            if case .table = inline { return inline }
            if case .image = inline { return inline }
        }
        if let table = tables.first { return .table(table: table) }
        if let media = media.first(where: { $0.kind == "image" }) { return .image(media: media) }
        return nil
    }

    func with(
        marker: Marker? = nil,
        markerFamily: String? = nil,
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
        content: [MobileInline]? = nil
    ) -> LineMeta {
        LineMeta(
            marker: marker ?? self.marker,
            markerFamily: markerFamily ?? self.markerFamily,
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
        h.combine(content)
        return h.finalize()
    }

}

extension LineMeta {
    /// A copy with the `tableIndex`-th table's cell text (or header column name)
    /// set to `text`. Patches both the flat `tables` list and the inline
    /// `content`, so every draw path reflects the edit. Used to update a drawn
    /// table cell *optimistically* on commit, before the model round-trip
    /// reloads the document (which then reconciles to the same value). Returns
    /// nil when the addressed table isn't on this line.
    func patchingTable(tableIndex: Int, row: Int, column: Int, isHeader: Bool, text: String) -> LineMeta? {
        func patched(_ table: MobileTable) -> MobileTable {
            var t = table
            if isHeader {
                if column >= 0, column < t.columns.count {
                    t.columns[column].name = text
                }
                return t
            }
            guard row >= 0, row < t.rows.count, column >= 0, column < t.rows[row].cells.count else {
                return t
            }
            var cell = t.rows[row].cells[column]
            let lineTexts = text.isEmpty ? [""] : text.components(separatedBy: "\n")
            var lines: [MobileCellLine] = []
            for (index, lineText) in lineTexts.enumerated() {
                if index < cell.lines.count {
                    var line = cell.lines[index]
                    line.text = lineText
                    lines.append(line)
                } else {
                    lines.append(MobileCellLine(
                        id: "", text: lineText, marker: "blank",
                        done: false, start: nil, end: nil, media: []
                    ))
                }
            }
            cell.lines = lines
            cell.text = lines.map(\.text).joined(separator: " ")
            t.rows[row].cells[column] = cell
            return t
        }

        var found = false
        var newContent = content
        var seen = 0
        for index in newContent.indices {
            if case let .table(table) = newContent[index] {
                if seen == tableIndex {
                    newContent[index] = .table(table: patched(table))
                    found = true
                }
                seen += 1
            }
        }
        var newTables = tables
        if tableIndex >= 0, tableIndex < newTables.count {
            newTables[tableIndex] = patched(newTables[tableIndex])
            found = true
        }
        return found ? with(tables: newTables, content: newContent) : nil
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
        // A block line's `KnotQBlockAttachment` glyph dictates the fragment
        // height; for text lines this keeps the body row at the standard height.
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
