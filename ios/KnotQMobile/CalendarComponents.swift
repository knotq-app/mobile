import SwiftUI
import UIKit

struct UpcomingSection: View {
    let title: String
    let empty: String
    let occurrences: [MobileOccurrence]
    let theme: KnotQTheme
    let timeFormat: String
    let onToggleOccurrence: (MobileOccurrence) -> Void
    let onOpenOccurrence: (MobileOccurrence) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textDim)
                .padding(.horizontal, 4)
            if occurrences.isEmpty {
                Text(empty)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(occurrences.enumerated()), id: \.element.id) { idx, occurrence in
                    OccurrenceCompactRow(
                        occurrence: occurrence,
                        theme: theme,
                        timeFormat: timeFormat,
                        striped: idx % 2 == 1,
                        moreAction: { onOpenOccurrence(occurrence) }
                    ) {
                        onToggleOccurrence(occurrence)
                    }
                }
            }
        }
    }
}

struct DesktopCalendarPane: View {
    let calendar: MobileCalendar?
    let theme: KnotQTheme
    let wide: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onToday: () -> Void
    let onAdd: () -> Void
    let timeFormat: String
    let onOpenScheme: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            CalendarToolbar(calendar: calendar, theme: theme, onPrevious: onPrevious, onNext: onNext, onToday: onToday, onAdd: onAdd)
            ScrollView([.vertical, wide ? .horizontal : []]) {
                VStack(alignment: .leading, spacing: 12) {
                    if let overdue = calendar?.overdue, !overdue.isEmpty {
                        CalendarListSection(title: "Overdue", occurrences: overdue, theme: theme, timeFormat: timeFormat, onOpenScheme: onOpenScheme)
                    }

                    if wide {
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(calendar?.visibleDays ?? []) { day in
                                CalendarDayColumn(day: day, theme: theme, timeFormat: timeFormat, onOpenScheme: onOpenScheme)
                                    .frame(width: 132)
                            }
                        }
                        .padding(.horizontal, 12)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(calendar?.visibleDays ?? []) { day in
                                CalendarDayColumn(day: day, theme: theme, timeFormat: timeFormat, onOpenScheme: onOpenScheme)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .background(theme.bgApp)
    }
}

// MARK: - DayTimelinePane (UIKit-backed Apple Calendar-style day timeline)


struct CalendarToolbar: View {
    let calendar: MobileCalendar?
    let theme: KnotQTheme
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onToday: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPrevious) { Image(systemName: "chevron.left") }
                .buttonStyle(TitleIconButton(theme: theme))
            VStack(alignment: .leading, spacing: 2) {
                Text(monthText)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textSoft)
                Text(rangeText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Button("Today", action: onToday)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textDim)
                    .buttonStyle(.plain)
            }
            Spacer()
            Button(action: onAdd) { Image(systemName: "calendar.badge.plus") }
                .buttonStyle(TitleIconButton(theme: theme))
            Button(action: onNext) { Image(systemName: "chevron.right") }
                .buttonStyle(TitleIconButton(theme: theme))
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(theme.bgApp)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.dividerSoft).frame(height: 1) }
    }

    private var rangeText: String {
        guard let calendar else { return "Calendar" }
        return "\(MobileDate.formatDay(calendar.startDate)) - \(MobileDate.formatDay(calendar.endDate))"
    }

    private var monthText: String {
        guard let start = calendar?.startDate,
              let date = AppModel.date(from: start) else {
            return "Week"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }
}

struct CalendarDayColumn: View {
    let day: MobileCalendarDay
    let theme: KnotQTheme
    let timeFormat: String
    let onOpenScheme: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(MobileDate.formatFullDay(day.date))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(day.date == AppModel.dateOnly(Date()) ? theme.textToday : theme.textDim)
                .lineLimit(1)
            if day.occurrences.isEmpty {
                Text("None")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(theme.rowAlt, in: RoundedRectangle(cornerRadius: 4))
            } else {
                ForEach(day.occurrences) { occurrence in
                    CalendarEventBlock(occurrence: occurrence, theme: theme, timeFormat: timeFormat) {
                        onOpenScheme(occurrence.schemeId)
                    }
                }
            }
        }
        .padding(8)
        .background(theme.bgModal.opacity(theme.isDark ? 0.35 : 0.45), in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(theme.dividerSoft, lineWidth: 1) }
    }
}

struct CalendarDayList: View {
    let day: MobileCalendarDay
    let theme: KnotQTheme
    let timeFormat: String
    let onOpenScheme: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(MobileDate.formatFullDay(day.date))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(day.date == AppModel.dateOnly(Date()) ? theme.textToday : theme.textDim)
            if day.occurrences.isEmpty {
                Text("No calendar items")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textMuted)
                    .padding(.vertical, 6)
            } else {
                ForEach(day.occurrences) { occurrence in
                    OccurrenceCompactRow(occurrence: occurrence, theme: theme, timeFormat: timeFormat, striped: false) {
                        onOpenScheme(occurrence.schemeId)
                    }
                }
            }
        }
    }
}

struct CalendarListSection: View {
    let title: String
    let occurrences: [MobileOccurrence]
    let theme: KnotQTheme
    let timeFormat: String
    let onOpenScheme: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.danger)
            ForEach(occurrences) { occurrence in
                OccurrenceCompactRow(occurrence: occurrence, theme: theme, timeFormat: timeFormat, striped: false) {
                    onOpenScheme(occurrence.schemeId)
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

struct CalendarEventBlock: View {
    let occurrence: MobileOccurrence
    let theme: KnotQTheme
    let timeFormat: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(occurrence.title.isEmpty ? occurrence.kind.capitalized : occurrence.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(3)
                    .strikethrough(occurrence.done)
                Text(occurrenceTimeLabel(occurrence, timeFormat: timeFormat))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textSoft)
                Text(occurrence.schemeName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(occurrenceSchemeColor(occurrence, dark: theme.isDark))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(7)
            .background(theme.isDark ? Color(hex: 0x333333).opacity(0.94) : Color(hex: 0xd3d2ce).opacity(0.86), in: RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(occurrenceSchemeColor(occurrence, dark: theme.isDark))
                    .frame(width: 2)
                    .padding(.vertical, 5)
            }
        }
        .buttonStyle(.plain)
        .opacity(occurrence.done ? 0.45 : 1)
    }
}

struct OccurrenceCompactRow: View {
    let occurrence: MobileOccurrence
    let theme: KnotQTheme
    let timeFormat: String
    let striped: Bool
    let moreAction: (() -> Void)?
    let action: () -> Void
    let showDayLabel: Bool
    let longPressDuration: Double

    init(
        occurrence: MobileOccurrence,
        theme: KnotQTheme,
        timeFormat: String,
        striped: Bool,
        showDayLabel: Bool = false,
        longPressDuration: Double = 0.25,
        moreAction: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) {
        self.occurrence = occurrence
        self.theme = theme
        self.timeFormat = timeFormat
        self.striped = striped
        self.moreAction = moreAction
        self.action = action
        self.showDayLabel = showDayLabel
        self.longPressDuration = longPressDuration
    }

    var body: some View {
        interactiveRow
            .opacity(occurrence.done ? 0.45 : 1)
    }

    @ViewBuilder
    private var interactiveRow: some View {
        if let moreAction {
            baseRow
                .overlay {
                    FastPressGestureOverlay(
                        longPressDuration: longPressDuration,
                        allowableMovement: 18,
                        tapAction: action,
                        longPressAction: {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            moreAction()
                        }
                    )
                }
        } else {
            baseRow
                .onTapGesture {
                    action()
                }
        }
    }

    private var baseRow: some View {
        rowContent
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    private var rowContent: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(occurrenceSchemeColor(occurrence, dark: theme.isDark))
                .frame(width: 1.5)
                .padding(.vertical, 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(occurrence.schemeName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(occurrenceSchemeColor(occurrence, dark: theme.isDark))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(occurrenceTimeLabel(occurrence, timeFormat: timeFormat, showDay: showDayLabel))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(occurrenceStatusTimeColor(occurrence, theme: theme))
                        .lineLimit(1)
                }
                Text(occurrence.title.isEmpty ? occurrence.kind.capitalized : occurrence.title)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                    .strikethrough(occurrence.done)
            }
            .padding(.vertical, 7)
            .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(striped ? theme.rowAlt : Color.clear, in: RoundedRectangle(cornerRadius: 3))
    }
}

private struct FastPressGestureOverlay: UIViewRepresentable {
    let longPressDuration: TimeInterval
    let allowableMovement: CGFloat
    let tapAction: () -> Void
    let longPressAction: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(tapAction: tapAction, longPressAction: longPressAction)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = longPressDuration
        longPress.allowableMovement = allowableMovement
        longPress.cancelsTouchesInView = false
        longPress.delaysTouchesBegan = false
        longPress.delaysTouchesEnded = false
        longPress.delegate = context.coordinator

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = context.coordinator
        tap.require(toFail: longPress)

        view.addGestureRecognizer(longPress)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.tapAction = tapAction
        context.coordinator.longPressAction = longPressAction

        for recognizer in view.gestureRecognizers ?? [] {
            if let longPress = recognizer as? UILongPressGestureRecognizer {
                longPress.minimumPressDuration = longPressDuration
                longPress.allowableMovement = allowableMovement
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var tapAction: () -> Void
        var longPressAction: () -> Void

        init(tapAction: @escaping () -> Void, longPressAction: @escaping () -> Void) {
            self.tapAction = tapAction
            self.longPressAction = longPressAction
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            tapAction()
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            longPressAction()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer
        }
    }
}
