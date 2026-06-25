import SwiftUI
import UIKit

extension DayTimelineUIKitView {
    @objc func handleWeekdayTap(_ sender: UIControl) {
        guard let sender = sender as? DayTimelineDayCell else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        selectedDate = Calendar.current.startOfDay(for: sender.date)
        swipeOffset = 0
        renderAllIfReady()
        let date = selectedDate
        DispatchQueue.main.async {
            self.onSetDate(date)
        }
    }

    @objc func handleDayPan(_ recognizer: UIPanGestureRecognizer) {
        guard activeDragView == nil else { return }
        let visibleCount = visibleDayCount()
        let colWidth = max(1, (bounds.width - Self.gutterWidth) / CGFloat(visibleCount))
        switch recognizer.state {
        case .changed:
            let dx = recognizer.translation(in: scrollView).x
            swipeOffset = rubberBand(dx, limit: colWidth * 0.96)
            layoutDayCanvas(colWidth: colWidth)
        case .ended:
            let dx = recognizer.translation(in: scrollView).x
            let velocity = recognizer.velocity(in: scrollView).x
            let projected = abs(dx + velocity * 0.18) > abs(dx) ? dx + velocity * 0.18 : dx
            let shouldShift = abs(projected) > max(48, min(bounds.width * 0.15, colWidth * 0.68)) || abs(dx) > colWidth * 0.42
            if shouldShift {
                completeSwipe(dayDelta: projected < 0 ? 1 : -1, colWidth: colWidth)
            } else {
                resetSwipe(colWidth: colWidth)
            }
            recognizer.setTranslation(.zero, in: scrollView)
        case .cancelled, .failed:
            resetSwipe(colWidth: colWidth)
            recognizer.setTranslation(.zero, in: scrollView)
        default:
            break
        }
    }

    func completeSwipe(dayDelta: Int, colWidth: CGFloat) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let targetDate = Calendar.current.date(byAdding: .day, value: dayDelta, to: selectedDate) ?? selectedDate
        swipeOffset = dayDelta > 0 ? -colWidth : colWidth
        UIView.animate(withDuration: 0.22, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.2, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.layoutDayCanvas(colWidth: colWidth)
        } completion: { _ in
            self.swipeOffset = 0
            DispatchQueue.main.async {
                self.onSetDate(targetDate)
            }
        }
    }

    func resetSwipe(colWidth: CGFloat) {
        swipeOffset = 0
        UIView.animate(withDuration: 0.20, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0.2, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.layoutDayCanvas(colWidth: colWidth)
        }
    }

    func layoutDayCanvas(colWidth: CGFloat) {
        dayCanvas.frame.origin.x = -colWidth + swipeOffset
        updateStickyIndicators()
    }

    @objc func handleCreateLongPress(_ recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: dayClip)
        let geometry = currentGeometry()
        switch recognizer.state {
        case .began:
            guard dayClip.bounds.contains(point), hitEvent(atClipPoint: point, geometry: geometry) == nil else { return }
            scrollView.isScrollEnabled = false
            activeCreateDraft = createDraft(at: point, geometry: geometry)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            updateDraftView(geometry: geometry)
        case .changed:
            let next = createDraft(at: point, geometry: geometry)
            if next != activeCreateDraft {
                activeCreateDraft = next
                UISelectionFeedbackGenerator().selectionChanged()
                updateDraftView(geometry: geometry)
            }
        case .ended:
            scrollView.isScrollEnabled = true
            // Leave the draft block on screen so it marks the new task's slot
            // while the editor popover is open; it clears when the popover is
            // dismissed (see `configure`). If no date resolves, drop it now.
            if let draft = activeCreateDraft, let date = createDate(for: draft) {
                DispatchQueue.main.async {
                    self.onCreate(date)
                }
            } else {
                activeCreateDraft = nil
                draftView.isHidden = true
            }
        case .cancelled, .failed:
            activeCreateDraft = nil
            draftView.isHidden = true
            scrollView.isScrollEnabled = true
        default:
            break
        }
    }

    @objc func handleEventLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let view = recognizer.view as? DayTimelineEventBlockView,
              let laid = view.laid,
              !laid.occurrence.isReadOnly else { return }
        let geometry = currentGeometry()
        let location = recognizer.location(in: dayClip)
        switch recognizer.state {
        case .began:
            activeDragView = view
            activeDragStartFrame = view.frame
            activeDragGrabOffset = CGPoint(
                x: location.x - geometry.clipX(forCanvasX: view.frame.minX),
                y: location.y - view.frame.minY
            )
            activeDragTarget = nil
            activeDragSnapKey = nil
            scrollView.isScrollEnabled = false
            dayCanvas.bringSubviewToFront(view)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .changed:
            let target = moveTarget(for: laid, locationInClip: location, grabOffset: activeDragGrabOffset, geometry: geometry)
            activeDragTarget = target
            view.frame = target.frame
            let snapKey = "\(target.dayIndex)-\(Int(target.startMinute))"
            if snapKey != activeDragSnapKey {
                activeDragSnapKey = snapKey
                UISelectionFeedbackGenerator().selectionChanged()
            }
        case .ended:
            let target = activeDragTarget
            cleanupEventDrag(view: view, colWidth: geometry.columnWidth, restoreStartFrame: target == nil)
            if let target {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                DispatchQueue.main.async {
                    self.onMoveOccurrence(laid.occurrence, target.start, target.end)
                }
            }
        case .cancelled, .failed:
            cleanupEventDrag(view: view, colWidth: geometry.columnWidth, restoreStartFrame: true)
        default:
            break
        }
    }

    func cleanupEventDrag(view: DayTimelineEventBlockView, colWidth: CGFloat, restoreStartFrame: Bool) {
        scrollView.isScrollEnabled = true
        activeDragView = nil
        activeDragTarget = nil
        activeDragSnapKey = nil
        swipeOffset = 0
        UIView.performWithoutAnimation {
            self.layoutDayCanvas(colWidth: colWidth)
            if restoreStartFrame {
                view.frame = self.activeDragStartFrame
                self.renderAllIfReady()
            }
            self.layoutIfNeeded()
        }
    }

    func moveTarget(
        for laid: DayTimelineLaidOccurrence,
        locationInClip: CGPoint,
        grabOffset: CGPoint,
        geometry: DayTimelineGeometry
    ) -> DayTimelineMoveTarget {
        let proposedMinClipX = locationInClip.x - grabOffset.x
        let proposedCenterClipX = proposedMinClipX + activeDragStartFrame.width / 2
        let dayIndex = geometry.dayIndex(forClipX: proposedCenterClipX, in: geometry.visibleDayRange)
        let duration = max(15, laid.endMinute - laid.startMinute)
        let maxStart = laid.occurrence.kind == "event"
            ? CGFloat(Self.hoursInDay * 60) - duration
            : CGFloat(Self.hoursInDay * 60 - 15)
        let proposedMinY = locationInClip.y - grabOffset.y
        let rawMinute = (proposedMinY - Self.timeYOffset) / Self.hourHeight * 60
        let snapped = (rawMinute / 15).rounded() * 15
        let startMinute = max(0, min(maxStart, snapped))
        let width = min(activeDragStartFrame.width, geometry.columnWidth - 2)
        let sourceColumnOffset = activeDragStartFrame.minX - geometry.canvasX(forDayIndex: laid.dayIndex)
        let maxColumnOffset = max(1, geometry.columnWidth - width - 1)
        let columnOffset = min(max(1, sourceColumnOffset), maxColumnOffset)
        let frame = CGRect(
            x: geometry.canvasX(forDayIndex: dayIndex) + columnOffset,
            y: Self.timeYOffset + startMinute / 60 * Self.hourHeight,
            width: width,
            height: activeDragStartFrame.height
        )
        let base = Calendar.current.startOfDay(for: dayDate(dayIndex))
        let anchor = Calendar.current.date(byAdding: .minute, value: Int(startMinute), to: base)
        if laid.occurrence.kind == "assignment" {
            return DayTimelineMoveTarget(dayIndex: dayIndex, startMinute: startMinute, frame: frame, start: nil, end: anchor)
        }
        if laid.occurrence.kind == "reminder" {
            return DayTimelineMoveTarget(dayIndex: dayIndex, startMinute: startMinute, frame: frame, start: anchor, end: nil)
        }
        let end = anchor.flatMap { Calendar.current.date(byAdding: .minute, value: Int(duration), to: $0) }
        return DayTimelineMoveTarget(dayIndex: dayIndex, startMinute: startMinute, frame: frame, start: anchor, end: end)
    }

    func createDraft(at point: CGPoint, geometry: DayTimelineGeometry) -> DayTimelineCreateDraft {
        let dayIndex = geometry.dayIndex(forClipX: point.x, in: geometry.visibleDayRange)
        let rawMinute = max(0, (point.y - Self.timeYOffset) / Self.hourHeight * 60)
        let snapped = (rawMinute / 5).rounded(.down) * 5
        let clamped = max(0, min(CGFloat(Self.hoursInDay * 60 - 60), snapped))
        return DayTimelineCreateDraft(dayIndex: dayIndex, startMinute: clamped)
    }

    func createDate(for draft: DayTimelineCreateDraft) -> Date? {
        Calendar.current.date(byAdding: .minute, value: Int(draft.startMinute), to: dayDate(draft.dayIndex))
    }

    func draftTime(_ draft: DayTimelineCreateDraft) -> String {
        guard let date = createDate(for: draft) else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = timeFormat == "twenty_four_hour" ? "HH:mm" : "h:mm a"
        return formatter.string(from: date)
    }

    func currentGeometry() -> DayTimelineGeometry {
        let visibleCount = visibleDayCount()
        let width = max(1, bounds.width)
        let colWidth = max(1, (width - Self.gutterWidth) / CGFloat(visibleCount))
        let canvasOffset = dayCanvas.bounds.width > 0 ? dayCanvas.frame.minX : -colWidth + swipeOffset
        return DayTimelineGeometry(
            visibleCount: visibleCount,
            columnWidth: colWidth,
            canvasOffsetX: canvasOffset
        )
    }

    func hitEvent(atClipPoint point: CGPoint, geometry: DayTimelineGeometry) -> DayTimelineEventBlockView? {
        let canvasPoint = geometry.canvasPoint(fromClipPoint: point)
        return dayCanvas.subviews.reversed().compactMap { $0 as? DayTimelineEventBlockView }.first { $0.frame.contains(canvasPoint) }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UIPanGestureRecognizer {
            // The day-switch swipe must not begin while an event is being
            // dragged (the drag owns horizontal motion as a day-peek reveal).
            guard activeDragView == nil else { return false }
            let velocity = (gestureRecognizer as? UIPanGestureRecognizer)?.velocity(in: scrollView) ?? .zero
            let point = gestureRecognizer.location(in: dayClip)
            return dayClip.bounds.contains(point)
                && abs(velocity.x) > abs(velocity.y) * 1.15
                && hitEvent(atClipPoint: point, geometry: currentGeometry()) == nil
        }
        if gestureRecognizer is UILongPressGestureRecognizer,
           gestureRecognizer.view === scrollView {
            let point = gestureRecognizer.location(in: dayClip)
            return dayClip.bounds.contains(point) && hitEvent(atClipPoint: point, geometry: currentGeometry()) == nil
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }

}
