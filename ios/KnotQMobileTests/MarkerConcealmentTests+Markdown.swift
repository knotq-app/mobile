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

    // MARK: - Code, links, quotes and rules (parity with the desktop editor)

    func testBackticksMarkCodeAndHideThemselves() {
        let body = "run `cargo test` now"
        XCTAssertEqual(displayed(body), "run cargo test now")
        let storage = styled(body)
        let code = (body as NSString).range(of: "cargo test")
        let font = storage.attribute(.font, at: code.location, effectiveRange: nil) as? UIFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) ?? false)
        XCTAssertNotNil(storage.attribute(.backgroundColor, at: code.location, effectiveRange: nil))
        XCTAssertNil(storage.attribute(.backgroundColor, at: 0, effectiveRange: nil))
    }

    func testCodeIsLiteralAndAnEmptyPairIsNotASpan() {
        XCTAssertEqual(displayed("`**not bold**`"), "**not bold**")
        XCTAssertEqual(displayed("`[a](https://b.c)`"), "[a](https://b.c)")
        XCTAssertEqual(displayed("a `` b"), "a `` b")
        XCTAssertEqual(displayed("one ` tick"), "one ` tick")
    }

    func testNamedLinkShowsOnlyItsLabel() {
        let body = "see [the docs](https://example.com/a_b) today"
        XCTAssertEqual(displayed(body), "see the docs today")
        let storage = styled(body)
        let label = (body as NSString).range(of: "the docs")
        XCTAssertEqual(
            storage.attribute(.underlineStyle, at: label.location, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
        XCTAssertNil(storage.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        XCTAssertEqual(displayed("[**bold** label](mailto:a@b.co)"), "bold label")
    }

    func testBracketedProseIsNotALink() {
        for body in ["[x] (later)", "[1](2)", "[](https://a.b)", "[a](file:///etc)", "[a](https://a b)", "[a](https://)"] {
            XCTAssertNil(namedMarkdownLink(body as NSString, at: 0, limit: (body as NSString).length), body)
        }
        XCTAssertEqual(displayed("[1](2)"), "[1](2)")
    }

    func testBareLinkIsUnderlinedAndKeepsItsUnderscores() {
        let body = "at https://example.com/my_file_name."
        // The address is literal: its underscores are not italic markers.
        XCTAssertEqual(displayed(body), body)
        let ns = body as NSString
        let start = ns.range(of: "https").location
        XCTAssertEqual(bareMarkdownLinkEnd(ns, at: start, limit: ns.length), ns.length - 1)
        XCTAssertEqual(
            styled(body).attribute(.underlineStyle, at: start, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
        XCTAssertNil(bareMarkdownLinkEnd("xhttps://a.b" as NSString, at: 1, limit: 12))
        let wiki = "(https://en.wikipedia.org/wiki/Rust_(language))" as NSString
        XCTAssertEqual(bareMarkdownLinkEnd(wiki, at: 1, limit: wiki.length), wiki.length - 1)
    }

    func testQuoteHidesItsMarkerAndSoftensItsText() {
        XCTAssertEqual(markdownQuoteMarkerLength("> said"), 2)
        XCTAssertEqual(markdownQuoteMarkerLength("  > said"), 4)
        XCTAssertEqual(markdownQuoteMarkerLength(">"), 1)
        XCTAssertNil(markdownQuoteMarkerLength(">said"))
        XCTAssertNil(markdownQuoteMarkerLength("a > b"))
        XCTAssertEqual(displayed("> a **b**"), "a b")

        let body = "> said"
        let storage = styled(body)
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? UIColor, UIColor(KnotQTheme.dark.textSoft))
        // A completed line keeps its own colour.
        let done = styled(body, palette: MarkdownPalette(theme: .dark, done: true))
        XCTAssertEqual(done.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? UIColor, UIColor.label)
    }

    func testRuleIsAllMarkerAndOnlyInItsOwnRow() {
        XCTAssertTrue(isMarkdownRule("---"))
        XCTAssertTrue(isMarkdownRule("  ------ "))
        XCTAssertFalse(isMarkdownRule("--"))
        XCTAssertFalse(isMarkdownRule("--- x"))
        XCTAssertFalse(isMarkdownRule("- - -"))
        XCTAssertEqual(markerRanges(styled("---")), [NSRange(location: 0, length: 3)])
        // A table cell has no row of its own: quotes and rules stay as typed.
        XCTAssertEqual(displayed("---", blockForms: false), "---")
        XCTAssertEqual(displayed("> a", blockForms: false), "> a")
    }

    func testRestylingALineClearsItsLinkUnderline() {
        let (view, _) = makeWiredEditorView()
        view.textStorage.setAttributedString(NSAttributedString(
            string: "https://example.com\n",
            attributes: EditorAttributes.bodyAttributes(meta: LineMeta(), theme: .dark)
        ))
        let paragraph = NSRange(location: 0, length: view.textStorage.length)
        setLineMeta(LineMeta(), onParagraph: paragraph, in: view.textStorage, theme: .dark)
        XCTAssertNotNil(view.textStorage.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        view.textStorage.replaceCharacters(in: NSRange(location: 0, length: 8), with: "")
        setLineMeta(LineMeta(), onParagraph: NSRange(location: 0, length: view.textStorage.length), in: view.textStorage, theme: .dark)
        XCTAssertNil(view.textStorage.attribute(.underlineStyle, at: 0, effectiveRange: nil))
    }

    func testEditorDrawsQuotesAndRulesWithoutCrashing() {
        let (view, _) = makeWiredEditorView()
        let attrs = EditorAttributes.bodyAttributes(meta: LineMeta(), theme: .dark)
        view.textStorage.setAttributedString(NSAttributedString(string: "> quoted\n---\n>\nplain `code`\n", attributes: attrs))
        for paragraph in paragraphRanges(in: view.textStorage.string as NSString) {
            setLineMeta(LineMeta(), onParagraph: paragraph.fullRange, in: view.textStorage, theme: .dark)
        }
        renderEditor(view)
    }

    func testSearchPreviewDropsMarkdownButKeepsNames() {
        XCTAssertEqual(searchPreviewText("**sharper labels**\n### Thesis\n__concrete, small__"), "sharper labels Thesis concrete, small")
        XCTAssertEqual(searchPreviewText("run `cargo test`"), "run cargo test")
        XCTAssertEqual(searchPreviewText("see [the docs](https://example.com/a_b) today"), "see the docs today")
        XCTAssertEqual(searchPreviewText("> said once\nabove\n---\nbelow"), "said once above below")
        XCTAssertEqual(searchPreviewText("[1](2) my_file_name"), "[1](2) my_file_name")
        XCTAssertEqual(searchPreviewText("Calendar"), "Calendar")
    }

    func styled(_ body: String, palette: MarkdownPalette = MarkdownPalette(theme: .dark)) -> NSTextStorage {
        let storage = NSTextStorage(
            string: body,
            attributes: [.font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor.label]
        )
        applyInlineMarkdownStyling(
            body: body,
            bodyRange: NSRange(location: 0, length: (body as NSString).length),
            in: storage,
            palette: palette
        )
        return storage
    }

    /// What a line reads as off the caret, with its markers collapsed.
    func displayed(_ body: String, blockForms: Bool = true) -> String {
        markdownDisplayAttributedString(
            body: body,
            attributes: [.font: UIFont.systemFont(ofSize: 17)],
            blockForms: blockForms
        ).string
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
