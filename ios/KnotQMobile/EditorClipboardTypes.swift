import SwiftUI
import UIKit

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
    var content: [EditorRichClipboardInline]

    enum CodingKeys: String, CodingKey {
        case text
        case marker
        case indent
        case done
        case start
        case end
        case notificationOffsetSecs
        case repeatRule
        case media
        case content
    }

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
        var orderedContent = meta.content
        if orderedContent.isEmpty {
            orderedContent = meta.media.map { .image(media: $0) }
                + meta.tables.map { .table(table: $0) }
        }
        content = orderedContent.map(EditorRichClipboardInline.init(inline:))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        marker = try container.decode(String.self, forKey: .marker)
        indent = try container.decode(Int32.self, forKey: .indent)
        done = try container.decode(Bool.self, forKey: .done)
        start = try container.decodeIfPresent(String.self, forKey: .start)
        end = try container.decodeIfPresent(String.self, forKey: .end)
        notificationOffsetSecs = try container.decodeIfPresent(Int32.self, forKey: .notificationOffsetSecs)
        repeatRule = try container.decodeIfPresent(String.self, forKey: .repeatRule)
        media = try container.decodeIfPresent([EditorRichClipboardMedia].self, forKey: .media) ?? []
        content = try container.decodeIfPresent([EditorRichClipboardInline].self, forKey: .content) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(marker, forKey: .marker)
        try container.encode(indent, forKey: .indent)
        try container.encode(done, forKey: .done)
        try container.encodeIfPresent(start, forKey: .start)
        try container.encodeIfPresent(end, forKey: .end)
        try container.encodeIfPresent(notificationOffsetSecs, forKey: .notificationOffsetSecs)
        try container.encodeIfPresent(repeatRule, forKey: .repeatRule)
        try container.encode(media, forKey: .media)
        try container.encode(content, forKey: .content)
    }

    func lineMeta(timeFormat: String) -> LineMeta {
        let marker = Marker(rawValue: marker) ?? .blank
        let decodedContent = content.compactMap { $0.mobileInline }
        let decodedMedia = mediaInlines(from: decodedContent)
        let decodedTables = tableInlines(from: decodedContent)
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
            media: decodedContent.isEmpty ? media.map(\.mobileMedia) : decodedMedia,
            tables: decodedTables,
            content: decodedContent
        )
    }

}

struct EditorRichClipboardInline: Codable {
    var kind: String
    var text: String?
    var media: EditorRichClipboardMedia?
    var table: EditorRichClipboardTable?

    init(inline: MobileInline) {
        switch inline {
        case let .text(text):
            kind = "text"
            self.text = text
            media = nil
            table = nil
        case let .image(media):
            kind = "image"
            text = nil
            self.media = EditorRichClipboardMedia(media: media)
            table = nil
        case let .table(table):
            kind = "table"
            text = nil
            media = nil
            self.table = EditorRichClipboardTable(table: table)
        }
    }

    var mobileInline: MobileInline? {
        switch kind {
        case "text":
            return .text(text: text ?? "")
        case "image":
            guard let media else { return nil }
            return .image(media: media.mobileMedia)
        case "table":
            guard let table else { return nil }
            return .table(table: table.mobileTable)
        default:
            return nil
        }
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

struct EditorRichClipboardTable: Codable {
    var columns: [EditorRichClipboardTableColumn]
    var rows: [EditorRichClipboardTableRow]

    init(table: MobileTable) {
        columns = table.columns.map(EditorRichClipboardTableColumn.init(column:))
        rows = table.rows.map(EditorRichClipboardTableRow.init(row:))
    }

    var mobileTable: MobileTable {
        MobileTable(columns: columns.map(\.mobileColumn), rows: rows.map(\.mobileRow))
    }
}

struct EditorRichClipboardTableColumn: Codable {
    var id: String
    var name: String

    init(column: MobileTableColumn) {
        id = column.id
        name = column.name
    }

    var mobileColumn: MobileTableColumn {
        MobileTableColumn(id: id, name: name)
    }
}

struct EditorRichClipboardTableRow: Codable {
    var id: String
    var cells: [EditorRichClipboardTableCell]

    init(row: MobileTableRow) {
        id = row.id
        cells = row.cells.map(EditorRichClipboardTableCell.init(cell:))
    }

    var mobileRow: MobileTableRow {
        MobileTableRow(id: id, cells: cells.map(\.mobileCell))
    }
}

struct EditorRichClipboardTableCell: Codable {
    var text: String
    var lines: [EditorRichClipboardCellLine]

    init(cell: MobileTableCell) {
        text = cell.text
        lines = cell.lines.map(EditorRichClipboardCellLine.init(line:))
    }

    var mobileCell: MobileTableCell {
        MobileTableCell(text: text, lines: lines.map(\.mobileLine))
    }
}

struct EditorRichClipboardCellLine: Codable {
    var id: String
    var text: String
    var marker: String
    var done: Bool
    var start: String?
    var end: String?
    var media: [EditorRichClipboardMedia]

    init(line: MobileCellLine) {
        id = line.id
        text = line.text
        marker = line.marker
        done = line.done
        start = line.start
        end = line.end
        media = line.media.map(EditorRichClipboardMedia.init(media:))
    }

    var mobileLine: MobileCellLine {
        MobileCellLine(
            id: id,
            text: text,
            marker: marker,
            done: done,
            start: start,
            end: end,
            media: media.map(\.mobileMedia)
        )
    }
}
