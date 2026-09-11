import Foundation

enum MobileDate {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    // DateFormatter construction is surprisingly expensive and these helpers are
    // used from nearly every timeline and calendar cell. Keep one formatter per
    // thread: formatters are not documented as thread-safe, while this avoids a
    // lock on the rendering path. Locale/time-zone changes get a fresh key.
    private static func cachedDateFormatter(
        key: String,
        make: () -> DateFormatter
    ) -> DateFormatter {
        let cacheKey = "knotq.mobile-date.\(key)"
        let dictionary = Thread.current.threadDictionary
        if let formatter = dictionary[cacheKey] as? DateFormatter {
            return formatter
        }
        let formatter = make()
        dictionary[cacheKey] = formatter
        return formatter
    }

    private static func cachedISOFormatter(includeFractionalSeconds: Bool) -> ISO8601DateFormatter {
        let cacheKey = "knotq.mobile-date.iso.\(includeFractionalSeconds)"
        let dictionary = Thread.current.threadDictionary
        if let formatter = dictionary[cacheKey] as? ISO8601DateFormatter {
            return formatter
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = includeFractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        dictionary[cacheKey] = formatter
        return formatter
    }

    private static var currentLocaleKey: String {
        Locale.current.identifier
    }

    private static var currentTimeZoneKey: String {
        let timeZone = TimeZone.current
        return "\(timeZone.identifier)-\(timeZone.secondsFromGMT())"
    }

    private static func dateOnlyFormatter() -> DateFormatter {
        cachedDateFormatter(key: "date-only.\(currentTimeZoneKey)") {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = posixLocale
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter
        }
    }

    private static func shortDayFormatter() -> DateFormatter {
        cachedDateFormatter(key: "short-day.\(currentLocaleKey).\(currentTimeZoneKey)") {
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "MMM d"
            return formatter
        }
    }

    private static func fullDayFormatter() -> DateFormatter {
        cachedDateFormatter(key: "full-day.\(currentLocaleKey).\(currentTimeZoneKey)") {
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "EEEE, MMM d"
            return formatter
        }
    }

    private static func timeFormatter(timeFormat: String) -> DateFormatter {
        cachedDateFormatter(key: "time.\(timeFormat).\(currentTimeZoneKey)") {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = posixLocale
            formatter.timeZone = TimeZone.current
            if timeFormat == "twenty_four_hour" {
                formatter.dateFormat = "HH:mm"
            } else {
                formatter.dateFormat = "h:mm a"
            }
            return formatter
        }
    }

    private static func compactTimeFormatter(timeFormat: String, includePeriod: Bool) -> DateFormatter {
        cachedDateFormatter(key: "compact-time.\(timeFormat).\(includePeriod).\(currentTimeZoneKey)") {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = posixLocale
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = timeFormat == "twenty_four_hour" ? "HH:mm" : (includePeriod ? "h:mm a" : "h:mm")
            return formatter
        }
    }

    /// Parse both forms emitted by our Rust and backend layers. Foundation's
    /// ISO8601DateFormatter is unexpectedly strict about the formatter options:
    /// a fractional formatter rejects whole-second timestamps, while a plain
    /// formatter rejects millisecond timestamps. Keep both cached per thread so
    /// the common UI path stays cheap while sync/notification timestamps remain
    /// interoperable across implementations.
    private static func parseISO(_ raw: String) -> Date? {
        cachedISOFormatter(includeFractionalSeconds: true).date(from: raw)
            ?? cachedISOFormatter(includeFractionalSeconds: false).date(from: raw)
    }

    static func formatDay(_ raw: String) -> String {
        guard let date = parseDateOnly(raw) else { return raw }
        return shortDayFormatter().string(from: date)
    }

    static func dateOnly(_ date: Date) -> String {
        dateOnlyFormatter().string(from: date)
    }

    /// Formats a Date with a fixed display pattern using the current locale and
    /// time zone. This is used by dense UIKit grids where creating a formatter
    /// for every cell would otherwise show up in scrolling and relayout costs.
    static func format(_ date: Date, dateFormat: String) -> String {
        cachedDateFormatter(key: "custom.\(dateFormat).\(currentLocaleKey).\(currentTimeZoneKey)") {
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = dateFormat
            return formatter
        }.string(from: date)
    }

    static func parseDateOnly(_ raw: String) -> Date? {
        let formatter = dateOnlyFormatter()
        guard let date = formatter.date(from: raw), formatter.string(from: date) == raw else {
            // DateFormatter is lenient for date-only patterns: without this
            // round-trip check, values such as 2026-02-30 silently become a
            // different day and can poison Daily/calendar bucketing.
            return nil
        }
        return date
    }

    static func displayDate(_ raw: String) -> String {
        guard let date = parseDateOnly(raw) else { return raw }
        return displayDateFormatter().string(from: date)
    }

    static func formatFullDay(_ raw: String) -> String {
        guard let date = parseDateOnly(raw) else { return raw }
        return fullDayFormatter().string(from: date)
    }

    static func formatTime(_ raw: String?, timeFormat: String = "twelve_hour") -> String? {
        guard let raw, let date = parseISO(raw) else { return nil }
        return timeFormatter(timeFormat: timeFormat).string(from: date)
    }

    /// Formats an already-parsed date using the same stable clock style as
    /// the string-based occurrence helpers. Timeline drag feedback calls this
    /// repeatedly while the finger moves, so it must reuse the cached formatter.
    static func formatTime(_ date: Date, timeFormat: String = "twelve_hour") -> String {
        timeFormatter(timeFormat: timeFormat).string(from: date)
    }

    static func formatCompactTime(_ raw: String?, timeFormat: String, includePeriod: Bool) -> String? {
        guard let raw, let date = parseISO(raw) else { return nil }
        return compactTimeFormatter(timeFormat: timeFormat, includePeriod: includePeriod).string(from: date)
    }

    static func parseDateTime(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return parseISO(raw)
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
        let includesYear = calendar.component(.year, from: date) != calendar.component(.year, from: Date())
        return contextualDateFormatter(includesYear: includesYear).string(from: date)
    }

    private static func displayDateFormatter() -> DateFormatter {
        cachedDateFormatter(key: "display-date.\(currentLocaleKey).\(currentTimeZoneKey)") {
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.timeZone = TimeZone.current
            formatter.dateStyle = .medium
            return formatter
        }
    }

    private static func contextualDateFormatter(includesYear: Bool) -> DateFormatter {
        cachedDateFormatter(key: "contextual-date.\(includesYear).\(currentTimeZoneKey)") {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = posixLocale
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = includesYear ? "MMMM d, yyyy" : "MMMM d"
            return formatter
        }
    }

    private static func upcomingWeekdayFormatter() -> DateFormatter {
        cachedDateFormatter(key: "upcoming-weekday.\(currentTimeZoneKey)") {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = posixLocale
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "EEE"
            return formatter
        }
    }

    private static func upcomingMonthDayFormatter() -> DateFormatter {
        cachedDateFormatter(key: "upcoming-month-day.\(currentTimeZoneKey)") {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = posixLocale
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "MMM d"
            return formatter
        }
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
            return upcomingWeekdayFormatter().string(from: date)
        }
        return upcomingMonthDayFormatter().string(from: date)
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
