import Foundation

enum MobileDate {
    private static func dateOnlyFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func shortDayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }

    private static func fullDayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter
    }

    private static func timeFormatter(timeFormat: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if timeFormat == "twenty_four_hour" {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "h:mm a"
        }
        return formatter
    }

    private static func compactTimeFormatter(timeFormat: String, includePeriod: Bool) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = timeFormat == "twenty_four_hour" ? "HH:mm" : (includePeriod ? "h:mm a" : "h:mm")
        return formatter
    }

    private static func isoFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    static func formatDay(_ raw: String) -> String {
        guard let date = parseDateOnly(raw) else { return raw }
        return shortDayFormatter().string(from: date)
    }

    static func dateOnly(_ date: Date) -> String {
        dateOnlyFormatter().string(from: date)
    }

    static func parseDateOnly(_ raw: String) -> Date? {
        dateOnlyFormatter().date(from: raw)
    }

    static func displayDate(_ raw: String) -> String {
        guard let date = parseDateOnly(raw) else { return raw }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    static func formatFullDay(_ raw: String) -> String {
        guard let date = parseDateOnly(raw) else { return raw }
        return fullDayFormatter().string(from: date)
    }

    static func formatTime(_ raw: String?, timeFormat: String = "twelve_hour") -> String? {
        guard let raw, let date = isoFormatter().date(from: raw) else { return nil }
        return timeFormatter(timeFormat: timeFormat).string(from: date)
    }

    static func formatCompactTime(_ raw: String?, timeFormat: String, includePeriod: Bool) -> String? {
        guard let raw, let date = isoFormatter().date(from: raw) else { return nil }
        return compactTimeFormatter(timeFormat: timeFormat, includePeriod: includePeriod).string(from: date)
    }

    static func parseDateTime(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return isoFormatter().date(from: raw)
    }

    static func annotationText(start: String?, end: String?, timeFormat: String) -> String? {
        let startDate = parseDateTime(start)
        let endDate = parseDateTime(end)
        switch (startDate, endDate) {
        case let (.some(startDate), .some(endDate)):
            let startText = annotationDateTime(startDate, previous: nil, timeFormat: timeFormat)
            let endText = annotationDateTime(endDate, previous: startDate, timeFormat: timeFormat)
            return "\(startText) → \(endText)"
        case let (.some(startDate), .none):
            return "At \(annotationDateTime(startDate, previous: nil, timeFormat: timeFormat))"
        case let (.none, .some(endDate)):
            return "Due \(annotationDateTime(endDate, previous: nil, timeFormat: timeFormat))"
        default: return nil
        }
    }

    /// Mirrors the desktop editor's `format_annotation_datetime`: drop the day
    /// when it matches the paired date or is today, otherwise prefix the
    /// contextual date (e.g. "June 12 11:10 PM", with a year when it differs).
    private static func annotationDateTime(_ date: Date, previous: Date?, timeFormat: String) -> String {
        let calendar = Calendar.current
        let time = timeFormatter(timeFormat: timeFormat).string(from: date)
        if let previous, calendar.isDate(previous, inSameDayAs: date) {
            return time
        }
        if calendar.isDateInToday(date) {
            return time
        }
        return "\(contextualDate(date)) \(time)"
    }

    private static func contextualDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            formatter.dateFormat = "MMMM d"
        } else {
            formatter.dateFormat = "MMMM d, yyyy"
        }
        return formatter.string(from: date)
    }

    static func occurrenceLabel(_ occurrence: MobileOccurrence, timeFormat: String, showDay: Bool = false) -> String {
        if showDay {
            return occurrenceLabelWithDay(occurrence, timeFormat: timeFormat)
        }

        let start = formatTime(occurrence.start, timeFormat: timeFormat)
        let end = formatTime(occurrence.end, timeFormat: timeFormat)
        if occurrence.kind == "reminder", let start { return "At \(start)" }
        if occurrence.kind == "assignment", let end { return "Due \(end)" }
        if let start, let end { return "\(start) - \(end)" }
        if let start { return start }
        if let end { return "Due \(end)" }
        return occurrence.kind.capitalized
    }

    static func compactOccurrenceLabel(_ occurrence: MobileOccurrence, timeFormat: String) -> String {
        if occurrence.kind == "reminder", let start = formatTime(occurrence.start, timeFormat: timeFormat) {
            return "At \(start)"
        }
        if occurrence.kind == "assignment", let end = formatTime(occurrence.end, timeFormat: timeFormat) {
            return "Due \(end)"
        }
        let start = formatCompactTime(occurrence.start, timeFormat: timeFormat, includePeriod: false)
        let end = formatCompactTime(occurrence.end, timeFormat: timeFormat, includePeriod: true)
        if let start, let end { return "\(start) to \(end)" }
        if let start { return start }
        if let end { return "Due \(end)" }
        return ""
    }

    static func upcomingDatePrefix(date: Date) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: date)
        if target == today { return "" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today), target == tomorrow {
            return "Tomorrow"
        }
        if let inAWeek = calendar.date(byAdding: .day, value: 7, to: today), target < inAWeek && target > today {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE"
            return formatter.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private static func occurrenceLabelWithDay(_ occurrence: MobileOccurrence, timeFormat: String) -> String {
        if occurrence.kind == "reminder",
           let raw = occurrence.start,
           let date = parseDateTime(raw),
           let time = formatTime(raw, timeFormat: timeFormat)
        {
            let dayPrefix = upcomingDatePrefix(date: date)
            return dayPrefix.isEmpty ? "At \(time)" : "At \(dayPrefix) \(time)"
        }
        if occurrence.kind == "assignment",
           let raw = occurrence.end,
           let date = parseDateTime(raw),
           let time = formatTime(raw, timeFormat: timeFormat)
        {
            let dayPrefix = upcomingDatePrefix(date: date)
            return dayPrefix.isEmpty ? "Due \(time)" : "Due \(dayPrefix) \(time)"
        }
        if let rawStart = occurrence.start,
           let rawEnd = occurrence.end,
           let startDate = parseDateTime(rawStart),
           let endDate = parseDateTime(rawEnd),
           let startTime = formatTime(rawStart, timeFormat: timeFormat),
           let endTime = formatTime(rawEnd, timeFormat: timeFormat)
        {
            let from = upcomingDatePrefix(date: startDate)
            let to = upcomingDatePrefix(date: endDate)
            let fromText = from.isEmpty ? startTime : "\(from) \(startTime)"
            let toText = from == to ? endTime : (to.isEmpty ? endTime : "\(to) \(endTime)")
            return "\(fromText) → \(toText)"
        }
        if let rawStart = occurrence.start,
           let startDate = parseDateTime(rawStart),
           let startTime = formatTime(rawStart, timeFormat: timeFormat)
        {
            let dayPrefix = upcomingDatePrefix(date: startDate)
            return dayPrefix.isEmpty ? startTime : "\(dayPrefix) \(startTime)"
        }
        if let rawEnd = occurrence.end,
           let endDate = parseDateTime(rawEnd),
           let endTime = formatTime(rawEnd, timeFormat: timeFormat)
        {
            let dayPrefix = upcomingDatePrefix(date: endDate)
            return dayPrefix.isEmpty ? "Due \(endTime)" : "Due \(dayPrefix) \(endTime)"
        }
        return occurrence.kind.capitalized
    }
}
