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
        case "dark": .dark
        case "rose_pine_moon": .moonlit
        case "catppuccin_mocha": .espresso
        case "tokyo_night": .blueHour
        case "parchment": .parchment
        case "rose_pine_dawn": .dawn
        case "catppuccin_latte": .cream
        case "system", nil: systemScheme == .dark ? .dark : .light
        default: .dark
        }
    }

    private static func variant(_ base: KnotQTheme, bgApp: UInt32, bgSidebar: UInt32, bgToolbar: UInt32, bgModal: UInt32, accent: UInt32, textPrimary: UInt32, textSoft: UInt32, textDim: UInt32, textMuted: UInt32) -> KnotQTheme {
        KnotQTheme(
            isDark: base.isDark,
            bgApp: Color(hex: bgApp), bgSidebar: Color(hex: bgSidebar), bgToolbar: Color(hex: bgToolbar), bgModal: Color(hex: bgModal),
            rowAlt: base.rowAlt, rowHover: base.rowHover, rowSelected: Color(hex: accent).opacity(base.isDark ? 0.22 : 0.12),
            buttonBg: base.buttonBg, divider: base.divider, dividerSoft: base.dividerSoft, dividerTiny: base.dividerTiny,
            borderOverlay: base.borderOverlay, textPrimary: Color(hex: textPrimary), textDim: Color(hex: textDim), textMuted: Color(hex: textMuted),
            textSoft: Color(hex: textSoft), textToday: Color(hex: accent), accent: Color(hex: accent), danger: base.danger
        )
    }

    static let moonlit = variant(.dark, bgApp: 0x191724, bgSidebar: 0x1f1d2e, bgToolbar: 0x26233a, bgModal: 0x26233a, accent: 0xc4a7e7, textPrimary: 0xe0def4, textSoft: 0x908caa, textDim: 0x9893a5, textMuted: 0x6e6a86)
    static let espresso = variant(.dark, bgApp: 0x1e1e2e, bgSidebar: 0x181825, bgToolbar: 0x313244, bgModal: 0x313244, accent: 0xf5c2e7, textPrimary: 0xcdd6f4, textSoft: 0xa6adc8, textDim: 0xbac2de, textMuted: 0x7f849c)
    static let blueHour = variant(.dark, bgApp: 0x1a1b26, bgSidebar: 0x16161e, bgToolbar: 0x24283b, bgModal: 0x24283b, accent: 0x7aa2f7, textPrimary: 0xc0caf5, textSoft: 0xa9b1d6, textDim: 0x9aa5ce, textMuted: 0x565f89)
    static let parchment = variant(.light, bgApp: 0xf4eddf, bgSidebar: 0xebe1cf, bgToolbar: 0xe4d6bf, bgModal: 0xfff9ed, accent: 0xa66a00, textPrimary: 0x3c3024, textSoft: 0x6b5b48, textDim: 0x665542, textMuted: 0x887763)
    static let dawn = variant(.light, bgApp: 0xfaf4ed, bgSidebar: 0xf2e9df, bgToolbar: 0xece0d3, bgModal: 0xfffaf3, accent: 0x907aa9, textPrimary: 0x575279, textSoft: 0x797593, textDim: 0x6e6a86, textMuted: 0x9893a5)
    static let cream = variant(.light, bgApp: 0xeff1f5, bgSidebar: 0xe6e9ef, bgToolbar: 0xdce0e8, bgModal: 0xffffff, accent: 0x1e66f5, textPrimary: 0x4c4f69, textSoft: 0x6c6f85, textDim: 0x5c5f77, textMuted: 0x8c8fa1)

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

    // Clean, near-white light theme matching knotq.com: an off-white canvas,
    // soft gray-green surfaces, near-black ink, and a rose accent. Translucent
    // rows/dividers tint with a slate-green so they read as the site's --line
    // colors over the light canvas.
    static let light = KnotQTheme(
        isDark: false,
        bgApp: Color(hex: 0xfafbf9),
        bgSidebar: Color(hex: 0xf2f5f2),
        bgToolbar: Color(hex: 0xf2f5f2),
        bgModal: Color(hex: 0xffffff),
        rowAlt: Color(hex: 0x3a443d).opacity(0.04),
        rowHover: Color(hex: 0x3a443d).opacity(0.08),
        rowSelected: Color(hex: 0xc7375d).opacity(0.12),
        buttonBg: Color(hex: 0x3a443d).opacity(0.08),
        divider: Color(hex: 0x3a443d).opacity(0.16),
        dividerSoft: Color(hex: 0x3a443d).opacity(0.11),
        dividerTiny: Color(hex: 0x3a443d).opacity(0.05),
        borderOverlay: Color(hex: 0x3a443d).opacity(0.20),
        textPrimary: Color(hex: 0x171717),
        textDim: Color(hex: 0x393f39).opacity(0.90),
        textMuted: Color(hex: 0x6d746d).opacity(0.80),
        textSoft: Color(hex: 0x393f39).opacity(0.85),
        textToday: Color(hex: 0xc7375d),
        accent: Color(hex: 0xc7375d),
        danger: Color(hex: 0xb84433)
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
    let lightPalette: [UInt32] = [0xb84433, 0xc47400, 0x28764f, 0x2563a6, 0x735aa6, 0xe0a800]
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
