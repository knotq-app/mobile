import SwiftUI
import UIKit

extension DayTimelineUIKitView {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateStickyIndicators()
    }

    /// Rebuilds the per-column indicator stacks when the rendered day count
    /// changes so every visible and swipe-adjacent column gets its own
    /// top/bottom off-screen-event pills. Cheap no-op when unchanged.
    func ensureStickyStacks(columns: Int) {
        let columns = max(1, columns)
        guard columns != stickyDayColumnCount else { return }
        stickyIndicators.forEach { $0.removeFromSuperview() }
        func makeStacks() -> [[DayTimelineStickyIndicatorView]] {
            (0..<columns).map { _ in
                (0..<Self.stickyStackDepth).map { _ in DayTimelineStickyIndicatorView() }
            }
        }
        topStickyIndicatorStacks = makeStacks()
        bottomStickyIndicatorStacks = makeStacks()
        // Re-added above scrollView (added after it in the view list), matching
        // the original z-order so the pills stay tappable over the timeline.
        stickyIndicators.forEach { indicator in
            indicator.isHidden = true
            addSubview(indicator)
        }
        stickyDayColumnCount = columns
    }

    func updateStickyIndicators() {
        ensureStickyStacks(columns: visibleDayCount() + 2)
        guard let theme,
              scrollView.bounds.height > 1,
              dayClip.bounds.width > 1,
              calendarSnapshot != nil else {
            hideStickyIndicators()
            return
        }

        let geometry = currentGeometry()
        let bottomCutoff = bottomStickyCutoff()
        let visibleMinY = max(0, scrollView.contentOffset.y)
        let visibleMaxY = min(
            Self.timelineHeight,
            scrollView.contentOffset.y + scrollView.bounds.height - bottomCutoff
        )
        guard visibleMaxY > visibleMinY else {
            hideStickyIndicators()
            return
        }

        hideStickyIndicators()
        let bottomY = max(
            scrollView.frame.minY + 7,
            min(
                scrollView.frame.maxY - bottomCutoff - Self.stickyIndicatorHeight - 10,
                bounds.height - bottomCutoff - Self.stickyIndicatorHeight - 10
            )
        )

        for dayIndex in geometry.renderDayRange {
            guard let topIndicators = stickyIndicators(top: true, forDayIndex: dayIndex),
                  let bottomIndicators = stickyIndicators(top: false, forDayIndex: dayIndex) else {
                continue
            }

            let dayEvents = laidEvents(forDayIndex: dayIndex, geometry: geometry)
            let topCandidates = dayEvents
                .filter { $0.frame.minY < visibleMinY }
                .sorted { lhs, rhs in
                    if lhs.frame.minY != rhs.frame.minY {
                        return lhs.frame.minY > rhs.frame.minY
                    }
                    return lhs.frame.minX < rhs.frame.minX
                }
            let bottomCandidates = dayEvents
                .filter { $0.frame.minY > visibleMaxY }
                .sorted { lhs, rhs in
                    if lhs.frame.minY != rhs.frame.minY {
                        return lhs.frame.minY < rhs.frame.minY
                    }
                    return lhs.frame.minX < rhs.frame.minX
                }

            configureStickyIndicators(
                topIndicators,
                candidates: Array(topCandidates.prefix(topIndicators.count).reversed()),
                alphaForCandidate: { stickyAlpha(distance: visibleMinY - $0.frame.minY) },
                geometry: geometry,
                yForIndex: { scrollView.frame.minY + 7 + CGFloat($0) * (Self.stickyIndicatorHeight + Self.stickyStackSpacing) },
                theme: theme
            )
            configureStickyIndicators(
                bottomIndicators,
                candidates: Array(bottomCandidates.prefix(bottomIndicators.count).reversed()),
                alphaForCandidate: { stickyAlpha(distance: $0.frame.minY - visibleMaxY) },
                geometry: geometry,
                yForIndex: { max(scrollView.frame.minY + 7, bottomY - CGFloat($0) * (Self.stickyIndicatorHeight + Self.stickyStackSpacing)) },
                theme: theme
            )
        }
    }

    func configureStickyIndicators(
        _ indicators: [DayTimelineStickyIndicatorView],
        candidates: [DayTimelineLaidOccurrence],
        alphaForCandidate: (DayTimelineLaidOccurrence) -> CGFloat,
        geometry: DayTimelineGeometry,
        yForIndex: (Int) -> CGFloat,
        theme: KnotQTheme
    ) {
        for (index, indicator) in indicators.enumerated() {
            guard index < candidates.count else {
                indicator.isHidden = true
                continue
            }
            configureStickyIndicator(
                indicator,
                candidate: candidates[index],
                alpha: alphaForCandidate(candidates[index]),
                geometry: geometry,
                y: yForIndex(index),
                theme: theme
            )
        }
    }

    func configureStickyIndicator(
        _ indicator: DayTimelineStickyIndicatorView,
        candidate: DayTimelineLaidOccurrence,
        alpha: CGFloat,
        geometry: DayTimelineGeometry,
        y: CGFloat,
        theme: KnotQTheme
    ) {
        guard alpha > 0.02 else {
            indicator.isHidden = true
            return
        }
        let columnClipX = geometry.clipX(forCanvasX: geometry.canvasX(forDayIndex: candidate.dayIndex))
        let horizontalVisibleWidth = min(dayClip.bounds.width, columnClipX + geometry.columnWidth) - max(0, columnClipX)
        guard horizontalVisibleWidth > 0 else {
            indicator.isHidden = true
            return
        }
        let horizontalAlpha = min(1, max(0, horizontalVisibleWidth / min(geometry.columnWidth, Self.stickyFadeDistance)))
        let resolvedAlpha = alpha * horizontalAlpha
        guard resolvedAlpha > 0.02 else {
            indicator.isHidden = true
            return
        }
        let width = min(max(96, geometry.columnWidth - 14), bounds.width - dayClip.frame.minX - 14)
        let unclampedX = dayClip.frame.minX + columnClipX + 7
        let minX = dayClip.frame.minX + 7
        let maxX = max(minX, bounds.width - width - 7)
        indicator.frame = CGRect(
            x: min(max(unclampedX, minX), maxX),
            y: y,
            width: max(70, width),
            height: Self.stickyIndicatorHeight
        )
        indicator.configure(occurrence: candidate.occurrence, theme: theme)
        indicator.onTap = { [weak self] occurrence in self?.onOpenOccurrence(occurrence) }
        indicator.alpha = resolvedAlpha
        indicator.isHidden = false
    }

    func stickyAlpha(distance: CGFloat) -> CGFloat {
        min(1, max(0, distance / Self.stickyFadeDistance))
    }

    func stickyIndicators(top: Bool, forDayIndex dayIndex: Int) -> [DayTimelineStickyIndicatorView]? {
        let stacks = top ? topStickyIndicatorStacks : bottomStickyIndicatorStacks
        let stackIndex = dayIndex + 1
        guard stackIndex >= 0, stackIndex < stacks.count else { return nil }
        return stacks[stackIndex]
    }

    func bottomStickyCutoff() -> CGFloat {
        // iPad has no floating tab dock, so the bottom sticky indicator can sit
        // lower — only clear the safe area instead of the iPhone chrome inset.
        if UIDevice.current.userInterfaceIdiom == .pad {
            return safeAreaInsets.bottom + 24
        }
        return max(Self.bottomStickyChromeInset, safeAreaInsets.bottom + 64)
    }

    func hideStickyIndicators() {
        stickyIndicators.forEach { $0.isHidden = true }
    }

}
