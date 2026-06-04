import SwiftUI

enum RepeatChoice: String, CaseIterable, Identifiable {
    case none, daily, weekly, monthly, yearly
    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "Never"
        case .daily: "Every Day"
        case .weekly: "Every Week"
        case .monthly: "Every Month"
        case .yearly: "Every Year"
        }
    }

    var rrule: String? {
        rrule(weekdays: Set<RepeatWeekdayChoice>())
    }

    func rrule(weekdays: Set<RepeatWeekdayChoice>) -> String? {
        switch self {
        case .none:
            return nil
        case .daily:
            return "FREQ=DAILY;INTERVAL=1"
        case .weekly:
            let codes = RepeatWeekdayChoice.orderedCodes(weekdays)
            if codes.isEmpty { return "FREQ=WEEKLY;INTERVAL=1" }
            return "FREQ=WEEKLY;INTERVAL=1;BYDAY=\(codes.joined(separator: ","))"
        case .monthly:
            return "FREQ=MONTHLY;INTERVAL=1"
        case .yearly:
            return "FREQ=YEARLY;INTERVAL=1"
        }
    }

    static func from(rrule: String?) -> RepeatChoice {
        guard let rrule = rrule?.uppercased() else { return .none }
        if rrule.contains("FREQ=DAILY") { return .daily }
        if rrule.contains("FREQ=WEEKLY") { return .weekly }
        if rrule.contains("FREQ=MONTHLY") { return .monthly }
        if rrule.contains("FREQ=YEARLY") { return .yearly }
        return .none
    }
}

struct CalendarSchemePicker: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: String?
    let theme: KnotQTheme

    var body: some View {
        Picker("Scheme", selection: $selection) {
            calendarSchemeRow(name: "Daily", color: dailyQueueColor(dark: theme.isDark))
                .tag(String?.none)
            ForEach(model.snapshot?.schemes.filter { !$0.isDailyQueue && !$0.isReadOnly } ?? []) { scheme in
                calendarSchemeRow(name: scheme.displayName, color: schemeColor(scheme.colorIndex, dark: theme.isDark))
                    .tag(String?.some(scheme.id))
            }
        }
        .pickerStyle(.navigationLink)
    }
}

struct ScheduledDateFields: View {
    @Binding var kind: CalendarKind
    @Binding var hasStart: Bool
    @Binding var hasEnd: Bool
    @Binding var start: Date
    @Binding var end: Date
    var disabled = false

    var body: some View {
        CalendarKindSelector(selection: $kind, disabled: disabled)

        if hasStart {
            DatePicker(hasEnd ? "Start" : "At", selection: $start)
                .disabled(disabled)
                .onChange(of: start) { _, value in
                    if hasEnd, end < value { end = value.addingTimeInterval(3600) }
                }
        }
        if hasEnd {
            DatePicker(hasStart ? "End" : "Due", selection: $end, in: (hasStart ? start : Date.distantPast)...)
                .disabled(disabled)
        }
    }
}

struct NotificationLeadTimePicker: View {
    @Binding var selection: Int32
    var disabled = false

    var body: some View {
        Picker("Notification", selection: $selection) {
            ForEach(occurrenceNotificationOptionsIncluding(selection)) { option in
                Text(option.label).tag(option.offsetSecs)
            }
        }
        .disabled(disabled)
    }
}

struct RepeatRulePicker: View {
    @Binding var selection: RepeatChoice
    @Binding var weekdays: Set<RepeatWeekdayChoice>
    let anchorDate: Date
    var disabled = false

    var body: some View {
        Picker("Repeat", selection: $selection) {
            ForEach(RepeatChoice.allCases) { choice in
                Text(choice.label).tag(choice)
            }
        }
        .disabled(disabled)
        .onChange(of: selection) { _, choice in
            if choice == .weekly, weekdays.isEmpty {
                weekdays = [RepeatWeekdayChoice.defaultFor(date: anchorDate)]
            }
        }
        if selection == .weekly {
            WeeklyRepeatDaysPicker(selection: $weekdays, disabled: disabled)
        }
    }
}

private func calendarSchemeRow(name: String, color: Color) -> some View {
    HStack(spacing: 8) {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
        Text(name)
    }
}
