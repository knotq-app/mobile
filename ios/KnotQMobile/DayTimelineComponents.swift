import SwiftUI
import UIKit

struct DayTimelinePane: UIViewRepresentable {
    let calendar: MobileCalendar?
    let selectedDate: Date
    let theme: KnotQTheme
    let timeFormat: String
    let onSetDate: (Date) -> Void
    let onCreate: (Date) -> Void
    let onOpenOccurrence: (MobileOccurrence) -> Void
    let onMoveOccurrence: (MobileOccurrence, Date?, Date?) -> Void
    let onTapTitle: () -> Void
    let isCreatingEvent: Bool
    let resetToken: Int
    /// Forces a specific visible-day count (iPad shows 5); `nil` keeps the
    /// width-based iPhone behavior (2, or 3 in landscape).
    let preferredVisibleDays: Int?

    func makeUIView(context: Context) -> DayTimelineUIKitView {
        DayTimelineUIKitView()
    }

    func updateUIView(_ uiView: DayTimelineUIKitView, context: Context) {
        uiView.configure(
            calendar: calendar,
            selectedDate: selectedDate,
            theme: theme,
            timeFormat: timeFormat,
            onSetDate: onSetDate,
            onCreate: onCreate,
            onOpenOccurrence: onOpenOccurrence,
            onMoveOccurrence: onMoveOccurrence,
            onTapTitle: onTapTitle,
            isCreatingEvent: isCreatingEvent,
            resetToken: resetToken,
            preferredVisibleDays: preferredVisibleDays
        )
    }
}


struct DayTimelineCreateDraft: Equatable {
    let dayIndex: Int
    let startMinute: CGFloat
}

struct DayTimelineLaidOccurrence {
    /// The representative occurrence used for the block's styling, tap target,
    /// and drag. When several occurrences share the exact same kind/start/end
    /// (duplicates, or distinct events at the same time) they are merged into a
    /// single block — mirroring the desktop calendar's `equal_groups` — and
    /// `mergedOccurrences` holds every member (always includes `occurrence`).
    let occurrence: MobileOccurrence
    let mergedOccurrences: [MobileOccurrence]
    let dayIndex: Int
    let frame: CGRect
    let startMinute: CGFloat
    let endMinute: CGFloat

    var mergedCount: Int { mergedOccurrences.count }
}

struct DayTimelineMoveTarget: Equatable {
    let dayIndex: Int
    let startMinute: CGFloat
    let frame: CGRect
    let start: Date?
    let end: Date?
}

final class DayTimelineDayCell: UIControl {
    let pill = UIView()
    let weekdayLabel = UILabel()
    let dayLabel = UILabel()
    let todayDot = UIView()
    var date = Date()

    // The active-day pill is drawn behind the whole visible run in the strip;
    // these constants keep the cell's number centered inside it and let the
    // strip lay the capsule out with the same geometry.
    static let pillTop: CGFloat = 21
    static let pillHeight: CGFloat = 37

    /// When true, the weekday and day number sit on one centered line with the
    /// highlight drawn as a capsule behind both (the compact multi-day header).
    var singleLine = false {
        didSet { if singleLine != oldValue { setNeedsLayout() } }
    }
    /// Capsule shown behind the single-line content for highlighted days.
    var showsPill = false
    var pillColor: UIColor = .clear

    override init(frame: CGRect) {
        super.init(frame: frame)
        pill.isUserInteractionEnabled = false
        pill.layer.cornerCurve = .continuous
        pill.isHidden = true
        addSubview(pill)
        addSubview(weekdayLabel)
        addSubview(dayLabel)
        addSubview(todayDot)
        weekdayLabel.textAlignment = .center
        weekdayLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        dayLabel.textAlignment = .center
        dayLabel.font = .systemFont(ofSize: 18, weight: .medium)
        todayDot.isUserInteractionEnabled = false
        todayDot.layer.cornerCurve = .continuous
        todayDot.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if singleLine {
            layoutSingleLine()
            return
        }
        pill.isHidden = true
        weekdayLabel.frame = CGRect(x: 0, y: 6, width: bounds.width, height: 12)
        dayLabel.frame = CGRect(x: 0, y: Self.pillTop, width: bounds.width, height: Self.pillHeight)
        let dotSize: CGFloat = 5
        todayDot.frame = CGRect(
            x: (bounds.width - dotSize) / 2,
            y: Self.pillTop + Self.pillHeight + 1,
            width: dotSize,
            height: dotSize
        )
        todayDot.layer.cornerRadius = dotSize / 2
    }

    /// "Tue 9" on a single centered row, with the highlight capsule sized to
    /// hug the weekday + number group.
    private func layoutSingleLine() {
        todayDot.isHidden = true
        let gap: CGFloat = 5
        weekdayLabel.sizeToFit()
        dayLabel.sizeToFit()
        let weekdayWidth = ceil(weekdayLabel.bounds.width)
        let dayWidth = ceil(dayLabel.bounds.width)
        let contentWidth = weekdayWidth + gap + dayWidth
        let centerX = bounds.width / 2
        let centerY = bounds.height / 2
        let groupLeft = (centerX - contentWidth / 2).rounded()

        weekdayLabel.frame = CGRect(x: groupLeft, y: 0, width: weekdayWidth, height: bounds.height)
        dayLabel.frame = CGRect(x: groupLeft + weekdayWidth + gap, y: 0, width: dayWidth, height: bounds.height)

        let pillHeight: CGFloat = 26
        let pillWidth = contentWidth + 20
        pill.frame = CGRect(
            x: (centerX - pillWidth / 2).rounded(),
            y: (centerY - pillHeight / 2).rounded(),
            width: pillWidth,
            height: pillHeight
        )
        pill.layer.cornerRadius = pillHeight / 2
        pill.backgroundColor = pillColor
        pill.isHidden = !showsPill
    }
}

final class DayTimelineEventBlockView: UIControl {
    let timeLabel = UILabel()
    private var titleLabels: [UILabel] = []
    let borderLine = UIView()
    var laid: DayTimelineLaidOccurrence?
    var onTap: ((MobileOccurrence) -> Void)?
    private var occurrence: MobileOccurrence?
    private var theme: KnotQTheme?
    private var timeFormat = "twelve_hour"

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(timeLabel)
        addSubview(borderLine)
        timeLabel.textAlignment = .center
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        timeLabel.lineBreakMode = .byTruncatingTail
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(laid: DayTimelineLaidOccurrence, theme: KnotQTheme, timeFormat: String) {
        self.laid = laid
        self.occurrence = laid.occurrence
        self.theme = theme
        self.timeFormat = timeFormat
        // Dim the whole block only when every merged item is done, mirroring the
        // desktop calendar block (`any_done`).
        alpha = laid.mergedOccurrences.allSatisfy(\.done) ? 0.55 : 1
        // One title row per merged occurrence: same-time items (duplicates, or
        // distinct events/tasks booked together) stack as their own rows under a
        // single shared time header — mirroring the desktop calendar's
        // `equal_groups` block — instead of collapsing into a "+N" badge.
        rebuildTitleLabels(count: laid.mergedOccurrences.count)
        for (label, member) in zip(titleLabels, laid.mergedOccurrences) {
            let title = member.title.trimmingCharacters(in: .whitespacesAndNewlines)
            label.text = title.isEmpty ? member.kind.capitalized : title
            label.textColor = Self.itemTextColor(for: member, done: member.done, dark: theme.isDark)
        }
        timeLabel.text = MobileDate.compactOccurrenceLabel(laid.occurrence, timeFormat: timeFormat)
        timeLabel.textColor = Self.timeColor(for: laid.occurrence, theme: theme)
        let isPill = laid.occurrence.kind == "reminder" || laid.occurrence.kind == "assignment"
        backgroundColor = theme.isDark
            ? UIColor(hex: 0x333333).withAlphaComponent(0.94)
            : UIColor(hex: 0xe6e8ec).withAlphaComponent(0.62)
        layer.cornerRadius = isPill ? 0 : 3
        layer.borderWidth = isPill ? 0 : 1.5
        layer.borderColor = (theme.isDark ? UIColor.white.withAlphaComponent(0.78) : UIColor(hex: 0x24272d).withAlphaComponent(0.80)).cgColor
        borderLine.backgroundColor = theme.isDark ? UIColor.white.withAlphaComponent(0.78) : UIColor(hex: 0x24272d).withAlphaComponent(0.80)
        borderLine.isHidden = !isPill
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let occurrence else { return }
        let hideTime = Self.hideTime(for: occurrence)
        let isReminder = occurrence.kind == "reminder"
        let isAssignment = occurrence.kind == "assignment"
        let topPadding: CGFloat = isReminder ? 6 : (isAssignment ? 3 : (hideTime ? 1 : 3))
        borderLine.frame = isReminder
            ? CGRect(x: 0, y: 0, width: bounds.width, height: 2)
            : CGRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2)
        let showTime = !hideTime && !(timeLabel.text?.isEmpty ?? true)
        let titleHeight: CGFloat = showTime ? 16 : 15
        let titleFont: UIFont = .systemFont(ofSize: showTime ? 12 : 11, weight: .bold)
        let labelWidth = max(0, bounds.width - 12)
        var y = topPadding
        if showTime {
            timeLabel.isHidden = false
            timeLabel.frame = CGRect(x: 6, y: y, width: labelWidth, height: 12)
            y += 12
        } else {
            timeLabel.isHidden = true
        }
        for label in titleLabels {
            label.font = titleFont
            label.frame = CGRect(x: 6, y: y, width: labelWidth, height: titleHeight)
            y += titleHeight
        }
    }

    /// Grows or shrinks the pool of stacked title rows to match the merged count.
    private func rebuildTitleLabels(count: Int) {
        let target = max(1, count)
        while titleLabels.count < target {
            let label = UILabel()
            label.textAlignment = .center
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
            titleLabels.append(label)
        }
        while titleLabels.count > target {
            titleLabels.removeLast().removeFromSuperview()
        }
    }

    /// Height needed to show the time header (when present) plus one title row
    /// per merged occurrence, so a block holding several same-time items grows
    /// to fit every row instead of clipping them.
    static func contentHeight(for occurrence: MobileOccurrence, mergedCount: Int, timeFormat: String) -> CGFloat {
        let hideTime = hideTime(for: occurrence)
        let isReminder = occurrence.kind == "reminder"
        let isAssignment = occurrence.kind == "assignment"
        let topPadding: CGFloat = isReminder ? 6 : (isAssignment ? 3 : (hideTime ? 1 : 3))
        let timeText = MobileDate.compactOccurrenceLabel(occurrence, timeFormat: timeFormat)
        let showTime = !hideTime && !timeText.isEmpty
        let titleHeight: CGFloat = showTime ? 16 : 15
        let rows = CGFloat(max(1, mergedCount))
        return topPadding + (showTime ? 12 : 0) + titleHeight * rows + 3
    }

    @objc private func tapped() {
        guard let occurrence else { return }
        onTap?(occurrence)
    }

    private static func hideTime(for occurrence: MobileOccurrence) -> Bool {
        guard occurrence.kind == "event",
              let start = MobileDate.parseDateTime(occurrence.start),
              let end = MobileDate.parseDateTime(occurrence.end) else {
            return false
        }
        return end.timeIntervalSince(start) <= 30 * 60
    }

    private static func timeColor(for occurrence: MobileOccurrence, theme: KnotQTheme) -> UIColor {
        guard !occurrence.done,
              let start = MobileDate.parseDateTime(occurrence.start ?? occurrence.end) else {
            return theme.isDark
                ? UIColor(hex: 0xe8edf2).withAlphaComponent(0.90)
                : UIColor(hex: 0x2e291f).withAlphaComponent(0.90)
        }
        let now = Date()
        if let end = MobileDate.parseDateTime(occurrence.end), start <= now, end > now {
            return theme.isDark ? UIColor(hex: 0xbfbfff) : UIColor(hex: 0x2f67cf)
        }
        if start < now {
            return theme.isDark ? UIColor(hex: 0xff5a53) : UIColor(hex: 0xd20f39)
        }
        let startDay = Calendar.current.startOfDay(for: start)
        let today = Calendar.current.startOfDay(for: now)
        let dayDiff = Calendar.current.dateComponents([.day], from: today, to: startDay).day ?? 0
        if dayDiff <= 0 {
            return theme.isDark ? UIColor(hex: 0xbfbfff) : UIColor(hex: 0x2f67cf)
        }
        if dayDiff <= 1 {
            return theme.isDark ? UIColor(hex: 0xe5e5ff) : UIColor(hex: 0x4f5f8f)
        }
        return theme.isDark
            ? UIColor(hex: 0xe8edf2).withAlphaComponent(0.90)
            : UIColor(hex: 0x2e291f).withAlphaComponent(0.90)
    }

    private static func itemTextColor(for occurrence: MobileOccurrence, done: Bool, dark: Bool) -> UIColor {
        let darkPalette: [(CGFloat, CGFloat, CGFloat)] = [
            (1.00, 0.270, 0.227), (1.00, 0.624, 0.039), (0.188, 0.820, 0.345),
            (0.039, 0.518, 1.000), (0.749, 0.353, 0.949), (1.000, 0.839, 0.039),
        ]
        let lightPalette: [(CGFloat, CGFloat, CGFloat)] = [
            (0.831, 0.153, 0.110), (0.769, 0.455, 0.000), (0.118, 0.620, 0.251),
            (0.000, 0.392, 0.824), (0.541, 0.239, 0.710), (0.878, 0.659, 0.000),
        ]
        let rgb: (CGFloat, CGFloat, CGFloat)
        if occurrence.schemeName == dailyQueueDisplayName {
            rgb = dark
                ? (0.722, 0.788, 0.910)
                : (0.353, 0.478, 0.678)
        } else {
            let palette = dark ? darkPalette : lightPalette
            rgb = palette[Int(occurrence.colorIndex) % palette.count]
        }
        let amount: CGFloat = done ? (dark ? 0.35 : 0.45) : (dark ? 0.70 : 0.90)
        let luma = rgb.0 * 0.299 + rgb.1 * 0.587 + rgb.2 * 0.114
        return UIColor(
            red: luma + (rgb.0 - luma) * amount,
            green: luma + (rgb.1 - luma) * amount,
            blue: luma + (rgb.2 - luma) * amount,
            alpha: done ? 0.78 : 1
        )
    }
}

final class DayTimelineStickyIndicatorView: UIControl {
    private let dotView = UIView()
    private let titleLabel = UILabel()
    private var occurrence: MobileOccurrence?
    var onTap: ((MobileOccurrence) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerRadius = 13
        layer.cornerCurve = .continuous
        addSubview(dotView)
        addSubview(titleLabel)
        dotView.isUserInteractionEnabled = false
        dotView.layer.cornerRadius = 3.5
        dotView.layer.cornerCurve = .continuous
        titleLabel.isUserInteractionEnabled = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(occurrence: MobileOccurrence, theme: KnotQTheme) {
        self.occurrence = occurrence
        let title = occurrence.title.trimmingCharacters(in: .whitespacesAndNewlines)
        titleLabel.text = title.isEmpty ? occurrence.kind.capitalized : title
        titleLabel.textColor = UIColor(theme.textPrimary)
        dotView.backgroundColor = UIColor(occurrenceSchemeColor(occurrence, dark: theme.isDark))
        backgroundColor = theme.isDark
            ? UIColor(hex: 0x333333).withAlphaComponent(0.92)
            : UIColor(theme.bgApp).withAlphaComponent(0.86)
        layer.borderWidth = 0.75
        layer.borderColor = theme.isDark
            ? UIColor.white.withAlphaComponent(0.18).cgColor
            : UIColor(theme.dividerSoft).cgColor
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dotView.frame = CGRect(x: 9, y: (bounds.height - 7) / 2, width: 7, height: 7)
        titleLabel.frame = CGRect(x: 22, y: 0, width: max(0, bounds.width - 30), height: bounds.height)
    }

    @objc private func tapped() {
        guard let occurrence else { return }
        onTap?(occurrence)
    }
}
