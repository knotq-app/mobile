import XCTest
import UIKit
@testable import KnotQMobile

/// Guards the "Obsidian-style" live preview: markdown markers (`**`, `__`, `*`,
/// `_`, `==`, leading `#`) are revealed only on the caret's line and collapse to
/// zero width everywhere else. The regression these tests exist for: moving the
/// caret between lines updated `revealedRange` and regenerated glyphs, but never
/// invalidated *layout*, so the zero-advancement collapse (a layout-time
/// decision) was computed against stale line fragments and the markers stayed
/// visually "stuck" on whichever line first revealed them.
@MainActor
final class MarkerConcealmentTests: XCTestCase {

    /// `NSLayoutManager.textStorage` is a weak back-reference (the storage owns
    /// the layout manager, not the reverse), so a test that only held the layout
    /// manager would let the storage deallocate out from under it. Pin every
    /// storage here for the lifetime of the test instance. XCTest makes a fresh
    /// instance per test method, so this naturally resets between tests.
    var liveStorages: [NSTextStorage] = []

    // MARK: - Fixtures

    /// A fully wired TextKit 1 stack (storage + layout manager + container) with
    /// markdown markers tagged exactly the way the editor tags them.
    func makeStack(_ text: String) -> (NSTextStorage, EditorLayoutManager, NSTextContainer) {
        let storage = NSTextStorage(
            string: text,
            attributes: [.font: UIFont.systemFont(ofSize: 17)]
        )
        liveStorages.append(storage)
        // Tag each line's markers through the production parser so the tests
        // exercise the real tagging, not a hand-rolled approximation.
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { line, range, _, _ in
            guard let line, !line.isEmpty else { return }
            applyEmphasis(body: line, lineLocation: range.location, storage: storage)
        }
        let layoutManager = EditorLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 2000, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        return (storage, layoutManager, container)
    }

    func renderedWidth(_ layoutManager: EditorLayoutManager, _ container: NSTextContainer) -> CGFloat {
        layoutManager.ensureLayout(for: container)
        let glyphs = layoutManager.glyphRange(for: container)
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: container).width
    }

    /// Width of a single line's glyphs. `boundingRect` over a *multi*-line glyph
    /// range collapses to the container width, so per-line measurement is the
    /// only way to compare one line's collapse against another's.
    func lineWidth(_ layoutManager: EditorLayoutManager, _ container: NSTextContainer, charRange: NSRange) -> CGFloat {
        layoutManager.ensureLayout(for: container)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        return layoutManager.boundingRect(forGlyphRange: glyphRange, in: container).width
    }

    func markerRanges(_ storage: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        storage.enumerateAttribute(.knotqMarker, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { ranges.append(range) }
        }
        return ranges
    }

    func markerCharacterIndexes(_ storage: NSAttributedString) -> [Int] {
        markerRanges(storage).flatMap { range in
            Array(range.location..<NSMaxRange(range))
        }
    }

    func assertMarkerCharacters(
        _ indexes: [Int],
        hidden expectedHidden: Bool,
        in layoutManager: EditorLayoutManager,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for index in indexes {
            XCTAssertEqual(
                layoutManager.isHiddenMarker(at: index),
                expectedHidden,
                "Marker at UTF-16 index \(index)",
                file: file,
                line: line
            )
        }
    }

    func assertColor(
        _ actual: UIColor?,
        equals expected: UIColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            XCTFail("Missing color", file: file, line: line)
            return
        }
        var ar: CGFloat = 0
        var ag: CGFloat = 0
        var ab: CGFloat = 0
        var aa: CGFloat = 0
        var er: CGFloat = 0
        var eg: CGFloat = 0
        var eb: CGFloat = 0
        var ea: CGFloat = 0
        XCTAssertTrue(
            actual.getRed(&ar, green: &ag, blue: &ab, alpha: &aa),
            file: file,
            line: line
        )
        XCTAssertTrue(
            expected.getRed(&er, green: &eg, blue: &eb, alpha: &ea),
            file: file,
            line: line
        )
        XCTAssertEqual(ar, er, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(ag, eg, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(ab, eb, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(aa, ea, accuracy: 0.01, file: file, line: line)
    }

}
