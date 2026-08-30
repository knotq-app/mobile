import SwiftUI
import UIKit

/// Builds the timeline's lookup table once per calendar snapshot. A recurring
/// occurrence can be represented in more than one source day while a snapshot
/// changes; retain the original first-seen ordering but show it once per local
/// day, matching the renderer's previous behavior.
func timelineOccurrencesByLocalDay(_ calendar: MobileCalendar?) -> [String: [MobileOccurrence]] {
    guard let calendar else { return [:] }
    var seenByDay: [String: Set<String>] = [:]
    var result: [String: [MobileOccurrence]] = [:]
    for occurrence in calendar.days.flatMap(\.occurrences) {
        guard let day = occurrence.localAnchorDateKey else { continue }
        guard seenByDay[day, default: []].insert(occurrence.id).inserted else { continue }
        result[day, default: []].append(occurrence)
    }
    return result
}

extension DayTimelineUIKitView {
    func visibleDayCount() -> Int {
        if let preferredVisibleDays {
            return max(2, min(7, preferredVisibleDays))
        }
        return bounds.width >= 620 ? 3 : 2
    }

    func visibleDayKeys() -> Set<String> {
        Set((0..<visibleDayCount()).map { AppModel.dateOnly(dayDate($0)) })
    }

    func dayDate(_ index: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: index, to: selectedDate) ?? selectedDate
    }

    func occurrences(forDayIndex index: Int) -> [MobileOccurrence] {
        let key = AppModel.dateOnly(dayDate(index))
        return occurrencesByLocalDay[key] ?? []
    }

    func minuteOfDay(_ raw: String?) -> CGFloat? {
        guard let date = MobileDate.parseDateTime(raw) else { return nil }
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return CGFloat((components.hour ?? 0) * 60 + (components.minute ?? 0))
    }

    func rubberBand(_ value: CGFloat, limit: CGFloat) -> CGFloat {
        let magnitude = abs(value)
        let sign: CGFloat = value < 0 ? -1 : 1
        if magnitude <= limit { return value }
        return sign * (limit + (magnitude - limit) * 0.18)
    }

    func hasToday() -> Bool {
        (-1...visibleDayCount()).contains { isToday(dayDate($0)) }
    }

    func isToday(_ date: Date) -> Bool {
        AppModel.dateOnly(date) == AppModel.dateOnly(Date())
    }

    func weekStart(for date: Date) -> Date {
        let weekday = Calendar.current.component(.weekday, from: date)
        return Calendar.current.date(byAdding: .day, value: -(weekday - 1), to: Calendar.current.startOfDay(for: date)) ?? date
    }

    func monthTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }

    func weekdayInitial(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEEE"
        return formatter.string(from: date).uppercased()
    }

    func weekdayShort(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: date).uppercased()
    }

    func dayNumber(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: date)
    }

    func hourLabel(_ hour: Int) -> String {
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
