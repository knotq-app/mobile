import SwiftUI
import UIKit

extension DayTimelineUIKitView {
    func renderHeader(theme: KnotQTheme) {
        titleLabel.text = monthTitle(for: selectedDate)
        weekStrip.subviews.forEach { $0.removeFromSuperview() }
        if preferredVisibleDays != nil {
            renderVisibleColumnHeader(theme: theme)
            return
        }

        let sunday = weekStart(for: selectedDate)
        let cellWidth = bounds.width / 7
        // Active days use standard iOS blue on the darker lip.
        let accent = UIColor(calendarDayHighlightColor(dark: theme.isDark))
        let secondaryAccent = UIColor(hex: theme.isDark ? 0x052547 : 0xbacada)
        let connectorAccent = UIColor(hex: theme.isDark ? 0x46515f : 0x9faebb)
        let secondaryText = theme.isDark ? UIColor(hex: 0xb9dcff) : UIColor(hex: 0x0059b8)
        let onAccent = onAccentTextColor(accent)
        let weekdayTextColor = UIColor(theme.textMuted).withAlphaComponent(theme.isDark ? 0.42 : 0.50)
        let visibleKeys = visibleDayKeys()
        let weekDates = (0..<7).map { index in
            Calendar.current.date(byAdding: .day, value: index, to: sunday) ?? sunday
        }
        let pillTop = DayTimelineDayCell.pillTop
        let pillHeight = DayTimelineDayCell.pillHeight

        // Two slim connectors per contiguous run, drawn center-to-center so the
        // day circles fully cover both ends without making the run a capsule.
        func addRangeConnector(start: Int, end: Int) {
            guard end > start else { return }
            let x = CGFloat(start) * cellWidth + cellWidth / 2
            let width = CGFloat(end - start) * cellWidth
            let barHeight: CGFloat = 4
            let barYs = [
                pillTop + pillHeight * 0.29,
                pillTop + pillHeight * 0.71 - barHeight
            ]
            for y in barYs {
                let bar = UIView(frame: CGRect(x: x, y: y, width: width, height: barHeight))
                bar.isUserInteractionEnabled = false
                bar.backgroundColor = connectorAccent
                bar.layer.cornerRadius = barHeight / 2
                bar.layer.cornerCurve = .continuous
                weekStrip.addSubview(bar)
            }
        }

        func addDayCircle(index: Int, today: Bool) {
            let circleSize = pillHeight
            let circleFrame = CGRect(
                x: CGFloat(index) * cellWidth + (cellWidth - circleSize) / 2,
                y: pillTop - (circleSize - pillHeight) / 2,
                width: circleSize,
                height: circleSize
            )
            let circle = UIView(frame: CGRect(
                x: circleFrame.minX,
                y: circleFrame.minY,
                width: circleFrame.width,
                height: circleFrame.height
            ))
            circle.isUserInteractionEnabled = false
            circle.backgroundColor = today ? accent : secondaryAccent
            circle.layer.cornerRadius = circleSize / 2
            circle.layer.cornerCurve = .continuous
            weekStrip.addSubview(circle)
        }

        var runStart: Int?
        for index in 0..<7 {
            let isVisible = visibleKeys.contains(AppModel.dateOnly(weekDates[index]))
            if isVisible, runStart == nil {
                runStart = index
            } else if !isVisible, let start = runStart {
                addRangeConnector(start: start, end: index - 1)
                runStart = nil
            }
        }
        if let start = runStart {
            addRangeConnector(start: start, end: 6)
        }

        for index in 0..<7 where visibleKeys.contains(AppModel.dateOnly(weekDates[index])) {
            addDayCircle(index: index, today: isToday(weekDates[index]))
        }

        for index in 0..<7 {
            let date = weekDates[index]
            let cell = DayTimelineDayCell(frame: CGRect(x: CGFloat(index) * cellWidth, y: 0, width: cellWidth, height: weekStrip.bounds.height))
            cell.date = date
            cell.weekdayLabel.text = weekdayInitial(date)
            cell.dayLabel.text = dayNumber(date)
            let visible = visibleKeys.contains(AppModel.dateOnly(date))
            let today = isToday(date)
            // Today keeps the primary blue; other visible days use the quieter
            // blue circle and connector.
            cell.weekdayLabel.textColor = today ? accent : weekdayTextColor
            cell.dayLabel.font = .systemFont(ofSize: 18, weight: today ? .bold : .medium)
            if visible {
                cell.dayLabel.textColor = today ? onAccent : secondaryText
            } else {
                cell.dayLabel.textColor = today ? accent : UIColor(theme.textPrimary)
            }
            cell.todayDot.isHidden = true
            cell.todayDot.backgroundColor = accent
            cell.addTarget(self, action: #selector(handleWeekdayTap(_:)), for: .touchUpInside)
            weekStrip.addSubview(cell)
        }
    }

    func renderVisibleColumnHeader(theme: KnotQTheme) {
        let visibleCount = visibleDayCount()
        let columnWidth = max(1, (bounds.width - Self.gutterWidth) / CGFloat(visibleCount))
        let accent = UIColor(calendarDayHighlightColor(dark: theme.isDark))
        let secondaryAccent = UIColor(hex: theme.isDark ? 0x052547 : 0xbacada)
        let secondaryText = theme.isDark ? UIColor(hex: 0xb9dcff) : UIColor(hex: 0x0059b8)
        let onAccent = onAccentTextColor(accent)
        let weekdayTextColor = UIColor(theme.textMuted).withAlphaComponent(theme.isDark ? 0.56 : 0.64)
        let gutter = UIView(frame: CGRect(x: 0, y: 0, width: Self.gutterWidth, height: weekStrip.bounds.height))
        gutter.isUserInteractionEnabled = false
        weekStrip.addSubview(gutter)

        // Single-line "Tue 9" cells, each with its own highlight capsule.
        for index in 0..<visibleCount {
            let date = dayDate(index)
            let cell = DayTimelineDayCell(frame: CGRect(
                x: Self.gutterWidth + CGFloat(index) * columnWidth,
                y: 0,
                width: columnWidth,
                height: weekStrip.bounds.height
            ))
            let today = isToday(date)
            cell.singleLine = true
            cell.date = date
            cell.weekdayLabel.text = weekdayShort(date)
            cell.dayLabel.text = dayNumber(date)
            cell.weekdayLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            cell.dayLabel.font = .systemFont(ofSize: 15, weight: today ? .bold : .semibold)
            cell.weekdayLabel.textColor = today ? onAccent : weekdayTextColor
            cell.dayLabel.textColor = today ? onAccent : secondaryText
            cell.showsPill = true
            cell.pillColor = today ? accent : secondaryAccent
            cell.addTarget(self, action: #selector(handleWeekdayTap(_:)), for: .touchUpInside)
            weekStrip.addSubview(cell)
        }
    }

    /// Black or white ink for text sitting on the accent pill, chosen by the
    /// accent's perceived luminance so it stays legible across every theme.
    func onAccentTextColor(_ accent: UIColor) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        accent.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luma = r * 0.299 + g * 0.587 + b * 0.114
        return luma > 0.6 ? UIColor(hex: 0x101216) : .white
    }

    func renderTimeline(theme: KnotQTheme, preserveScroll: Bool) {
        let previousOffset = scrollView.contentOffset
        let visibleCount = visibleDayCount()
        let width = max(1, bounds.width)
        let colWidth = max(1, (width - Self.gutterWidth) / CGFloat(visibleCount))
        let geometry = DayTimelineGeometry(
            visibleCount: visibleCount,
            columnWidth: colWidth,
            canvasOffsetX: -colWidth + swipeOffset
        )

        contentView.frame = CGRect(x: 0, y: 0, width: width, height: Self.timelineHeight + Self.bottomPadding)
        scrollView.contentSize = contentView.bounds.size
        dayClip.frame = CGRect(x: Self.gutterWidth, y: 0, width: max(0, width - Self.gutterWidth), height: Self.timelineHeight)
        timeGutter.frame = CGRect(x: 0, y: 0, width: Self.gutterWidth, height: Self.timelineHeight)
        dayCanvas.frame = CGRect(x: geometry.canvasOffsetX, y: 0, width: geometry.canvasWidth, height: Self.timelineHeight)

        timeGutter.subviews.forEach { $0.removeFromSuperview() }
        removeDecorationLayers(from: timeGutter.layer, named: Self.gutterDecorationLayerName)
        dayCanvas.subviews.filter { $0 !== draftView }.forEach { $0.removeFromSuperview() }
        removeDecorationLayers(from: dayCanvas.layer, named: Self.dayDecorationLayerName)
        removeDecorationLayers(from: dayCanvas.layer, named: Self.nowIndicatorLayerName)
        if draftView.superview !== dayCanvas {
            dayCanvas.addSubview(draftView)
        }

        drawTimeGutter(theme: theme)
        drawPastShade(theme: theme, geometry: geometry)
        drawGrid(theme: theme, geometry: geometry)
        drawNowLine(theme: theme, geometry: geometry)
        drawEvents(theme: theme, geometry: geometry)
        updateDraftView(geometry: geometry)

        if !didInitialScroll {
            didInitialScroll = true
            #if DEBUG
            let focusHour = AppModel.screenshotFixtureRequested ? 10 : (hasToday() ? max(0, Calendar.current.component(.hour, from: Date()) - 1) : 7)
            #else
            let focusHour = hasToday() ? max(0, Calendar.current.component(.hour, from: Date()) - 1) : 7
            #endif
            let y = min(max(0, Self.timeYOffset + CGFloat(focusHour) * Self.hourHeight), max(0, scrollView.contentSize.height - scrollView.bounds.height))
            scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        } else if preserveScroll {
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            scrollView.setContentOffset(CGPoint(x: 0, y: min(max(0, previousOffset.y), maxY)), animated: false)
        }
        updateStickyIndicators()
    }

    func removeDecorationLayers(from layer: CALayer, named name: String) {
        layer.sublayers?
            .filter { $0.name == name }
            .forEach { $0.removeFromSuperlayer() }
    }

    func drawTimeGutter(theme: KnotQTheme) {
        timeGutter.backgroundColor = UIColor(theme.bgApp)
        for hour in 0...Self.hoursInDay {
            let label = UILabel(frame: CGRect(x: 0, y: Self.timeYOffset + CGFloat(hour) * Self.hourHeight - 6, width: Self.gutterWidth - 8, height: 14))
            // The very bottom of the timeline is the next midnight (00:00 / 12 AM).
            label.text = hourLabel(hour % Self.hoursInDay)
            label.textAlignment = .right
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = UIColor(theme.textMuted)
            timeGutter.addSubview(label)
        }
        // Match the soft grid lines so the gutter edge doesn't stand out.
        let divider = CALayer()
        divider.name = Self.gutterDecorationLayerName
        divider.backgroundColor = UIColor(theme.dividerSoft).cgColor
        divider.frame = CGRect(x: Self.gutterWidth - 0.75, y: 0, width: 0.75, height: Self.timelineHeight)
        timeGutter.layer.addSublayer(divider)
    }

    /// Tints the already-elapsed part of each day, mirroring the desktop
    /// `cal_past` shade: a full column for past days, and top-to-now for today.
    /// Sits behind the grid, now-line, and events.
    func drawPastShade(theme: KnotQTheme, geometry: DayTimelineGeometry) {
        let today = Calendar.current.startOfDay(for: Date())
        let shade = UIColor(calendarDayHighlightColor(dark: theme.isDark)).withAlphaComponent(theme.isDark ? 0.11 : 0.13).cgColor
        for index in geometry.renderDayRange {
            let date = Calendar.current.startOfDay(for: dayDate(index))
            let height: CGFloat
            if date < today {
                height = Self.timelineHeight
            } else if date == today {
                let now = Date()
                let minute = Calendar.current.component(.hour, from: now) * 60
                    + Calendar.current.component(.minute, from: now)
                height = Self.timeYOffset + CGFloat(minute) / 60 * Self.hourHeight
            } else {
                continue
            }
            let layer = CALayer()
            layer.name = Self.nowIndicatorLayerName
            layer.backgroundColor = shade
            layer.frame = CGRect(x: geometry.canvasX(forDayIndex: index), y: 0, width: geometry.columnWidth, height: height)
            dayCanvas.layer.insertSublayer(layer, at: 0)
        }
    }

    func drawGrid(theme: KnotQTheme, geometry: DayTimelineGeometry) {
        let path = UIBezierPath()
        for hour in 0...Self.hoursInDay {
            let y = min(Self.timelineHeight - 1, Self.timeYOffset + CGFloat(hour) * Self.hourHeight)
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: geometry.canvasWidth, y: y))
        }
        for index in 0...(geometry.visibleCount + 2) {
            let x = CGFloat(index) * geometry.columnWidth
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: Self.timelineHeight))
        }
        let layer = CAShapeLayer()
        layer.name = Self.dayDecorationLayerName
        layer.path = path.cgPath
        layer.strokeColor = UIColor(theme.dividerSoft).cgColor
        layer.lineWidth = 0.5
        layer.fillColor = UIColor.clear.cgColor
        dayCanvas.layer.addSublayer(layer)
    }

    func drawNowLine(theme: KnotQTheme, geometry: DayTimelineGeometry) {
        guard let todayIndex = geometry.renderDayRange.first(where: { isToday(dayDate($0)) }) else { return }
        let minute = Calendar.current.component(.hour, from: Date()) * 60 + Calendar.current.component(.minute, from: Date())
        let y = Self.timeYOffset + CGFloat(minute) / 60 * Self.hourHeight
        let x = geometry.canvasX(forDayIndex: todayIndex)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: x + geometry.columnWidth, y: y))
        let line = CAShapeLayer()
        line.name = Self.nowIndicatorLayerName
        line.path = path.cgPath
        line.strokeColor = UIColor(theme.danger).cgColor
        line.lineWidth = 1.5
        // Keep it under the event blocks (as in the original draw order,
        // which ran before `drawEvents`) even when this is a standalone
        // refresh called after events already exist on screen.
        if let firstEventLayer = dayCanvas.subviews.first(where: { $0 !== draftView })?.layer {
            dayCanvas.layer.insertSublayer(line, below: firstEventLayer)
        } else {
            dayCanvas.layer.addSublayer(line)
        }
    }

    /// Re-draws just the elapsed-day shade and the now-line, without
    /// touching the grid, event views, or scroll position. Used by the
    /// once-a-minute tick so it can't disrupt an in-progress scroll/drag or
    /// recreate event views unnecessarily.
    func refreshNowIndicators() {
        guard let theme, bounds.width > 10, bounds.height > 10, dayCanvas.bounds.width > 0 else { return }
        removeDecorationLayers(from: dayCanvas.layer, named: Self.nowIndicatorLayerName)
        let geometry = currentGeometry()
        drawPastShade(theme: theme, geometry: geometry)
        drawNowLine(theme: theme, geometry: geometry)
    }

    func drawEvents(theme: KnotQTheme, geometry: DayTimelineGeometry) {
        for dayIndex in geometry.renderDayRange {
            for laid in laidEvents(forDayIndex: dayIndex, geometry: geometry) {
                let view = DayTimelineEventBlockView(frame: laid.frame)
                view.configure(laid: laid, theme: theme, timeFormat: timeFormat)
                view.onTap = { [weak self] occurrence in self?.onOpenOccurrence(occurrence) }
                if !laid.occurrence.isReadOnly {
                    let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleEventLongPress(_:)))
                    longPress.minimumPressDuration = 0.22
                    longPress.allowableMovement = 700
                    longPress.delegate = self
                    view.addGestureRecognizer(longPress)
                }
                dayCanvas.addSubview(view)
            }
        }
        dayCanvas.bringSubviewToFront(draftView)
    }

    func laidEvents(forDayIndex dayIndex: Int, geometry: DayTimelineGeometry) -> [DayTimelineLaidOccurrence] {
        struct Slot {
            let occurrence: MobileOccurrence
            let occurrences: [MobileOccurrence]
            let startMinute: CGFloat
            let endMinute: CGFloat
        }
        struct PendingSlot {
            let slot: Slot
            let lane: Int
        }
        struct PlacedSlot {
            let slot: Slot
            let lane: Int
            let laneSpan: Int
            let laneCount: Int
        }

        func slotsOverlap(_ lhs: Slot, _ rhs: Slot) -> Bool {
            lhs.startMinute < rhs.endMinute && rhs.startMinute < lhs.endMinute
        }

        func flushComponent(_ component: inout [PendingSlot], into placed: inout [PlacedSlot]) {
            guard !component.isEmpty else { return }
            let laneCount = (component.map(\.lane).max() ?? 0) + 1

            for pending in component {
                var laneSpan = 1
                if pending.lane + 1 < laneCount {
                    for lane in (pending.lane + 1)..<laneCount {
                        if component.contains(where: { other in
                            other.lane == lane && slotsOverlap(pending.slot, other.slot)
                        }) {
                            break
                        }
                        laneSpan += 1
                    }
                }
                placed.append(PlacedSlot(
                    slot: pending.slot,
                    lane: pending.lane,
                    laneSpan: laneSpan,
                    laneCount: laneCount
                ))
            }

            component.removeAll(keepingCapacity: true)
        }

        // Merge occurrences that share the exact same kind/start/end into one
        // slot, mirroring the desktop calendar's exact-time `equal_groups`
        // partition (see calendar/layout.rs). This keeps duplicates — or
        // distinct events booked at the same time — in a single full-width
        // block instead of splitting the column into thin slivers.
        var groupOrder: [String] = []
        var groups: [String: [MobileOccurrence]] = [:]
        for occurrence in occurrences(forDayIndex: dayIndex) {
            guard (minuteOfDay(occurrence.start) ?? minuteOfDay(occurrence.end)) != nil else { continue }
            let key = "\(occurrence.kind)|\(occurrence.start ?? "")|\(occurrence.end ?? "")"
            if groups[key] == nil {
                groups[key] = []
                groupOrder.append(key)
            }
            groups[key]?.append(occurrence)
        }

        var slots: [Slot] = []
        for key in groupOrder {
            guard let members = groups[key], let primary = members.first else { continue }
            let minimumDuration: CGFloat = primary.kind == "event" ? 30 : 45
            // When several same-time items share the block, reserve enough of the
            // timeline span to fit every stacked row, so neighbouring blocks lane
            // out around it instead of being overdrawn by the taller block.
            var reservedSpan = minimumDuration
            if members.count > 1 {
                let contentHeight = DayTimelineEventBlockView.contentHeight(
                    for: primary,
                    mergedCount: members.count,
                    timeFormat: timeFormat
                )
                reservedSpan = max(reservedSpan, contentHeight / Self.hourHeight * 60)
            }
            let startMinute: CGFloat
            let endMinute: CGFloat
            if primary.kind == "assignment" {
                // An assignment is anchored to its deadline: the block grows
                // upward so its bottom stroke sits at the due time, mirroring
                // the desktop calendar (see calendar/layout.rs estimate_range_y).
                guard let dueMinute = minuteOfDay(primary.end) ?? minuteOfDay(primary.start) else { continue }
                endMinute = dueMinute
                startMinute = max(0, dueMinute - reservedSpan)
            } else {
                guard let anchorMinute = minuteOfDay(primary.start) ?? minuteOfDay(primary.end) else { continue }
                startMinute = anchorMinute
                endMinute = max(startMinute + reservedSpan, minuteOfDay(primary.end) ?? startMinute + reservedSpan)
            }
            slots.append(Slot(occurrence: primary, occurrences: members, startMinute: startMinute, endMinute: endMinute))
        }
        slots.sort {
            if $0.startMinute == $1.startMinute {
                return $0.endMinute > $1.endMinute
            }
            return $0.startMinute < $1.startMinute
        }

        var placed: [PlacedSlot] = []
        var component: [PendingSlot] = []
        var componentEnd: CGFloat?
        var active: [(endMinute: CGFloat, lane: Int)] = []

        for slot in slots {
            if let currentEnd = componentEnd, slot.startMinute >= currentEnd {
                flushComponent(&component, into: &placed)
                active.removeAll(keepingCapacity: true)
                componentEnd = nil
            }

            active.removeAll { $0.endMinute <= slot.startMinute }

            var lane = 0
            while active.contains(where: { $0.lane == lane }) {
                lane += 1
            }
            active.append((slot.endMinute, lane))
            componentEnd = max(componentEnd ?? slot.endMinute, slot.endMinute)
            component.append(PendingSlot(slot: slot, lane: lane))
        }

        flushComponent(&component, into: &placed)

        let columnX = geometry.canvasX(forDayIndex: dayIndex)
        return placed.map { placement in
            let slot = placement.slot
            let subWidth = geometry.columnWidth / CGFloat(max(1, placement.laneCount))
            let minimumHeight: CGFloat = slot.occurrence.kind == "event" ? 20 : 34
            var height = max(minimumHeight, (slot.endMinute - slot.startMinute) / 60 * Self.hourHeight - 2)
            if slot.occurrences.count > 1 {
                height = max(height, DayTimelineEventBlockView.contentHeight(
                    for: slot.occurrence,
                    mergedCount: slot.occurrences.count,
                    timeFormat: timeFormat
                ))
            }
            // Assignments hang from their deadline: the frame's bottom edge (and
            // its stroke line) lands exactly on the due time, and any height
            // clamps grow the block upward instead of pushing it past the line.
            let y: CGFloat
            if slot.occurrence.kind == "assignment" {
                let dueY = Self.timeYOffset + slot.endMinute / 60 * Self.hourHeight
                y = max(Self.timeYOffset, dueY - height)
            } else {
                y = Self.timeYOffset + slot.startMinute / 60 * Self.hourHeight
            }
            let frame = CGRect(
                x: columnX + CGFloat(placement.lane) * subWidth + 1,
                y: y,
                width: max(8, subWidth * CGFloat(placement.laneSpan) - 2),
                height: height
            )
            return DayTimelineLaidOccurrence(
                occurrence: slot.occurrence,
                mergedOccurrences: slot.occurrences,
                dayIndex: dayIndex,
                frame: frame,
                startMinute: slot.startMinute,
                endMinute: slot.endMinute
            )
        }
    }

    func updateDraftView(geometry: DayTimelineGeometry) {
        guard let draft = activeCreateDraft, let theme else {
            draftView.isHidden = true
            return
        }
        let y = Self.timeYOffset + draft.startMinute / 60 * Self.hourHeight
        let x = geometry.canvasX(forDayIndex: draft.dayIndex) + 1
        draftView.frame = CGRect(x: x, y: y, width: max(8, geometry.columnWidth - 2), height: Self.hourHeight - 2)
        draftView.backgroundColor = UIColor(theme.accent).withAlphaComponent(theme.isDark ? 0.32 : 0.22)
        draftView.layer.borderColor = UIColor(theme.accent).cgColor
        draftTimeLabel.text = draftTime(draft)
        let textColor = theme.isDark ? UIColor.white : UIColor(hex: 0x24272d)
        draftTimeLabel.textColor = textColor
        draftTitleLabel.textColor = textColor
        draftTimeLabel.frame = CGRect(x: 4, y: 3, width: draftView.bounds.width - 8, height: 12)
        draftTitleLabel.frame = CGRect(x: 4, y: 15, width: draftView.bounds.width - 8, height: 16)
        draftView.isHidden = false
    }

}
