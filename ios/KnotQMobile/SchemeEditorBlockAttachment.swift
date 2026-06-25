import SwiftUI
import UIKit

final class KnotQBlockAttachment: NSTextAttachment {
    let block: MobileInline
    let indent: Int
    weak var owner: EditorTextView?

    init(block: MobileInline, indent: Int) {
        self.block = block
        self.indent = indent
        super.init(data: nil, ofType: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        // Sized off the owning text view so the reserved box matches what
        // `drawChrome` paints (same `editorInlineBlockMaxWidth`). TextKit runs
        // attachment layout on the main thread, where the owner is valid; the
        // owner-less fallback only covers the brief window before wiring.
        // As noted above, TextKit drives attachment layout on the main thread, so
        // the main-actor owner is safe to query — assert that to the compiler.
        // Capture into locals first (matching `drawChrome`/`annotationSpacing`
        // below) so the assumed-isolated closure captures the locals, not this
        // non-Sendable attachment.
        let owner = self.owner
        let block = self.block
        let indent = self.indent
        let fallbackWidth = max(120, lineFrag.width - CGFloat(indent) * DesktopEditorMetrics.indentWidth)
        let size: CGSize = MainActor.assumeIsolated {
            switch block {
            case let .image(media):
                return owner?.blockDisplaySize(forImage: media, indent: indent)
                    ?? CGSize(width: fallbackWidth, height: DesktopEditorMetrics.imageFallbackHeight)
            case let .table(table):
                return owner?.blockDisplaySize(forTable: table, indent: indent)
                    ?? CGSize(width: fallbackWidth, height: DesktopEditorMetrics.tableHeaderHeight + DesktopEditorMetrics.tableCellHeight)
            case .text:
                return .zero
            }
        }
        return CGRect(x: 0, y: 0, width: size.width, height: size.height)
    }

    /// The image/table is painted by the text view in `drawChrome` (the
    /// background pass); the attachment glyph itself must draw nothing. Returning
    /// a transparent image keeps TextKit's foreground glyph pass from stamping
    /// its default "missing attachment" document icon on top of our render.
    override func image(
        forBounds imageBounds: CGRect,
        textContainer: NSTextContainer?,
        characterIndex charIndex: Int
    ) -> UIImage? {
        Self.transparentGlyphImage
    }

    private static let transparentGlyphImage = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        .image { _ in }
}
