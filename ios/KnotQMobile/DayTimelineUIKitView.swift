import SwiftUI
import UIKit

final class DayTimelineUIKitView: UIView, UIGestureRecognizerDelegate, UIScrollViewDelegate {
    private let titleLabel = UILabel()
    private let titleButton = UIButton(type: .custom)
    private let titleChevron = UIImageView()
    private let titleBackdrop: UIVisualEffectView = {
        if #available(iOS 26.0, *) {
            return UIVisualEffectView(effect: UIGlassEffect())
        }
        return UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    }()
    private let weekStrip = UIView()
    private let separator = UIView()
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let dayClip = UIView()
    private let dayCanvas = UIView()
    private let timeGutter = UIView()
    private let draftView = UIView()
    private let draftTimeLabel = UILabel()
    private let draftTitleLabel = UILabel()

    private var calendarSnapshot: MobileCalendar?
    private var selectedDate = Date()
    private var theme: KnotQTheme?
    private var timeFormat = "twelve_hour"
    private var onSetDate: (Date) -> Void = { _ in }
    private var onCreate: (Date) -> Void = { _ in }
    private var onOpenOccurrence: (MobileOccurrence) -> Void = { _ in }
    private var onMoveOccurrence: (MobileOccurrence, Date?, Date?) -> Void = { _, _, _ in }
    private var onTapTitle: () -> Void = {}

    private var swipeOffset: CGFloat = 0
    private var didInitialScroll = false
    private var renderedBoundsSize: CGSize = .zero
    private var activeCreateDraft: DayTimelineCreateDraft?
    private var activeDragView: DayTimelineEventBlockView?
    private var activeDragStartFrame: CGRect = .zero
    private var activeDragStartLocation: CGPoint = .zero
    private var activeDragTarget: DayTimelineMoveTarget?
    private var activeDragSnapKey: String?
    private var creatingEvent = false
    private var needsFullRender = true

    private static let titleHeight: CGFloat = 47
    private static let weekHeight: CGFloat = 63
    private static let separatorHeight: CGFloat = 1
    private static let hourHeight: CGFloat = 44
    private static let gutterWidth: CGFloat = 50
    private static let timeYOffset: CGFloat = 8
    private static let hoursInDay = 24
    private static let bottomPadding: CGFloat = 88
    private static let timelineHeight = timeYOffset + CGFloat(hoursInDay) * hourHeight
    private static let dayDecorationLayerName = "knotq.dayTimeline.decoration"
    private static let gutterDecorationLayerName = "knotq.dayTimeline.gutterDecoration"

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(titleButton)
        addSubview(weekStrip)
        addSubview(separator)
        addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(dayClip)
        contentView.addSubview(timeGutter)
        dayClip.addSubview(dayCanvas)
        dayCanvas.addSubview(draftView)

        // The month/year title is a tappable liquid-glass capsule that opens
        // the month overview. Glass falls back to an ultra-thin material below
        // iOS 26 so the pill still reads on older OSes.
        titleBackdrop.isUserInteractionEnabled = false
        titleBackdrop.clipsToBounds = true
        titleBackdrop.layer.borderWidth = 1
        titleButton.addSubview(titleBackdrop)
        titleButton.addSubview(titleLabel)
        titleButton.addSubview(titleChevron)
        titleLabel.isUserInteractionEnabled = false
        titleLabel.textAlignment = .center
        titleLabel.font = .systemFont(ofSize: 21, weight: .bold)
        titleChevron.isUserInteractionEnabled = false
        titleChevron.contentMode = .center
        titleChevron.image = UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        )
        titleButton.addTarget(self, action: #selector(handleTitleTap), for: .touchUpInside)
        titleButton.addTarget(self, action: #selector(handleTitlePressDown), for: [.touchDown, .touchDragEnter])
        titleButton.addTarget(
            self,
            action: #selector(handleTitlePressUp),
            for: [.touchUpInside, .touchUpOutside, .touchDragExit, .touchCancel]
        )
        separator.isUserInteractionEnabled = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsHorizontalScrollIndicator = false
        // The pane extends under the home indicator; manage insets manually so
        // the timeline scrolls all the way to the bottom edge (no auto lip).
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
        dayClip.clipsToBounds = true
        draftView.isHidden = true
        draftView.layer.cornerRadius = 3
        draftView.layer.borderWidth = 1.5
        draftView.addSubview(draftTimeLabel)
        draftView.addSubview(draftTitleLabel)
        draftTimeLabel.textAlignment = .center
        draftTimeLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        draftTitleLabel.text = "New"
        draftTitleLabel.textAlignment = .center
        draftTitleLabel.font = .systemFont(ofSize: 11, weight: .bold)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDayPan(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        scrollView.addGestureRecognizer(pan)

        let createPress = UILongPressGestureRecognizer(target: self, action: #selector(handleCreateLongPress(_:)))
        createPress.delegate = self
        createPress.minimumPressDuration = 0.45
        createPress.allowableMovement = 600
        scrollView.addGestureRecognizer(createPress)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        calendar: MobileCalendar?,
        selectedDate: Date,
        theme: KnotQTheme,
        timeFormat: String,
        onSetDate: @escaping (Date) -> Void,
        onCreate: @escaping (Date) -> Void,
        onOpenOccurrence: @escaping (MobileOccurrence) -> Void,
        onMoveOccurrence: @escaping (MobileOccurrence, Date?, Date?) -> Void,
        onTapTitle: @escaping () -> Void,
        isCreatingEvent: Bool
    ) {
        let nextSelectedDate = Calendar.current.startOfDay(for: selectedDate)
        let renderInputsChanged = calendarSnapshot != calendar
            || self.selectedDate != nextSelectedDate
            || self.theme?.isDark != theme.isDark
            || self.timeFormat != timeFormat
        let createClosed = creatingEvent && !isCreatingEvent

        self.calendarSnapshot = calendar
        self.selectedDate = nextSelectedDate
        self.theme = theme
        self.timeFormat = timeFormat
        self.onSetDate = onSetDate
        self.onCreate = onCreate
        self.onOpenOccurrence = onOpenOccurrence
        self.onMoveOccurrence = onMoveOccurrence
        self.onTapTitle = onTapTitle
        // The create draft is held on screen while its editor popover is open;
        // clear it on the true->false transition (the popover just closed).
        if createClosed {
            activeCreateDraft = nil
            draftView.isHidden = true
        }
        creatingEvent = isCreatingEvent
        backgroundColor = UIColor(theme.bgApp)
        titleLabel.textColor = UIColor(theme.textPrimary)
        titleChevron.tintColor = UIColor(theme.textMuted)
        titleBackdrop.layer.borderColor = UIColor(theme.dividerSoft).cgColor
        separator.backgroundColor = UIColor(theme.dividerSoft)
        if renderInputsChanged {
            needsFullRender = true
            setNeedsLayout()
            renderAllIfReady()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        weekStrip.frame = CGRect(x: 0, y: Self.titleHeight, width: bounds.width, height: Self.weekHeight)
        separator.frame = CGRect(x: 0, y: Self.titleHeight + Self.weekHeight, width: bounds.width, height: Self.separatorHeight)
        scrollView.frame = CGRect(
            x: 0,
            y: Self.titleHeight + Self.weekHeight + Self.separatorHeight,
            width: bounds.width,
            height: max(0, bounds.height - Self.titleHeight - Self.weekHeight - Self.separatorHeight)
        )
        let sizeChanged = renderedBoundsSize != bounds.size
        if needsFullRender || sizeChanged {
            renderAllIfReady(force: sizeChanged)
        }
        renderedBoundsSize = bounds.size
        layoutTitleButton()
    }

    private func layoutTitleButton() {
        titleLabel.sizeToFit()
        let textWidth = ceil(titleLabel.bounds.width)
        let chevronWidth: CGFloat = 16
        let gap: CGFloat = 3
        let hPad: CGFloat = 15
        let capsuleHeight: CGFloat = 34
        let capsuleWidth = textWidth + gap + chevronWidth + hPad * 2
        let capsuleX = ((bounds.width - capsuleWidth) / 2).rounded()
        let capsuleY = ((Self.titleHeight - capsuleHeight) / 2).rounded()
        titleButton.frame = CGRect(x: capsuleX, y: capsuleY, width: capsuleWidth, height: capsuleHeight)
        titleBackdrop.frame = titleButton.bounds
        titleBackdrop.layer.cornerRadius = capsuleHeight / 2
        titleLabel.frame = CGRect(x: hPad, y: 0, width: textWidth, height: capsuleHeight)
        titleChevron.frame = CGRect(x: hPad + textWidth + gap, y: 0, width: chevronWidth, height: capsuleHeight)
    }

    @objc private func handleTitleTap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onTapTitle()
    }

    @objc private func handleTitlePressDown() {
        UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction]) {
            self.titleButton.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
            self.titleButton.alpha = 0.85
        }
    }

    @objc private func handleTitlePressUp() {
        UIView.animate(withDuration: 0.16, delay: 0, options: [.allowUserInteraction]) {
            self.titleButton.transform = .identity
            self.titleButton.alpha = 1
        }
    }

    private func renderAllIfReady(force: Bool = false) {
        guard bounds.width > 10, bounds.height > 10, let theme else { return }
        UIView.performWithoutAnimation {
            renderHeader(theme: theme)
            renderTimeline(theme: theme, preserveScroll: didInitialScroll || force)
        }
        needsFullRender = false
    }

    private func renderHeader(theme: KnotQTheme) {
        titleLabel.text = monthTitle(for: selectedDate)
        weekStrip.subviews.forEach { $0.removeFromSuperview() }
        let sunday = weekStart(for: selectedDate)
        let cellWidth = bounds.width / 7
        for index in 0..<7 {
            let date = Calendar.current.date(byAdding: .day, value: index, to: sunday) ?? sunday
            let cell = DayTimelineDayCell(frame: CGRect(x: CGFloat(index) * cellWidth, y: 0, width: cellWidth, height: weekStrip.bounds.height))
            cell.date = date
            cell.weekdayLabel.text = weekdayInitial(date)
            cell.dayLabel.text = dayNumber(date)
            // Cohesive accent treatment matching the month grid: today is a
            // filled accent circle, visible days get a soft accent pill.
            let todayCell = isToday(date)
            let visibleCell = visibleDayKeys().contains(AppModel.dateOnly(date))
            cell.isTodayCell = todayCell
            cell.weekdayLabel.textColor = (todayCell || visibleCell)
                ? UIColor(theme.textPrimary)
                : UIColor(theme.textMuted)
            if todayCell {
                cell.rangeBackground.backgroundColor = UIColor(theme.accent)
                cell.dayLabel.textColor = theme.isDark ? .black : .white
            } else if visibleCell {
                cell.rangeBackground.backgroundColor = UIColor(theme.accent).withAlphaComponent(theme.isDark ? 0.16 : 0.12)
                cell.dayLabel.textColor = UIColor(theme.textPrimary)
            } else {
                cell.rangeBackground.backgroundColor = .clear
                cell.dayLabel.textColor = UIColor(theme.textPrimary)
            }
            cell.addTarget(self, action: #selector(handleWeekdayTap(_:)), for: .touchUpInside)
            weekStrip.addSubview(cell)
        }
    }

    private func renderTimeline(theme: KnotQTheme, preserveScroll: Bool) {
        let previousOffset = scrollView.contentOffset
        let visibleCount = visibleDayCount()
        let width = max(1, bounds.width)
        let colWidth = max(1, (width - Self.gutterWidth) / CGFloat(visibleCount))
        let dayCanvasWidth = colWidth * CGFloat(visibleCount + 2)

        contentView.frame = CGRect(x: 0, y: 0, width: width, height: Self.timelineHeight + Self.bottomPadding)
        scrollView.contentSize = contentView.bounds.size
        dayClip.frame = CGRect(x: Self.gutterWidth, y: 0, width: max(0, width - Self.gutterWidth), height: Self.timelineHeight)
        timeGutter.frame = CGRect(x: 0, y: 0, width: Self.gutterWidth, height: Self.timelineHeight)
        dayCanvas.frame = CGRect(x: -colWidth + swipeOffset, y: 0, width: dayCanvasWidth, height: Self.timelineHeight)

        timeGutter.subviews.forEach { $0.removeFromSuperview() }
        removeDecorationLayers(from: timeGutter.layer, named: Self.gutterDecorationLayerName)
        dayCanvas.subviews.filter { $0 !== draftView }.forEach { $0.removeFromSuperview() }
        removeDecorationLayers(from: dayCanvas.layer, named: Self.dayDecorationLayerName)
        if draftView.superview !== dayCanvas {
            dayCanvas.addSubview(draftView)
        }

        drawTimeGutter(theme: theme)
        drawPastShade(theme: theme, colWidth: colWidth, visibleCount: visibleCount)
        drawGrid(theme: theme, colWidth: colWidth, visibleCount: visibleCount)
        drawNowLine(theme: theme, colWidth: colWidth, visibleCount: visibleCount)
        drawEvents(theme: theme, colWidth: colWidth, visibleCount: visibleCount)
        updateDraftView(colWidth: colWidth)

        if !didInitialScroll {
            didInitialScroll = true
            let focusHour = hasToday() ? max(0, Calendar.current.component(.hour, from: Date()) - 1) : 7
            let y = min(max(0, Self.timeYOffset + CGFloat(focusHour) * Self.hourHeight), max(0, scrollView.contentSize.height - scrollView.bounds.height))
            scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        } else if preserveScroll {
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            scrollView.setContentOffset(CGPoint(x: 0, y: min(max(0, previousOffset.y), maxY)), animated: false)
        }
    }

    private func removeDecorationLayers(from layer: CALayer, named name: String) {
        layer.sublayers?
            .filter { $0.name == name }
            .forEach { $0.removeFromSuperlayer() }
    }

    private func drawTimeGutter(theme: KnotQTheme) {
        timeGutter.backgroundColor = UIColor(theme.bgApp)
        for hour in 0...Self.hoursInDay {
            let label = UILabel(frame: CGRect(x: 0, y: Self.timeYOffset + CGFloat(hour) * Self.hourHeight - 6, width: Self.gutterWidth - 8, height: 14))
            // The very bottom of the timeline is the next midnight (00:00 / 12 AM).
            label.text = hourLabel(hour % Self.hoursInDay)
            label.textAlignment = .right
            label.font = .systemFont(ofSize: 10, weight: .medium)
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

    /// Tints the already-elapsed part of each day blue, mirroring the desktop
    /// `cal_past` shade: a full column for past days, and top-to-now for today.
    /// Sits behind the grid, now-line, and events.
    private func drawPastShade(theme: KnotQTheme, colWidth: CGFloat, visibleCount: Int) {
        let today = Calendar.current.startOfDay(for: Date())
        let shade = UIColor(theme.accent).withAlphaComponent(theme.isDark ? 0.13 : 0.15).cgColor
        for index in -1...visibleCount {
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
            layer.name = Self.dayDecorationLayerName
            layer.backgroundColor = shade
            layer.frame = CGRect(x: CGFloat(index + 1) * colWidth, y: 0, width: colWidth, height: height)
            dayCanvas.layer.insertSublayer(layer, at: 0)
        }
    }

    private func drawGrid(theme: KnotQTheme, colWidth: CGFloat, visibleCount: Int) {
        let path = UIBezierPath()
        let width = colWidth * CGFloat(visibleCount + 2)
        for hour in 0...Self.hoursInDay {
            let y = min(Self.timelineHeight - 1, Self.timeYOffset + CGFloat(hour) * Self.hourHeight)
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: width, y: y))
        }
        for index in 0...(visibleCount + 2) {
            let x = CGFloat(index) * colWidth
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

    private func drawNowLine(theme: KnotQTheme, colWidth: CGFloat, visibleCount: Int) {
        guard let todayIndex = (-1...visibleCount).first(where: { isToday(dayDate($0)) }) else { return }
        let minute = Calendar.current.component(.hour, from: Date()) * 60 + Calendar.current.component(.minute, from: Date())
        let y = Self.timeYOffset + CGFloat(minute) / 60 * Self.hourHeight
        let x = CGFloat(todayIndex + 1) * colWidth
        let path = UIBezierPath()
        path.move(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: x + colWidth, y: y))
        let line = CAShapeLayer()
        line.name = Self.dayDecorationLayerName
        line.path = path.cgPath
        line.strokeColor = UIColor(theme.danger).cgColor
        line.lineWidth = 1.5
        dayCanvas.layer.addSublayer(line)
    }

    private func drawEvents(theme: KnotQTheme, colWidth: CGFloat, visibleCount: Int) {
        for dayIndex in -1...visibleCount {
            for laid in laidEvents(forDayIndex: dayIndex, colWidth: colWidth) {
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

    private func laidEvents(forDayIndex dayIndex: Int, colWidth: CGFloat) -> [DayTimelineLaidOccurrence] {
        struct Slot {
            let occurrence: MobileOccurrence
            let startMinute: CGFloat
            let endMinute: CGFloat
        }
        var slots: [Slot] = []
        for occurrence in occurrences(forDayIndex: dayIndex) {
            guard let startMinute = minuteOfDay(occurrence.start) ?? minuteOfDay(occurrence.end) else { continue }
            let minimumDuration: CGFloat = occurrence.kind == "event" ? 30 : 45
            let endMinute = max(startMinute + minimumDuration, minuteOfDay(occurrence.end) ?? startMinute + minimumDuration)
            slots.append(Slot(occurrence: occurrence, startMinute: startMinute, endMinute: endMinute))
        }
        slots.sort { $0.startMinute < $1.startMinute }

        var columnEnd: [CGFloat] = []
        var slotColumn = Array(repeating: 0, count: slots.count)
        for (index, slot) in slots.enumerated() {
            var placed = false
            for (column, end) in columnEnd.enumerated() where slot.startMinute >= end {
                columnEnd[column] = slot.endMinute
                slotColumn[index] = column
                placed = true
                break
            }
            if !placed {
                slotColumn[index] = columnEnd.count
                columnEnd.append(slot.endMinute)
            }
        }

        let subCount = max(1, columnEnd.count)
        let subWidth = colWidth / CGFloat(subCount)
        let columnX = CGFloat(dayIndex + 1) * colWidth
        return slots.enumerated().map { index, slot in
            let y = Self.timeYOffset + slot.startMinute / 60 * Self.hourHeight
            let minimumHeight: CGFloat = slot.occurrence.kind == "event" ? 20 : 34
            let height = max(minimumHeight, (slot.endMinute - slot.startMinute) / 60 * Self.hourHeight - 2)
            let frame = CGRect(
                x: columnX + CGFloat(slotColumn[index]) * subWidth + 1,
                y: y,
                width: max(8, subWidth - 2),
                height: height
            )
            return DayTimelineLaidOccurrence(
                occurrence: slot.occurrence,
                dayIndex: dayIndex,
                frame: frame,
                startMinute: slot.startMinute,
                endMinute: slot.endMinute
            )
        }
    }

    private func updateDraftView(colWidth: CGFloat) {
        guard let draft = activeCreateDraft, let theme else {
            draftView.isHidden = true
            return
        }
        let y = Self.timeYOffset + draft.startMinute / 60 * Self.hourHeight
        let x = CGFloat(draft.dayIndex + 1) * colWidth + 1
        draftView.frame = CGRect(x: x, y: y, width: max(8, colWidth - 2), height: Self.hourHeight - 2)
        draftView.backgroundColor = UIColor(theme.accent).withAlphaComponent(theme.isDark ? 0.32 : 0.22)
        draftView.layer.borderColor = UIColor(theme.accent).cgColor
        draftTimeLabel.text = draftTime(draft)
        let textColor = theme.isDark ? UIColor.white : UIColor(hex: 0x24272d)
        draftTimeLabel.textColor = textColor
        draftTitleLabel.textColor = textColor
        draftTimeLabel.frame = CGRect(x: 4, y: 3, width: draftView.bounds.width - 8, height: 12)
        draftTitleLabel.frame = CGRect(x: 4, y: 15, width: draftView.bounds.width - 8, height: 15)
        draftView.isHidden = false
    }

    @objc private func handleWeekdayTap(_ sender: UIControl) {
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

    @objc private func handleDayPan(_ recognizer: UIPanGestureRecognizer) {
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

    private func completeSwipe(dayDelta: Int, colWidth: CGFloat) {
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

    private func resetSwipe(colWidth: CGFloat) {
        swipeOffset = 0
        UIView.animate(withDuration: 0.20, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0.2, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.layoutDayCanvas(colWidth: colWidth)
        }
    }

    private func layoutDayCanvas(colWidth: CGFloat) {
        dayCanvas.frame.origin.x = -colWidth + swipeOffset
    }

    @objc private func handleCreateLongPress(_ recognizer: UILongPressGestureRecognizer) {
        let point = contentPoint(from: recognizer.location(in: scrollView))
        let visibleCount = visibleDayCount()
        let colWidth = max(1, (bounds.width - Self.gutterWidth) / CGFloat(visibleCount))
        switch recognizer.state {
        case .began:
            guard point.x >= Self.gutterWidth, hitEvent(at: point) == nil else { return }
            scrollView.isScrollEnabled = false
            activeCreateDraft = createDraft(at: point, colWidth: colWidth, visibleCount: visibleCount)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            updateDraftView(colWidth: colWidth)
        case .changed:
            let next = createDraft(at: point, colWidth: colWidth, visibleCount: visibleCount)
            if next != activeCreateDraft {
                activeCreateDraft = next
                UISelectionFeedbackGenerator().selectionChanged()
                updateDraftView(colWidth: colWidth)
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

    @objc private func handleEventLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let view = recognizer.view as? DayTimelineEventBlockView,
              let laid = view.laid,
              !laid.occurrence.isReadOnly else { return }
        let visibleCount = visibleDayCount()
        let colWidth = max(1, (bounds.width - Self.gutterWidth) / CGFloat(visibleCount))
        let location = recognizer.location(in: dayClip)
        switch recognizer.state {
        case .began:
            activeDragView = view
            activeDragStartFrame = view.frame
            activeDragStartLocation = location
            activeDragTarget = nil
            activeDragSnapKey = nil
            scrollView.isScrollEnabled = false
            dayCanvas.bringSubviewToFront(view)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .changed:
            let translation = CGPoint(x: location.x - activeDragStartLocation.x, y: location.y - activeDragStartLocation.y)
            let target = moveTarget(for: laid, translation: translation, colWidth: colWidth, visibleCount: visibleCount)
            activeDragTarget = target
            // Keep the calendar columns fixed while dragging an event — only the
            // event follows the finger, so the calendar never swipes left/right.
            view.frame = frameForDragging(laid: laid, target: target, translation: translation, colWidth: colWidth)
            let snapKey = "\(target.dayIndex)-\(Int(target.startMinute))"
            if snapKey != activeDragSnapKey {
                activeDragSnapKey = snapKey
                UISelectionFeedbackGenerator().selectionChanged()
            }
        case .ended:
            let target = activeDragTarget
            cleanupEventDrag(view: view, colWidth: colWidth, restoreStartFrame: target == nil)
            if let target {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                DispatchQueue.main.async {
                    self.onMoveOccurrence(laid.occurrence, target.start, target.end)
                }
            }
        case .cancelled, .failed:
            cleanupEventDrag(view: view, colWidth: colWidth, restoreStartFrame: true)
        default:
            break
        }
    }

    private func cleanupEventDrag(view: DayTimelineEventBlockView, colWidth: CGFloat, restoreStartFrame: Bool) {
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

    private func frameForDragging(laid: DayTimelineLaidOccurrence, target: DayTimelineMoveTarget, translation: CGPoint, colWidth: CGFloat) -> CGRect {
        let targetY = Self.timeYOffset + target.startMinute / 60 * Self.hourHeight
        let x = CGFloat(target.dayIndex + 1) * colWidth + max(1, activeDragStartFrame.minX - CGFloat(laid.dayIndex + 1) * colWidth)
        return CGRect(
            x: x,
            y: targetY,
            width: min(activeDragStartFrame.width, colWidth - 2),
            height: activeDragStartFrame.height
        )
    }

    private func moveTarget(for laid: DayTimelineLaidOccurrence, translation: CGPoint, colWidth: CGFloat, visibleCount: Int) -> DayTimelineMoveTarget {
        let startCenterInClip = CGPoint(
            x: activeDragStartFrame.midX + dayCanvas.frame.minX,
            y: activeDragStartFrame.midY
        )
        let proposedCenterX = startCenterInClip.x + translation.x
        let proposedCanvasX = proposedCenterX - dayCanvas.frame.minX
        let rawSlot = Int(floor(proposedCanvasX / colWidth))
        let dayIndex = min(visibleCount, max(-1, rawSlot - 1))
        let duration = max(15, laid.endMinute - laid.startMinute)
        let maxStart = laid.occurrence.kind == "event"
            ? CGFloat(Self.hoursInDay * 60) - duration
            : CGFloat(Self.hoursInDay * 60 - 15)
        let rawMinute = (activeDragStartFrame.minY + translation.y - Self.timeYOffset) / Self.hourHeight * 60
        let snapped = (rawMinute / 15).rounded() * 15
        let startMinute = max(0, min(maxStart, snapped))
        let base = Calendar.current.startOfDay(for: dayDate(dayIndex))
        let anchor = Calendar.current.date(byAdding: .minute, value: Int(startMinute), to: base)
        if laid.occurrence.kind == "assignment" {
            return DayTimelineMoveTarget(dayIndex: dayIndex, startMinute: startMinute, start: nil, end: anchor)
        }
        if laid.occurrence.kind == "reminder" {
            return DayTimelineMoveTarget(dayIndex: dayIndex, startMinute: startMinute, start: anchor, end: nil)
        }
        let end = anchor.flatMap { Calendar.current.date(byAdding: .minute, value: Int(duration), to: $0) }
        return DayTimelineMoveTarget(dayIndex: dayIndex, startMinute: startMinute, start: anchor, end: end)
    }

    private func createDraft(at point: CGPoint, colWidth: CGFloat, visibleCount: Int) -> DayTimelineCreateDraft {
        let clipX = point.x - Self.gutterWidth
        let canvasX = clipX - dayCanvas.frame.minX
        let rawSlot = Int(floor(canvasX / colWidth))
        let dayIndex = min(visibleCount, max(-1, rawSlot - 1))
        let rawMinute = max(0, (point.y - Self.timeYOffset) / Self.hourHeight * 60)
        let snapped = (rawMinute / 5).rounded(.down) * 5
        let clamped = max(0, min(CGFloat(Self.hoursInDay * 60 - 60), snapped))
        return DayTimelineCreateDraft(dayIndex: dayIndex, startMinute: clamped)
    }

    private func createDate(for draft: DayTimelineCreateDraft) -> Date? {
        Calendar.current.date(byAdding: .minute, value: Int(draft.startMinute), to: dayDate(draft.dayIndex))
    }

    private func draftTime(_ draft: DayTimelineCreateDraft) -> String {
        guard let date = createDate(for: draft) else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = timeFormat == "twenty_four_hour" ? "HH:mm" : "h:mm a"
        return formatter.string(from: date)
    }

    private func contentPoint(from point: CGPoint) -> CGPoint {
        point
    }

    private func hitEvent(at contentPoint: CGPoint) -> DayTimelineEventBlockView? {
        let canvasPoint = CGPoint(
            x: contentPoint.x - Self.gutterWidth - dayCanvas.frame.minX,
            y: contentPoint.y
        )
        return dayCanvas.subviews.reversed().compactMap { $0 as? DayTimelineEventBlockView }.first { $0.frame.contains(canvasPoint) }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UIPanGestureRecognizer {
            // The day-switch swipe must not begin while an event is being
            // dragged (the drag owns horizontal motion as a day-peek reveal).
            guard activeDragView == nil else { return false }
            let velocity = (gestureRecognizer as? UIPanGestureRecognizer)?.velocity(in: scrollView) ?? .zero
            let point = contentPoint(from: gestureRecognizer.location(in: scrollView))
            return point.x >= Self.gutterWidth
                && abs(velocity.x) > abs(velocity.y) * 1.15
                && hitEvent(at: point) == nil
        }
        if gestureRecognizer is UILongPressGestureRecognizer,
           gestureRecognizer.view === scrollView {
            let point = contentPoint(from: gestureRecognizer.location(in: scrollView))
            return point.x >= Self.gutterWidth && hitEvent(at: point) == nil
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }

    private func visibleDayCount() -> Int {
        bounds.width >= 620 ? 3 : 2
    }

    private func visibleDayKeys() -> Set<String> {
        Set((0..<visibleDayCount()).map { AppModel.dateOnly(dayDate($0)) })
    }

    private func dayDate(_ index: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: index, to: selectedDate) ?? selectedDate
    }

    private func occurrences(forDayIndex index: Int) -> [MobileOccurrence] {
        let key = AppModel.dateOnly(dayDate(index))
        return calendarSnapshot?.days.first { $0.date == key }?.occurrences ?? []
    }

    private func minuteOfDay(_ raw: String?) -> CGFloat? {
        guard let date = MobileDate.parseDateTime(raw) else { return nil }
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return CGFloat((components.hour ?? 0) * 60 + (components.minute ?? 0))
    }

    private func rubberBand(_ value: CGFloat, limit: CGFloat) -> CGFloat {
        let magnitude = abs(value)
        let sign: CGFloat = value < 0 ? -1 : 1
        if magnitude <= limit { return value }
        return sign * (limit + (magnitude - limit) * 0.18)
    }

    private func hasToday() -> Bool {
        (-1...visibleDayCount()).contains { isToday(dayDate($0)) }
    }

    private func isToday(_ date: Date) -> Bool {
        AppModel.dateOnly(date) == AppModel.dateOnly(Date())
    }

    private func weekStart(for date: Date) -> Date {
        let weekday = Calendar.current.component(.weekday, from: date)
        return Calendar.current.date(byAdding: .day, value: -(weekday - 1), to: Calendar.current.startOfDay(for: date)) ?? date
    }

    private func monthTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }

    private func weekdayInitial(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEEE"
        return formatter.string(from: date).uppercased()
    }

    private func dayNumber(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: date)
    }

    private func hourLabel(_ hour: Int) -> String {
        if timeFormat == "twenty_four_hour" {
            return String(format: "%02d:00", hour)
        }
        switch hour {
        case 0: return "12 AM"
        case 12: return "12 PM"
        case ..<12: return "\(hour) AM"
        default: return "\(hour - 12) PM"
        }
    }
}
