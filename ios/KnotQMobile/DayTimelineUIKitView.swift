import SwiftUI
import UIKit

struct DayTimelineGeometry {
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
    let headerSurface = UIView()
    let titleLabel = UILabel()
    let titleButton = UIButton(type: .custom)
    let titleChevron = UIImageView()
    let titleBackdrop = UIView()
    let weekStrip = UIView()
    let separator = UIView()
    let scrollView = UIScrollView()
    let contentView = UIView()
    let dayClip = UIView()
    let dayCanvas = UIView()
    let timeGutter = UIView()
    let draftView = UIView()
    let draftTimeLabel = UILabel()
    let draftTitleLabel = UILabel()
    // One stack of indicators per rendered day column, including the previous
    // and next offscreen columns used during horizontal day swipes.
    var topStickyIndicatorStacks: [[DayTimelineStickyIndicatorView]] = []
    var bottomStickyIndicatorStacks: [[DayTimelineStickyIndicatorView]] = []
    var stickyDayColumnCount = 0

    var calendarSnapshot: MobileCalendar?
    var selectedDate = Date()
    var theme: KnotQTheme?
    var timeFormat = "twelve_hour"
    var preferredVisibleDays: Int?
    var onSetDate: (Date) -> Void = { _ in }
    var onCreate: (Date) -> Void = { _ in }
    var onOpenOccurrence: (MobileOccurrence) -> Void = { _ in }
    var onMoveOccurrence: (MobileOccurrence, Date?, Date?) -> Void = { _, _, _ in }
    var onTapTitle: () -> Void = {}

    var swipeOffset: CGFloat = 0
    var didInitialScroll = false
    var renderedBoundsSize: CGSize = .zero
    var activeCreateDraft: DayTimelineCreateDraft?
    var activeDragView: DayTimelineEventBlockView?
    var activeDragStartFrame: CGRect = .zero
    var activeDragGrabOffset: CGPoint = .zero
    var activeDragTarget: DayTimelineMoveTarget?
    var activeDragSnapKey: String?
    var creatingEvent = false
    var needsFullRender = true
    var resetToken = 0
    var nowIndicatorTimer: Timer?
    var lastNowIndicatorDay: Date?

    static let titleHeight: CGFloat = 42
    static let weekHeight: CGFloat = 66
    static let separatorHeight: CGFloat = 1

    /// The multi-day (iPad) header puts the weekday + number on one line, so it
    /// needs far less vertical room than the stacked single-day strip.
    var weekStripHeight: CGFloat { preferredVisibleDays != nil ? 42 : Self.weekHeight }
    static let hourHeight: CGFloat = 44
    static let gutterWidth: CGFloat = 50
    static let timeYOffset: CGFloat = 8
    static let hoursInDay = 24
    static let bottomPadding: CGFloat = 88
    static let timelineHeight = timeYOffset + CGFloat(hoursInDay) * hourHeight
    static let stickyIndicatorHeight: CGFloat = 26
    static let stickyFadeDistance: CGFloat = 44
    static let stickyStackSpacing: CGFloat = 4
    static let stickyStackDepth = 3
    static let bottomStickyChromeInset: CGFloat = 104
    static let dayDecorationLayerName = "knotq.dayTimeline.decoration"
    static let gutterDecorationLayerName = "knotq.dayTimeline.gutterDecoration"
    static let nowIndicatorLayerName = "knotq.dayTimeline.nowIndicator"

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
        draftTimeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        draftTitleLabel.text = "New"
        draftTitleLabel.textAlignment = .center
        draftTitleLabel.font = .systemFont(ofSize: 12, weight: .bold)
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

    var stickyIndicators: [DayTimelineStickyIndicatorView] {
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
        let weekHeight = weekStripHeight
        headerSurface.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.titleHeight + weekHeight)
        headerSurface.layer.shadowPath = UIBezierPath(rect: headerSurface.bounds).cgPath
        weekStrip.frame = CGRect(x: 0, y: Self.titleHeight, width: bounds.width, height: weekHeight)
        separator.frame = CGRect(x: 0, y: Self.titleHeight + weekHeight, width: bounds.width, height: Self.separatorHeight)
        scrollView.frame = CGRect(
            x: 0,
            y: Self.titleHeight + weekHeight + Self.separatorHeight,
            width: bounds.width,
            height: max(0, bounds.height - Self.titleHeight - weekHeight - Self.separatorHeight)
        )
        let sizeChanged = renderedBoundsSize != bounds.size
        if needsFullRender || sizeChanged {
            renderAllIfReady(force: sizeChanged)
        }
        renderedBoundsSize = bounds.size
        layoutTitleButton()
        updateStickyIndicators()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            stopNowIndicatorTimer()
            return
        }
        // SwiftUI can drive the first `configure`/`layoutSubviews` before this
        // view is in a window, which leaves the CALayer-drawn grid/events
        // uncommitted until the next interaction — the "Daily opens fully black
        // until you tap" bug. Worse, the stale layout leaves `currentGeometry()`
        // wrong, so scheduling/drag hit-testing misfires until then. Once we're
        // actually on screen, force a fresh render on the next runloop turn so
        // the timeline paints (and its geometry settles) immediately.
        needsFullRender = true
        setNeedsLayout()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.renderAllIfReady(force: true)
        }
        startNowIndicatorTimer()
    }

    isolated deinit {
        nowIndicatorTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    /// Keeps the now-line (and the day it belongs to) live while the
    /// timeline is on screen. iOS never redraws the "red line" on its own —
    /// without this it only moves when something else forces a re-render
    /// (scrolling, switching days, a data edit).
    private func startNowIndicatorTimer() {
        stopNowIndicatorTimer()
        lastNowIndicatorDay = Calendar.current.startOfDay(for: Date())
        // A fraction of a minute rather than exactly 60s so the line is
        // never more than ~20s stale even right after the timer starts.
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            self?.tickNowIndicator()
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        nowIndicatorTimer = timer
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleClockOrForegroundChange),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleClockOrForegroundChange),
            name: UIApplication.significantTimeChangeNotification, object: nil
        )
    }

    private func stopNowIndicatorTimer() {
        nowIndicatorTimer?.invalidate()
        nowIndicatorTimer = nil
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.significantTimeChangeNotification, object: nil)
    }

    @objc private func handleClockOrForegroundChange() {
        // The app may have been backgrounded for hours (timer paused the
        // whole time) or the clock may have jumped — always re-check.
        tickNowIndicator(force: true)
    }

    private func tickNowIndicator(force: Bool = false) {
        guard window != nil, theme != nil, calendarSnapshot != nil else { return }
        let today = Calendar.current.startOfDay(for: Date())
        if force || today != lastNowIndicatorDay {
            lastNowIndicatorDay = today
            // Midnight rollover (or a clock jump) changes which column is
            // "today" — the weekday strip, header title, and full-day past
            // shading all key off that, so give it the same full pass a
            // manual date change gets rather than just moving the line.
            needsFullRender = true
            setNeedsLayout()
            return
        }
        guard hasToday() else { return }
        // Don't yank a view out from under an in-progress drag or draft.
        guard activeDragView == nil, activeCreateDraft == nil else { return }
        refreshNowIndicators()
    }

    func layoutTitleButton() {
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

    func renderAllIfReady(force: Bool = false) {
        guard bounds.width > 10, bounds.height > 10, let theme else { return }
        UIView.performWithoutAnimation {
            renderHeader(theme: theme)
            renderTimeline(theme: theme, preserveScroll: didInitialScroll || force)
        }
        needsFullRender = false
    }

}
