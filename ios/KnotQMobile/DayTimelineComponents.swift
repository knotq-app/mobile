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
            resetToken: resetToken
        )
    }
}


struct DayTimelineCreateDraft: Equatable {
    let dayIndex: Int
    let startMinute: CGFloat
}

struct DayTimelineLaidOccurrence {
    let occurrence: MobileOccurrence
    let dayIndex: Int
    let frame: CGRect
    let startMinute: CGFloat
    let endMinute: CGFloat
}

struct DayTimelineMoveTarget: Equatable {
    let dayIndex: Int
    let startMinute: CGFloat
    let frame: CGRect
    let start: Date?
    let end: Date?
}

final class DayTimelineDayCell: UIControl {
    let weekdayLabel = UILabel()
    let dayLabel = UILabel()
    let rangeBackground = UIView()
    var date = Date()
    var isTodayCell = false { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(rangeBackground)
        addSubview(weekdayLabel)
        addSubview(dayLabel)
        weekdayLabel.textAlignment = .center
        weekdayLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        dayLabel.textAlignment = .center
        dayLabel.font = .systemFont(ofSize: 18, weight: .medium)
        rangeBackground.isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        weekdayLabel.frame = CGRect(x: 0, y: 3, width: bounds.width, height: 14)
        // Today is a compact circle (matching the month grid); a visible-day
        // pill spans the cell width.
        if isTodayCell {
            let diameter: CGFloat = 34
            rangeBackground.frame = CGRect(x: (bounds.width - diameter) / 2, y: 23, width: diameter, height: diameter)
        } else {
            rangeBackground.frame = CGRect(x: 5, y: 23, width: max(0, bounds.width - 10), height: 34)
        }
        rangeBackground.layer.cornerRadius = 17
        rangeBackground.layer.cornerCurve = .continuous
        dayLabel.frame = CGRect(x: 0, y: 23, width: bounds.width, height: 34)
    }
}

final class DayTimelineEventBlockView: UIControl {
    let timeLabel = UILabel()
    let titleLabel = UILabel()
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
        addSubview(titleLabel)
        addSubview(borderLine)
        timeLabel.textAlignment = .center
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        timeLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textAlignment = .center
        titleLabel.font = .systemFont(ofSize: 11, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail
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
        alpha = laid.occurrence.done ? 0.55 : 1
        let title = laid.occurrence.title.trimmingCharacters(in: .whitespacesAndNewlines)
        titleLabel.text = title.isEmpty ? laid.occurrence.kind.capitalized : title
        timeLabel.text = Self.timeLabel(for: laid.occurrence, timeFormat: timeFormat)
        titleLabel.textColor = Self.itemTextColor(for: laid.occurrence, done: laid.occurrence.done, dark: theme.isDark)
        timeLabel.textColor = Self.timeColor(for: laid.occurrence, theme: theme)
        let isPill = laid.occurrence.kind == "reminder" || laid.occurrence.kind == "assignment"
        backgroundColor = theme.isDark
            ? UIColor(hex: 0x232426).withAlphaComponent(0.66)
            : UIColor(hex: 0xe6e8ec).withAlphaComponent(0.62)
        layer.cornerRadius = isPill ? 0 : 3
        layer.borderWidth = isPill ? 0 : 1.5
        layer.borderColor = (theme.isDark ? UIColor.white.withAlphaComponent(0.84) : UIColor(hex: 0x24272d).withAlphaComponent(0.80)).cgColor
        borderLine.backgroundColor = theme.isDark ? UIColor.white.withAlphaComponent(0.84) : UIColor(hex: 0x24272d).withAlphaComponent(0.80)
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
        if hideTime || timeLabel.text?.isEmpty == true {
            timeLabel.isHidden = true
            titleLabel.font = .systemFont(ofSize: 10, weight: .bold)
            titleLabel.frame = CGRect(x: 6, y: topPadding, width: max(0, bounds.width - 12), height: 14)
        } else {
            timeLabel.isHidden = false
            titleLabel.font = .systemFont(ofSize: 11, weight: .bold)
            timeLabel.frame = CGRect(x: 6, y: topPadding, width: max(0, bounds.width - 12), height: 11)
            titleLabel.frame = CGRect(x: 6, y: topPadding + 11, width: max(0, bounds.width - 12), height: 15)
        }
    }

    @objc private func tapped() {
        guard let occurrence else { return }
        onTap?(occurrence)
    }

    private static func timeLabel(for occurrence: MobileOccurrence, timeFormat: String) -> String {
        if occurrence.kind == "reminder", let start = MobileDate.formatTime(occurrence.start, timeFormat: timeFormat) {
            return "At \(start)"
        }
        if occurrence.kind == "assignment", let end = MobileDate.formatTime(occurrence.end, timeFormat: timeFormat) {
            return "Due \(end)"
        }
        let start = formatEventTime(occurrence.start, timeFormat: timeFormat, includePeriod: false)
        let end = formatEventTime(occurrence.end, timeFormat: timeFormat, includePeriod: true)
        if let start, let end { return "\(start) to \(end)" }
        if let start { return start }
        if let end { return "Due \(end)" }
        return ""
    }

    private static func formatEventTime(_ raw: String?, timeFormat: String, includePeriod: Bool) -> String? {
        guard let date = MobileDate.parseDateTime(raw) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = timeFormat == "twenty_four_hour" ? "HH:mm" : (includePeriod ? "h:mm a" : "h:mm")
        return formatter.string(from: date)
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
