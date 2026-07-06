import SwiftUI
import UIKit

extension EditorCoordinator {
    func markClean() {
        // Skip the redundant write: loadItems now also runs inside makeUIView,
        // and publishing an unchanged @Published value there would trip
        // "publishing changes from within view updates".
        if controller?.isDirty == true {
            controller?.isDirty = false
        }
    }
}

// MARK: - NSLayoutManager subclass

final class EditorLayoutManager: NSLayoutManager {
    weak var editorTextView: EditorTextView?
    /// Character range whose markdown markers are revealed (the caret's line(s));
    /// markers elsewhere collapse to zero width for an Obsidian-style preview.
    private(set) var revealedRange = NSRange(location: 0, length: 0)

    override init() {
        super.init()
        delegate = self
    }

    /// Reveals the markdown markers inside `range` (collapsing all others) and
    /// rebuilds every line whose marker visibility changed — the whole document
    /// when `force` is set, otherwise just the union of the old and new revealed
    /// ranges. Returns whether anything actually changed.
    ///
    /// Both invalidations below are required. Regenerating glyphs re-tags the
    /// markers as control characters (`shouldGenerateGlyphs`), but collapsing
    /// them to zero width is a *layout*-time decision (`shouldUse:
    /// forControlCharacterAt:`). Without also invalidating layout, the cached
    /// line fragments keep the previous marker widths, so the reveal/collapse
    /// never takes visual effect as the caret moves between lines — the markers
    /// appear "stuck" on whichever line first revealed them.
    @discardableResult
    func setRevealedRange(_ range: NSRange, force: Bool) -> Bool {
        guard let storage = textStorage, storage.length > 0 else {
            revealedRange = range
            return false
        }
        let length = storage.length
        let range = clampedTextRange(range, length: length)
        let previous = clampedTextRange(revealedRange, length: length)
        guard force || !NSEqualRanges(previous, range) else {
            revealedRange = range
            return false
        }
        revealedRange = range

        let invalidation = force
            ? NSRange(location: 0, length: length)
            : rangeUnion(previous, range, length: length)
        guard invalidation.length > 0, invalidation.location < length else {
            return true
        }
        // Reveal/collapse only affects characters tagged `.knotqMarker`. The
        // revealed range moves on every keystroke and caret change; without this
        // check each one regenerates glyphs and forces a synchronous full
        // ensureLayout even on plain-text lines with nothing to reveal — enough
        // for UITextView to nudge the scroll mid-type at the document's bottom.
        if !force {
            var hasMarker = false
            storage.enumerateAttribute(.knotqMarker, in: invalidation) { value, _, stop in
                if value != nil {
                    hasMarker = true
                    stop.pointee = true
                }
            }
            guard hasMarker else { return false }
        }
        invalidateGlyphs(forCharacterRange: invalidation, changeInLength: 0, actualCharacterRange: nil)
        invalidateLayout(forCharacterRange: invalidation, actualCharacterRange: nil)
        if let container = textContainers.first {
            ensureLayout(for: container)
        }
        return true
    }

    private func rangeUnion(_ a: NSRange, _ b: NSRange, length: Int) -> NSRange {
        let lower = max(0, min(a.location, b.location))
        let upper = min(length, max(NSMaxRange(a), NSMaxRange(b)))
        return NSRange(location: lower, length: max(0, upper - lower))
    }

    /// A marker character is hidden when it is tagged `.knotqMarker` and falls
    /// outside the revealed range.
    func isHiddenMarker(at charIndex: Int) -> Bool {
        guard let storage = textStorage, charIndex >= 0, charIndex < storage.length else { return false }
        guard !NSLocationInRange(charIndex, revealedRange) else { return false }
        return storage.attribute(.knotqMarker, at: charIndex, effectiveRange: nil) != nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        let editor = editorTextView
        MainActor.assumeIsolated {
            editor?.drawChrome(forGlyphRange: glyphsToShow, at: origin)
        }
    }
}

extension EditorLayoutManager: NSLayoutManagerDelegate {
    /// Flag hidden marker glyphs as control characters so the zero-advancement
    /// action below collapses them without removing the characters from storage.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: UIFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        var properties = [NSLayoutManager.GlyphProperty](repeating: [], count: glyphRange.length)
        var changed = false
        for i in 0..<glyphRange.length {
            properties[i] = props[i]
            if isHiddenMarker(at: charIndexes[i]) {
                properties[i] = .controlCharacter
                changed = true
            }
        }
        guard changed else { return 0 }
        layoutManager.setGlyphs(
            glyphs,
            properties: &properties,
            characterIndexes: charIndexes,
            font: aFont,
            forGlyphRange: glyphRange
        )
        return glyphRange.length
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        isHiddenMarker(at: charIndex) ? .zeroAdvancement : action
    }

    func layoutManager(_ layoutManager: NSLayoutManager, lineSpacingAfterGlyphAt glyphIndex: Int, withProposedLineFragmentRect rect: CGRect) -> CGFloat {
        0
    }

    func layoutManager(_ layoutManager: NSLayoutManager, paragraphSpacingAfterGlyphAt glyphIndex: Int, withProposedLineFragmentRect rect: CGRect) -> CGFloat {
        let editor = editorTextView
        return MainActor.assumeIsolated {
            editor?.annotationSpacingAfterGlyph(at: glyphIndex) ?? 0
        }
    }
}
