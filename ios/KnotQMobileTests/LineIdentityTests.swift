import XCTest
import UIKit
@testable import KnotQMobile

/// Every line the editor hands to a flush must carry an `itemID`.
///
/// The editor flushes the *whole* item list every ~0.6 s while you type, and
/// the core mints an item for any line that arrives without an id. Ids come
/// back through `adoptItemIDs`, which gives up whenever the paragraph count no
/// longer matches the returned item count — which is exactly what typing during
/// an in-flight write does. So a line that is created (or rewritten) without an
/// id is not merely unidentified for a moment: every flush presents it as a new
/// draft and the core mints *another* item for it.
///
/// That is invisible locally, because `replace_scheme_items` rebuilds the plain
/// list positionally. It is not invisible to the document: an ordinary scheme
/// write deliberately never tombstones the items the list dropped (doing so is
/// how lines nobody deleted once got lost), so every superseded id stays live
/// in the CRDT and the next materialization brings them all back as real rows.
/// One typed line, five identical rows.
///
/// These tests are written against the invariant rather than against the three
/// handlers that broke it, because the cost of a new hole is high and the cost
/// of noticing one here is a few milliseconds.
@MainActor
final class LineIdentityTests: XCTestCase {

    /// Kept alive for the duration of a test: the coordinator holds its view
    /// weakly, and a deallocated view turns every handler into a silent no-op.
    /// XCTest builds a fresh instance per test, so this is released with it;
    /// it needs no teardown, and an override of the nonisolated `tearDown`
    /// could not touch it from a `@MainActor` class anyway.
    private var liveViews: [EditorTextView] = []

    /// An editor holding `lines`, each already carrying its own id, the way a
    /// scheme loaded from the core arrives. Every line must be non-empty:
    /// `setLineMeta` declines an empty paragraph, so a blank line here would
    /// silently have no meta at all and the test would be measuring nothing.
    private func makeEditor(lines: [String]) -> (EditorTextView, EditorCoordinator, [String]) {
        for line in lines {
            precondition(!line.isEmpty, "a blank seed line cannot hold meta")
        }
        let view = EditorTextView()
        let coordinator = EditorCoordinator()
        view.coordinator = coordinator
        // Both directions: the handlers reach the storage through
        // `coordinator.view`, which is weak.
        coordinator.view = view
        liveViews.append(view)

        let theme = coordinator.theme
        let storage = view.textStorage
        storage.setAttributedString(
            NSAttributedString(
                string: lines.joined(separator: "\n") + "\n",
                attributes: EditorAttributes.bodyAttributes(meta: LineMeta(), theme: theme)
            )
        )

        var ids: [String] = []
        var location = 0
        for _ in lines {
            let id = UUID().uuidString
            ids.append(id)
            let range = editableParagraphRange(in: storage.string as NSString, at: location)
            setLineMeta(
                LineMeta(marker: .blank, itemID: id),
                onParagraph: range,
                in: storage,
                theme: theme
            )
            location = NSMaxRange(range) + 1
        }
        return (view, coordinator, ids)
    }

    private func idsOfEveryParagraph(in view: EditorTextView) -> [String?] {
        var ids: [String?] = []
        let storage = view.textStorage
        let ns = storage.string as NSString
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: .byParagraphs
        ) { _, range, _, _ in
            ids.append(lineMeta(at: range.location, in: storage).itemID)
        }
        return ids
    }

    /// Undo of an auto-bullet rewrites a line that already exists, so it has to
    /// keep that line's identity. Rebuilding its meta from scratch drops the id
    /// and the line flushes as a new draft while the item it used to be stays
    /// live in the document.
    ///
    /// The bulletized line deliberately is not the first one: the undo only
    /// fires for a backspace at `lineLocation - 1`, which no line at offset 0
    /// can ever produce, so a single-line fixture would assert nothing.
    func testUndoingAnAutoBulletKeepsTheLinesIdentity() {
        let (view, coordinator, ids) = makeEditor(lines: ["first", "- "])
        let storage = view.textStorage
        let secondLine = ("first" as NSString).length + 1

        coordinator.maybeAutoBulletize(at: secondLine)

        XCTAssertEqual(
            lineMeta(at: secondLine, in: storage).marker, .bullet,
            "fixture did not actually bulletize, so the undo path is untested"
        )
        XCTAssertEqual(
            lineMeta(at: secondLine, in: storage).itemID, ids[1],
            "bulletizing must not change which item the line is"
        )

        let undone = coordinator.handleAutoBulletUndo(
            in: view,
            deletionRange: NSRange(location: secondLine - 1, length: 1)
        )
        XCTAssertTrue(undone, "the undo path did not run, so this test asserts nothing")

        XCTAssertEqual(
            lineMeta(at: secondLine, in: storage).itemID, ids[1],
            "undoing the bullet dropped the line's id, so the next flush would mint a second item for it"
        )
    }

    /// Enter beside a block line adds a brand-new adjacent line, which has to be
    /// minted with an id rather than waiting for the core to assign one.
    func testEnterBesideABlockLineMintsAnIdForTheNewLine() {
        let (view, coordinator, _) = makeEditor(lines: ["block", "after"])
        let storage = view.textStorage
        let theme = coordinator.theme

        // Turn the first line into a block line the way an attached table does:
        // an attachment glyph plus its own newline, carrying the table meta.
        let table = MobileTable(columns: [], rows: [])
        let blockMeta = LineMeta(
            marker: .blank,
            itemID: UUID().uuidString,
            tables: [table],
            content: [.table(table: table)]
        )
        XCTAssertTrue(blockMeta.hasBlockContent, "fixture is not a block line")
        let firstParagraph = editableParagraphRange(in: storage.string as NSString, at: 0)
        coordinator.suppress {
            storage.replaceCharacters(
                in: NSRange(location: 0, length: NSMaxRange(firstParagraph) + 1),
                with: makeBlockAttributedParagraph(meta: blockMeta, theme: theme)
            )
        }

        let paragraphsBefore = idsOfEveryParagraph(in: view).count
        XCTAssertTrue(coordinator.handleEnter(in: view, at: 0))
        XCTAssertEqual(
            idsOfEveryParagraph(in: view).count, paragraphsBefore + 1,
            "Enter did not add a line, so the minting path is untested"
        )

        for (index, id) in idsOfEveryParagraph(in: view).enumerated() {
            XCTAssertNotNil(
                id,
                "paragraph \(index) reached a flush with no id, so every flush would mint another item for it"
            )
        }
    }
}
