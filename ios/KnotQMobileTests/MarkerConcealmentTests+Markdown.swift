import XCTest
import UIKit
@testable import KnotQMobile

extension MarkerConcealmentTests {
    // MARK: - Tagging (so future delimiter changes keep the markers concealable)

    func testEmphasisTagsEveryDelimiterStyle() {
        XCTAssertEqual(taggedRanges(for: "**b**"), [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
        XCTAssertEqual(taggedRanges(for: "__b__"), [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
        XCTAssertEqual(taggedRanges(for: "==h=="), [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
        XCTAssertEqual(taggedRanges(for: "~~s~~"), [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
        XCTAssertEqual(taggedRanges(for: "*i*"), [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)])
        XCTAssertEqual(taggedRanges(for: "_i_"), [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)])
    }

    func testStrikethroughMarkdownAppliesAttribute() {
        let body = "Keep ~~remove~~"
        let storage = NSTextStorage(
            string: body,
            attributes: [.font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor.label]
        )

        applyInlineMarkdownStyling(
            body: body,
            bodyRange: NSRange(location: 0, length: (body as NSString).length),
            in: storage
        )

        let struckRange = (body as NSString).range(of: "remove")
        XCTAssertEqual(
            storage.attribute(.strikethroughStyle, at: struckRange.location, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
    }

    func testMarkdownDisplayAttributedStringConcealsMarkersAndKeepsCompactFont() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13),
            .foregroundColor: UIColor.label
        ]

        let rendered = markdownDisplayAttributedString(
            body: "**Bold** ==Mark== ~~Gone~~",
            attributes: attributes,
            baseFont: UIFont.systemFont(ofSize: 13)
        )

        XCTAssertEqual(rendered.string, "Bold Mark Gone")
        let ns = rendered.string as NSString
        let boldRange = ns.range(of: "Bold")
        let markRange = ns.range(of: "Mark")
        let goneRange = ns.range(of: "Gone")
        let boldFont = rendered.attribute(.font, at: boldRange.location, effectiveRange: nil) as? UIFont
        XCTAssertEqual(boldFont?.pointSize, 13)
        XCTAssertTrue(boldFont?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false)
        XCTAssertNotNil(rendered.attribute(.backgroundColor, at: markRange.location, effectiveRange: nil))
        XCTAssertEqual(
            rendered.attribute(.strikethroughStyle, at: goneRange.location, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
    }

    func testHeadingMarkerIsTagged() {
        let body = "# Title"
        let storage = NSTextStorage(string: body, attributes: [.font: UIFont.systemFont(ofSize: 17)])
        applyInlineMarkdownStyling(
            body: body,
            bodyRange: NSRange(location: 0, length: (body as NSString).length),
            in: storage
        )
        // The leading "# " (hash + one space) is the marker.
        XCTAssertEqual(markerRanges(storage), [NSRange(location: 0, length: 2)])
    }

    func taggedRanges(for body: String) -> [NSRange] {
        let storage = NSTextStorage(string: body, attributes: [.font: UIFont.systemFont(ofSize: 17)])
        applyEmphasis(body: body, lineLocation: 0, storage: storage)
        return markerRanges(storage)
    }

    func firstEmbeddedTextView(in root: UIView) -> UITextView? {
        for subview in root.subviews {
            if let textView = subview as? UITextView, textView !== root {
                return textView
            }
            if let nested = firstEmbeddedTextView(in: subview) {
                return nested
            }
        }
        return nil
    }

    func makeEditorView() -> (EditorTextView, EditorCoordinator) {
        let view = EditorTextView()
        let coordinator = EditorCoordinator()
        coordinator.view = view
        view.coordinator = coordinator
        return (view, coordinator)
    }

    /// Like `makeEditorView` but wired the way `SchemeTextView.makeUIView` does:
    /// the coordinator is the text-storage delegate (so a native edit runs the
    /// `didProcessEditing` → normalize/isolate pass) and the view has real bounds
    /// (so layout + `drawChrome` run). Used to reproduce edit-time crashes.
    func makeWiredEditorView() -> (EditorTextView, EditorCoordinator) {
        let view = EditorTextView()
        let coordinator = EditorCoordinator()
        coordinator.view = view
        coordinator.theme = .dark
        view.coordinator = coordinator
        view.delegate = coordinator
        view.textStorage.delegate = coordinator
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 700)
        view.textContainer.size = CGSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        return (view, coordinator)
    }

    /// Forces layout + the custom `drawChrome` pass so a render-time crash (stale
    /// table geometry after an edit) surfaces in the test.
    func renderEditor(_ view: EditorTextView) {
        view.layoutManager.ensureLayout(for: view.textContainer)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 700))
        _ = renderer.image { ctx in view.layer.render(in: ctx.cgContext) }
    }

    func tableOnlyItem(indent: Int32) -> MobileItem {
        let line = MobileCellLine(
            id: "cell-line",
            text: "",
            marker: "blank",
            done: false,
            start: nil,
            end: nil,
            media: []
        )
        let table = MobileTable(
            columns: [
                MobileTableColumn(id: "column-1", name: "Column 1")
            ],
            rows: [
                MobileTableRow(
                    id: "row-1",
                    cells: [
                        MobileTableCell(text: "", lines: [line])
                    ]
                )
            ]
        )
        return MobileItem(
            id: "table-item",
            text: "",
            marker: "blank",
            indent: indent,
            kind: "procedure",
            done: false,
            start: nil,
            end: nil,
            notificationOffsetSecs: nil,
            repeatRule: nil,
            media: [],
            tables: [table],
            content: [.table(table: table)]
        )
    }

    func richTableItem(indent: Int32) -> MobileItem {
        func cell(_ id: String, _ text: String) -> MobileTableCell {
            MobileTableCell(
                text: text,
                lines: [MobileCellLine(id: id, text: text, marker: "blank", done: false, start: nil, end: nil, media: [])]
            )
        }
        let table = MobileTable(
            columns: [
                MobileTableColumn(id: "c1", name: "A"),
                MobileTableColumn(id: "c2", name: "B")
            ],
            rows: [
                MobileTableRow(id: "r1", cells: [cell("r1c1", "1a"), cell("r1c2", "1b")]),
                MobileTableRow(id: "r2", cells: [cell("r2c1", "2a"), cell("r2c2", "2b")])
            ]
        )
        return MobileItem(
            id: "rich-table",
            text: "",
            marker: "blank",
            indent: indent,
            kind: "procedure",
            done: false,
            start: nil,
            end: nil,
            notificationOffsetSecs: nil,
            repeatRule: nil,
            media: [],
            tables: [table],
            content: [.table(table: table)]
        )
    }

    func imageOnlyItem(indent: Int32) -> MobileItem {
        let media = testImageMedia()
        return MobileItem(
            id: "image-item",
            text: "",
            marker: "blank",
            indent: indent,
            kind: "procedure",
            done: false,
            start: nil,
            end: nil,
            notificationOffsetSecs: nil,
            repeatRule: nil,
            media: [media],
            tables: [],
            content: [.image(media: media)]
        )
    }

    func testImageMedia() -> MobileItemMedia {
        MobileItemMedia(kind: "image", path: nil, format: "png", width: 320, height: 200)
    }

    func textItem(id: String, text: String, indent: Int32) -> MobileItem {
        MobileItem(
            id: id,
            text: text,
            marker: "blank",
            indent: indent,
            kind: "procedure",
            done: false,
            start: nil,
            end: nil,
            notificationOffsetSecs: nil,
            repeatRule: nil,
            media: [],
            tables: [],
            content: [.text(text: text)]
        )
    }
}
