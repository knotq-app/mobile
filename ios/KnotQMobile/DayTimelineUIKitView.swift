import SwiftUI
import UIKit

private struct DayTimelineGeometry {
    let visibleCount: Int
    let columnWidth: CGFloat
    let canvasOffsetX: CGFloat

    var canvasWidth: CGFloat {
        columnWidth * CGFloat(visibleCount + 2)
    }

    var renderDayRange: ClosedRange<Int> {
        -1...visibleCount
    }

    var visibleDayRange: ClosedRange<Int> {
        0...max(0, visibleCount - 1)
    }

    func canvasX(forDayIndex dayIndex: Int) -> CGFloat {
        CGFloat(dayIndex + 1) * columnWidth
    }

    func canvasX(forClipX clipX: CGFloat) -> CGFloat {
        clipX - canvasOffsetX
    }

    func clipX(forCanvasX canvasX: CGFloat) -> CGFloat {
        canvasX + canvasOffsetX
    }

    func canvasPoint(fromClipPoint point: CGPoint) -> CGPoint {
        CGPoint(x: canvasX(forClipX: point.x), y: point.y)
    }

    func dayIndex(forClipX clipX: CGFloat, in range: ClosedRange<Int>) -> Int {
        dayIndex(forCanvasX: canvasX(forClipX: clipX), in: range)
    }

    func dayIndex(forCanvasX canvasX: CGFloat, in range: ClosedRange<Int>) -> Int {
        let raw = Int(floor(canvasX / columnWidth)) - 1
        return min(range.upperBound, max(range.lowerBound, raw))
    }
}

final class DayTimelineUIKitView: UIView, UIGestureRecognizerDelegate, UIScrollViewDelegate {
    private let headerSurface = UIView()
    private let titleLabel = UILabel()
    private let titleButton = UIButton(type: .custom)
    private let titleChevron = UIImageView()
    private let titleBackdrop = UIView()
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
    // One stack of indicators per rendered day column, including the previous
    // and next offscreen columns used during horizontal day swipes.
    private var topStickyIndicatorStacks: [[DayTimelineStickyIndicatorView]] = []
    private var bottomStickyIndicatorStacks: [[DayTimelineStickyIndicatorView]] = []
    private var stickyDayColumnCount = 0

    private var calendarSnapshot: MobileCalendar?
    private var selectedDate = Date()
    private var theme: KnotQTheme?
    private var timeFormat = "twelve_hour"
    private var preferredVisibleDays: Int?
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
    private var activeDragGrabOffset: CGPoint = .zero
    private var activeDragTarget: DayTimelineMoveTarget?
    private var activeDragSnapKey: String?
    private var creatingEvent = false
    private var needsFullRender = true
    private var resetToken = 0

    private static let titleHeight: CGFloat = 42
    private static let weekHeight: CGFloat = 66
    private static let separatorHeight: CGFloat = 1
    private static let hourHeight: CGFloat = 44
    private static let gutterWidth: CGFloat = 50
    private static let timeYOffset: CGFloat = 8
    private static let hoursInDay = 24
    private static let bottomPadding: CGFloat = 88
    private static let timelineHeight = timeYOffset + CGFloat(hoursInDay) * hourHeight
    private static let stickyIndicatorHeight: CGFloat = 26
    private static let stickyFadeDistance: CGFloat = 44
    private static let stickyStackSpacing: CGFloat = 4
    private static let stickyStackDepth = 3
    private static let bottomStickyChromeInset: CGFloat = 104
    private static let dayDecorationLayerName = "knotq.dayTimeline.decoration"
    private static let gutterDecorationLayerName = "knotq.dayTimeline.gutterDecoration"

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(headerSurface)
        addSubview(titleButton)
        addSubview(weekStrip)
        addSubview(separator)
        addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(dayClip)
        contentView.addSubview(timeGutter)
        dayClip.addSubview(dayCanvas)
        dayCanvas.addSubview(draftView)

        // The month/year title is a compact header control that opens the
        // month overview, matching the desktop calendar's flatter chrome.
        headerSurface.isUserInteractionEnabled = false
        titleBackdrop.isUserInteractionEnabled = false
        titleBackdrop.clipsToBounds = true
        titleBackdrop.layer.borderWidth = 0.75
        titleButton.addSubview(titleBackdrop)
        titleButton.addSubview(titleLabel)
        titleButton.addSubview(titleChevron)
        titleLabel.isUserInteractionEnabled = false
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleChevron.isUserInteractionEnabled = false
        titleChevron.contentMode = .center
        titleChevron.image = UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
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
        hideStickyIndicators()

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

    private var stickyIndicators: [DayTimelineStickyIndicatorView] {
        topStickyIndicatorStacks.flatMap { $0 } + bottomStickyIndicatorStacks.flatMap { $0 }
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
        isCreatingEvent: Bool,
        resetToken: Int,
        preferredVisibleDays: Int?
    ) {
        let nextSelectedDate = Calendar.current.startOfDay(for: selectedDate)
        let shouldReset = self.resetToken != resetToken
        let renderInputsChanged = calendarSnapshot != calendar
            || self.selectedDate != nextSelectedDate
            || self.theme?.isDark != theme.isDark
            || self.timeFormat != timeFormat
            || self.preferredVisibleDays != preferredVisibleDays
        let createClosed = creatingEvent && !isCreatingEvent

        self.calendarSnapshot = calendar
        self.selectedDate = nextSelectedDate
        self.theme = theme
        self.timeFormat = timeFormat
        self.preferredVisibleDays = preferredVisibleDays
        self.onSetDate = onSetDate
        self.onCreate = onCreate
        self.onOpenOccurrence = onOpenOccurrence
        self.onMoveOccurrence = onMoveOccurrence
        self.onTapTitle = onTapTitle
        self.resetToken = resetToken
        // The create draft is held on screen while its editor popover is open;
        // clear it on the true->false transition (the popover just closed).
        if createClosed {
            activeCreateDraft = nil
            draftView.isHidden = true
        }
        if shouldReset {
            activeDragView = nil
            activeDragTarget = nil
            activeDragSnapKey = nil
            scrollView.isScrollEnabled = true
            needsFullRender = true
        }
        creatingEvent = isCreatingEvent
        backgroundColor = UIColor(theme.bgApp)
        let calendarBlue = UIColor(calendarDayHighlightColor(dark: theme.isDark))
        // The calendar lip is intentionally darker than the rest of the mobile
        // chrome so the active-day blue carries the hierarchy.
        headerSurface.backgroundColor = theme.isDark ? UIColor(hex: 0x030306) : UIColor(theme.bgToolbar)
        headerSurface.layer.shadowColor = UIColor.black.cgColor
        headerSurface.layer.shadowOpacity = theme.isDark ? 0 : 0.07
        headerSurface.layer.shadowRadius = 5
        headerSurface.layer.shadowOffset = CGSize(width: 0, height: 2)
        weekStrip.backgroundColor = .clear
        titleLabel.textColor = UIColor(theme.textPrimary)
        titleChevron.tintColor = calendarBlue
        titleBackdrop.isHidden = false
        titleBackdrop.backgroundColor = theme.isDark
            ? UIColor(hex: 0x0b0c10)
            : UIColor(theme.buttonBg)
        titleBackdrop.layer.borderColor = (theme.isDark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor(theme.borderOverlay)
        ).cgColor
        separator.isHidden = false
        separator.backgroundColor = theme.isDark
            ? UIColor.white.withAlphaComponent(0.07)
            : UIColor(theme.dividerSoft)
        if renderInputsChanged || shouldReset {
            needsFullRender = true
            setNeedsLayout()
            renderAllIfReady(force: shouldReset)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        headerSurface.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.titleHeight + Self.weekHeight)
        headerSurface.layer.shadowPath = UIBezierPath(rect: headerSurface.bounds).cgPath
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
        updateStickyIndicators()
    }

    private func layoutTitleButton() {
        // Centered month control: compact enough for the lip, but still clearly
        // tappable as the month overview affordance.
        titleLabel.sizeToFit()
        let textWidth = ceil(titleLabel.bounds.width)
        let chevronWidth: CGFloat = 16
        let gap: CGFloat = 3
        let hPad: CGFloat = 12
        let buttonHeight: CGFloat = 31
        let maxContentWidth = max(0, bounds.width - 32 - hPad * 2)
        let contentWidth = min(maxContentWidth, textWidth + gap + chevronWidth)
        let labelWidth = max(0, contentWidth - gap - chevronWidth)
        let buttonWidth = contentWidth + hPad * 2
        let buttonX = ((bounds.width - buttonWidth) / 2).rounded()
        let buttonY = ((Self.titleHeight - buttonHeight) / 2).rounded()
        titleButton.frame = CGRect(x: buttonX, y: buttonY, width: buttonWidth, height: buttonHeight)
        titleBackdrop.frame = titleButton.bounds
        titleBackdrop.layer.cornerRadius = buttonHeight / 2
        titleBackdrop.layer.cornerCurve = .continuous
        titleLabel.frame = CGRect(x: hPad, y: 0, width: labelWidth, height: buttonHeight)
        titleChevron.frame = CGRect(x: hPad + labelWidth + gap, y: 0, width: chevronWidth, height: buttonHeight)
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
        // Active days use standard iOS blue on the darker lip.
        let accent = UIColor(calendarDayHighlightColor(dark: theme.isDark))
        let onAccent = onAccentTextColor(accent)
        let weekdayTextColor = UIColor(theme.textMuted).withAlphaComponent(theme.isDark ? 0.42 : 0.50)
        let visibleKeys = visibleDayKeys()
        let weekDates = (0..<7).map { index in
            Calendar.current.date(byAdding: .day, value: index, to: sunday) ?? sunday
        }
        let pillTop = DayTimelineDayCell.pillTop
        let pillHeight = DayTimelineDayCell.pillHeight

        // One capsule per contiguous run of visible days, drawn behind the cells.
        func addAccentPill(start: Int, end: Int) {
            let inset: CGFloat = 6
            let span = CGFloat(end - start + 1) * cellWidth
            let width = max(pillHeight, span - inset * 2)
            // Degenerate single-day runs (week boundaries) center a circle.
            let x = CGFloat(start) * cellWidth + (span - width) / 2
            let pill = UIView(frame: CGRect(x: x, y: pillTop, width: width, height: pillHeight))
            pill.isUserInteractionEnabled = false
            pill.backgroundColor = accent
            pill.layer.cornerRadius = pillHeight / 2
            pill.layer.cornerCurve = .continuous
            weekStrip.addSubview(pill)
        }
        var runStart: Int?
        for index in 0..<7 {
            let isVisible = visibleKeys.contains(AppModel.dateOnly(weekDates[index]))
            if isVisible, runStart == nil {
                runStart = index
            } else if !isVisible, let start = runStart {
                addAccentPill(start: start, end: index - 1)
                runStart = nil
            }
        }
        if let start = runStart {
            addAccentPill(start: start, end: 6)
        }

        for index in 0..<7 {
            let date = weekDates[index]
            let cell = DayTimelineDayCell(frame: CGRect(x: CGFloat(index) * cellWidth, y: 0, width: cellWidth, height: weekStrip.bounds.height))
            cell.date = date
            cell.weekdayLabel.text = weekdayInitial(date)
            cell.dayLabel.text = dayNumber(date)
            let visible = visibleKeys.contains(AppModel.dateOnly(date))
            let today = isToday(date)
            // Weekday initials stay neutral; only the day number/pill carries
            // the active blue.
            cell.weekdayLabel.textColor = weekdayTextColor
            cell.dayLabel.textColor = visible ? onAccent : (today ? accent : UIColor(theme.textPrimary))
            cell.todayDot.isHidden = !today
            cell.todayDot.backgroundColor = accent
            cell.addTarget(self, action: #selector(handleWeekdayTap(_:)), for: .touchUpInside)
            weekStrip.addSubview(cell)
        }
    }

    /// Black or white ink for text sitting on the accent pill, chosen by the
    /// accent's perceived luminance so it stays legible across every theme.
    private func onAccentTextColor(_ accent: UIColor) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        accent.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luma = r * 0.299 + g * 0.587 + b * 0.114
        return luma > 0.6 ? UIColor(hex: 0x101216) : .white
    }

    private func renderTimeline(theme: KnotQTheme, preserveScroll: Bool) {
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
            let focusHour = hasToday() ? max(0, Calendar.current.component(.hour, from: Date()) - 1) : 7
            let y = min(max(0, Self.timeYOffset + CGFloat(focusHour) * Self.hourHeight), max(0, scrollView.contentSize.height - scrollView.bounds.height))
            scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        } else if preserveScroll {
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            scrollView.setContentOffset(CGPoint(x: 0, y: min(max(0, previousOffset.y), maxY)), animated: false)
        }
        updateStickyIndicators()
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

    /// Tints the already-elapsed part of each day, mirroring the desktop
    /// `cal_past` shade: a full column for past days, and top-to-now for today.
    /// Sits behind the grid, now-line, and events.
    private func drawPastShade(theme: KnotQTheme, geometry: DayTimelineGeometry) {
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
            layer.name = Self.dayDecorationLayerName
            layer.backgroundColor = shade
            layer.frame = CGRect(x: geometry.canvasX(forDayIndex: index), y: 0, width: geometry.columnWidth, height: height)
            dayCanvas.layer.insertSublayer(layer, at: 0)
        }
    }

    private func drawGrid(theme: KnotQTheme, geometry: DayTimelineGeometry) {
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

    private func drawNowLine(theme: KnotQTheme, geometry: DayTimelineGeometry) {
        guard let todayIndex = geometry.renderDayRange.first(where: { isToday(dayDate($0)) }) else { return }
        let minute = Calendar.current.component(.hour, from: Date()) * 60 + Calendar.current.component(.minute, from: Date())
        let y = Self.timeYOffset + CGFloat(minute) / 60 * Self.hourHeight
        let x = geometry.canvasX(forDayIndex: todayIndex)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: x + geometry.columnWidth, y: y))
        let line = CAShapeLayer()
        line.name = Self.dayDecorationLayerName
        line.path = path.cgPath
        line.strokeColor = UIColor(theme.danger).cgColor
        line.lineWidth = 1.5
        dayCanvas.layer.addSublayer(line)
    }

    private func drawEvents(theme: KnotQTheme, geometry: DayTimelineGeometry) {
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

    private func laidEvents(forDayIndex dayIndex: Int, geometry: DayTimelineGeometry) -> [DayTimelineLaidOccurrence] {
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
        let subWidth = geometry.columnWidth / CGFloat(subCount)
        let columnX = geometry.canvasX(forDayIndex: dayIndex)
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

    private func updateDraftView(geometry: DayTimelineGeometry) {
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
        draftTitleLabel.frame = CGRect(x: 4, y: 15, width: draftView.bounds.width - 8, height: 15)
        draftView.isHidden = false
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateStickyIndicators()
    }

    /// Rebuilds the per-column indicator stacks when the rendered day count
    /// changes so every visible and swipe-adjacent column gets its own
    /// top/bottom off-screen-event pills. Cheap no-op when unchanged.
    private func ensureStickyStacks(columns: Int) {
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

    private func updateStickyIndicators() {
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

    private func configureStickyIndicators(
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

    private func configureStickyIndicator(
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

    private func stickyAlpha(distance: CGFloat) -> CGFloat {
        min(1, max(0, distance / Self.stickyFadeDistance))
    }

    private func stickyIndicators(top: Bool, forDayIndex dayIndex: Int) -> [DayTimelineStickyIndicatorView]? {
        let stacks = top ? topStickyIndicatorStacks : bottomStickyIndicatorStacks
        let stackIndex = dayIndex + 1
        guard stackIndex >= 0, stackIndex < stacks.count else { return nil }
        return stacks[stackIndex]
    }

    private func bottomStickyCutoff() -> CGFloat {
        max(Self.bottomStickyChromeInset, safeAreaInsets.bottom + 64)
    }

    private func hideStickyIndicators() {
        stickyIndicators.forEach { $0.isHidden = true }
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
        updateStickyIndicators()
    }

    @objc private func handleCreateLongPress(_ recognizer: UILongPressGestureRecognizer) {
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

    @objc private func handleEventLongPress(_ recognizer: UILongPressGestureRecognizer) {
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

    private func moveTarget(
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

    private func createDraft(at point: CGPoint, geometry: DayTimelineGeometry) -> DayTimelineCreateDraft {
        let dayIndex = geometry.dayIndex(forClipX: point.x, in: geometry.visibleDayRange)
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

    private func currentGeometry() -> DayTimelineGeometry {
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

    private func hitEvent(atClipPoint point: CGPoint, geometry: DayTimelineGeometry) -> DayTimelineEventBlockView? {
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

    private func visibleDayCount() -> Int {
        if let preferredVisibleDays {
            return max(2, min(7, preferredVisibleDays))
        }
        return bounds.width >= 620 ? 3 : 2
    }

    private func visibleDayKeys() -> Set<String> {
        Set((0..<visibleDayCount()).map { AppModel.dateOnly(dayDate($0)) })
    }

    private func dayDate(_ index: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: index, to: selectedDate) ?? selectedDate
    }

    private func occurrences(forDayIndex index: Int) -> [MobileOccurrence] {
        let key = AppModel.dateOnly(dayDate(index))
        guard let calendarSnapshot else { return [] }
        var seen = Set<String>()
        var out: [MobileOccurrence] = []
        for occurrence in calendarSnapshot.days.flatMap(\.occurrences) {
            guard occurrence.localAnchorDateKey == key, seen.insert(occurrence.id).inserted else {
                continue
            }
            out.append(occurrence)
        }
        return out
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
