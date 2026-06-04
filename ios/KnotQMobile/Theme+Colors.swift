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

    // OLED-black canvas (bgApp/bgSidebar) with subtly elevated surfaces for the
    // floating "glass" chrome — the dock, quick-write buttons, calendar lip, and
    // modal/sheet rows lift just above the black so they read as glass instead
    // of melting into the background.
    static let dark = KnotQTheme(
        isDark: true,
        bgApp: Color.black,
        bgSidebar: Color.black,
        bgToolbar: Color(hex: 0x151517),
        bgModal: Color(hex: 0x0e0e10),
        rowAlt: Color.white.opacity(0.045),
        rowHover: Color.white.opacity(0.08),
        rowSelected: Color.white.opacity(0.14),
        buttonBg: Color.white.opacity(0.095),
        divider: Color.white.opacity(0.13),
        dividerSoft: Color.white.opacity(0.08),
        dividerTiny: Color.white.opacity(0.05),
        borderOverlay: Color.white.opacity(0.16),
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

func calendarDayHighlightColor(dark: Bool) -> Color {
    Color(hex: dark ? 0x0a84ff : 0x007aff)
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
