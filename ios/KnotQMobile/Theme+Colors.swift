import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct KnotQTheme {
    let isDark: Bool
    let bgApp: Color
    let bgSidebar: Color
    let bgToolbar: Color
    let bgModal: Color
    let rowAlt: Color
    let rowHover: Color
    let rowSelected: Color
    let buttonBg: Color
    let divider: Color
    let dividerSoft: Color
    let dividerTiny: Color
    let borderOverlay: Color
    let textPrimary: Color
    let textDim: Color
    let textMuted: Color
    let textSoft: Color
    let textToday: Color
    let accent: Color
    let danger: Color

    static func resolve(mode: String?, systemScheme: ColorScheme) -> KnotQTheme {
        switch mode {
        case "light": .light
        case "system": systemScheme == .dark ? .dark : .light
        default: .dark
        }
    }

    // Desktop-matched dark: deep charcoal canvas with restrained raised surfaces,
    // bright text, red "today" accent.
    static let dark = KnotQTheme(
        isDark: true,
        bgApp: Color(hex: 0x18191a),
        bgSidebar: Color(hex: 0x1c1d1f),
        bgToolbar: Color(hex: 0x242527),
        bgModal: Color(hex: 0x202123),
        rowAlt: Color.white.opacity(0.03),
        rowHover: Color.white.opacity(0.06),
        rowSelected: Color.white.opacity(0.11),
        buttonBg: Color.white.opacity(0.065),
        divider: Color.white.opacity(0.10),
        dividerSoft: Color.white.opacity(0.065),
        dividerTiny: Color.white.opacity(0.035),
        borderOverlay: Color.white.opacity(0.11),
        textPrimary: Color(hex: 0xf2f2f7),
        textDim: Color(hex: 0xb4bcc4).opacity(0.74),
        textMuted: Color(hex: 0x98a0aa).opacity(0.55),
        textSoft: Color(hex: 0xd2dae2).opacity(0.64),
        textToday: Color(hex: 0xff453a),
        accent: Color(hex: 0x7aa0ff),
        danger: Color(hex: 0xff453a)
    )

    static let light = KnotQTheme(
        isDark: false,
        bgApp: Color(hex: 0xe8e2d8),
        bgSidebar: Color(hex: 0xe0d8cc),
        bgToolbar: Color(hex: 0xe3dcd2),
        bgModal: Color(hex: 0xece6dd),
        rowAlt: Color(hex: 0x5a4635).opacity(0.047),
        rowHover: Color(hex: 0x5a4635).opacity(0.094),
        rowSelected: Color(hex: 0xe66f1f).opacity(0.102),
        buttonBg: Color(hex: 0x5a4635).opacity(0.094),
        divider: Color(hex: 0x5a4635).opacity(0.141),
        dividerSoft: Color(hex: 0x5a4635).opacity(0.094),
        dividerTiny: Color(hex: 0x5a4635).opacity(0.051),
        borderOverlay: Color(hex: 0x3d2a18).opacity(0.188),
        textPrimary: Color(hex: 0x2c2420),
        textDim: Color(hex: 0x302520).opacity(0.878),
        textMuted: Color(hex: 0x5a4a3c).opacity(0.753),
        textSoft: Color(hex: 0x382c22).opacity(0.847),
        textToday: Color(hex: 0xd04e1a),
        accent: Color(hex: 0xc04510),
        danger: Color(hex: 0xc72f24)
    )
}

let dailyQueueDisplayName = "Daily"

func dailyQueueColor(dark: Bool) -> Color {
    dark ? Color(hex: 0xb8c9e8) : Color(hex: 0x5a7aad)
}

func isDailyQueueOccurrence(_ occurrence: MobileOccurrence) -> Bool {
    occurrence.schemeName == dailyQueueDisplayName
}

func occurrenceSchemeColor(_ occurrence: MobileOccurrence, dark: Bool) -> Color {
    isDailyQueueOccurrence(occurrence)
        ? dailyQueueColor(dark: dark)
        : schemeColor(occurrence.colorIndex, dark: dark)
}

func searchHitColor(_ hit: MobileSearchHit, dark: Bool) -> Color {
    if hit.targetKind == "daily_queue" || hit.status == "daily_queue" || hit.schemeName == dailyQueueDisplayName {
        return dailyQueueColor(dark: dark)
    }
    return schemeColor(hit.colorIndex ?? 0, dark: dark)
}


extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xff) / 255.0,
            green: CGFloat((hex >> 8) & 0xff) / 255.0,
            blue: CGFloat(hex & 0xff) / 255.0,
            alpha: 1
        )
    }
}


func occurrenceTimeLabel(_ occurrence: MobileOccurrence, timeFormat: String) -> String {
    return occurrenceTimeLabel(occurrence, timeFormat: timeFormat, showDay: false)
}

func occurrenceTimeLabel(_ occurrence: MobileOccurrence, timeFormat: String, showDay: Bool) -> String {
    let start = MobileDate.formatTime(occurrence.start, timeFormat: timeFormat)
    let end = MobileDate.formatTime(occurrence.end, timeFormat: timeFormat)
    if !showDay {
        if occurrence.kind == "reminder", let start { return "At \(start)" }
        if occurrence.kind == "assignment", let end { return "Due \(end)" }
        if let start, let end { return "\(start) - \(end)" }
        if let start { return start }
        if let end { return "Due \(end)" }
        return occurrence.kind.capitalized
    }

    if occurrence.kind == "reminder", let raw = occurrence.start, let date = MobileDate.parseDateTime(raw) {
        if let rawTime = upcomingTimeLabel(raw: raw, timeFormat: timeFormat) {
            let dayPrefix = upcomingDatePrefix(date: date)
            return dayPrefix.isEmpty ? "At \(rawTime)" : "At \(dayPrefix) \(rawTime)"
        }
    }
    if occurrence.kind == "assignment", let raw = occurrence.end, let date = MobileDate.parseDateTime(raw) {
        if let rawTime = upcomingTimeLabel(raw: raw, timeFormat: timeFormat) {
            let dayPrefix = upcomingDatePrefix(date: date)
            return dayPrefix.isEmpty ? "Due \(rawTime)" : "Due \(dayPrefix) \(rawTime)"
        }
    }
    if let rawStart = occurrence.start, let rawEnd = occurrence.end,
       let startDate = MobileDate.parseDateTime(rawStart),
       let endDate = MobileDate.parseDateTime(rawEnd),
       let startTime = upcomingTimeLabel(raw: rawStart, timeFormat: timeFormat),
       let endTime = upcomingTimeLabel(raw: rawEnd, timeFormat: timeFormat)
    {
        let from = upcomingDatePrefix(date: startDate)
        let to = upcomingDatePrefix(date: endDate)
        let fromText = from.isEmpty ? startTime : "\(from) \(startTime)"
        let toText = from == to ? endTime : (to.isEmpty ? endTime : "\(to) \(endTime)")
        return "\(fromText) → \(toText)"
    }
    if let rawStart = occurrence.start, let startDate = MobileDate.parseDateTime(rawStart), let startTime = upcomingTimeLabel(raw: rawStart, timeFormat: timeFormat) {
        let dayPrefix = upcomingDatePrefix(date: startDate)
        return dayPrefix.isEmpty ? startTime : "\(dayPrefix) \(startTime)"
    }
    if let rawEnd = occurrence.end, let endDate = MobileDate.parseDateTime(rawEnd), let endTime = upcomingTimeLabel(raw: rawEnd, timeFormat: timeFormat) {
        let dayPrefix = upcomingDatePrefix(date: endDate)
        return dayPrefix.isEmpty ? "Due \(endTime)" : "Due \(dayPrefix) \(endTime)"
    }
    return occurrence.kind.capitalized
}

func upcomingTimeLabel(raw: String, timeFormat: String) -> String? {
    guard let date = MobileDate.parseDateTime(raw) else { return nil }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    if timeFormat == "twenty_four_hour" {
        formatter.dateFormat = "HH:mm"
    } else {
        formatter.dateFormat = "h:mm a"
    }
    return formatter.string(from: date)
}

func upcomingDatePrefix(date: Date) -> String {
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

func occurrenceStatusTimeColor(_ occurrence: MobileOccurrence, theme: KnotQTheme) -> Color {
    guard !occurrence.done else { return theme.textMuted }
    let now = Date()
    let anchorRaw = occurrence.kind == "assignment"
        ? occurrence.end
        : (occurrence.start ?? occurrence.end)
    guard let anchorRaw, let anchor = MobileDate.parseDateTime(anchorRaw) else {
        return theme.textSoft
    }
    if occurrence.kind == "event",
       let end = MobileDate.parseDateTime(occurrence.end),
       anchor <= now,
       end > now {
        return theme.isDark ? Color(hex: 0xbfbfff) : Color(hex: 0x2f67cf)
    }
    if anchor < now {
        return theme.isDark ? Color(hex: 0xff5a53) : Color(hex: 0xd20f39)
    }
    let startDay = Calendar.current.startOfDay(for: anchor)
    let today = Calendar.current.startOfDay(for: now)
    let dayDiff = Calendar.current.dateComponents([.day], from: today, to: startDay).day ?? 0
    if dayDiff <= 0 {
        return theme.isDark ? Color(hex: 0xbfbfff) : Color(hex: 0x2f67cf)
    }
    if dayDiff <= 1 {
        return theme.isDark ? Color(hex: 0xe5e5ff) : Color(hex: 0x4f5f8f)
    }
    return theme.textSoft
}

func schemeColor(_ index: Int32, dark: Bool) -> Color {
    let darkPalette: [UInt32] = [0xff453a, 0xff9f0a, 0x30d158, 0x0a84ff, 0xbf5af2, 0xffd60a]
    let lightPalette: [UInt32] = [0xd4271c, 0xc47400, 0x1e9e40, 0x0064d2, 0x8a3db5, 0xe0a800]
    let palette = dark ? darkPalette : lightPalette
    return Color(hex: palette[Int(index) % palette.count])
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255.0,
            green: Double((hex >> 8) & 0xff) / 255.0,
            blue: Double(hex & 0xff) / 255.0
        )
    }
}
