import SwiftUI
import WidgetKit

struct KnotQUpcomingEntry: TimelineEntry {
    let date: Date
    let snapshot: KnotQWidgetSnapshot
}

struct KnotQUpcomingProvider: TimelineProvider {
    func placeholder(in context: Context) -> KnotQUpcomingEntry {
        KnotQUpcomingEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (KnotQUpcomingEntry) -> Void) {
        completion(KnotQUpcomingEntry(date: Date(), snapshot: KnotQWidgetSnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<KnotQUpcomingEntry>) -> Void) {
        let entry = KnotQUpcomingEntry(date: Date(), snapshot: KnotQWidgetSnapshotStore.load())
        let refresh = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }
}

struct KnotQUpcomingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: knotQWidgetKind, provider: KnotQUpcomingProvider()) { entry in
            KnotQUpcomingWidgetView(entry: entry)
        }
        .configurationDisplayName("Upcoming")
        .description("Shows upcoming KnotQ items.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryInline, .accessoryRectangular])
        .containerBackgroundRemovable(false)
        .contentMarginsDisabled()
    }
}

@main
struct KnotQUpcomingWidgetBundle: WidgetBundle {
    var body: some Widget {
        KnotQUpcomingWidget()
    }
}

private struct KnotQUpcomingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: KnotQUpcomingEntry

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: contentAlignment)
            .background {
                if family != .accessoryInline {
                    theme.background
                }
            }
            .containerBackground(for: .widget) {
                theme.background
            }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch family {
            case .accessoryInline:
                Text(inlineSummary)
                    .widgetAccentable()
            case .accessoryRectangular:
                accessoryRectangular
            case .systemSmall:
                systemBody(limit: 3, rowHeight: 40)
            case .systemMedium:
                systemBody(limit: 6, columns: 2, dense: true, rowHeight: 37)
            case .systemLarge:
                systemBody(limit: 12, columns: 2, rowHeight: 46)
            default:
                systemBody(limit: 3, rowHeight: 40)
            }
        }
    }

    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 3) {
            currentDateHeader
            if let first = visibleItems.first {
                WidgetOccurrenceCompactRow(
                    item: first,
                    time: timeLabel(for: first),
                    theme: theme,
                    striped: false,
                    compact: true
                )
                .frame(height: 38, alignment: .center)
                if visibleItems.count > 1 {
                    Text("+ \(visibleItems.count - 1) more")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(theme.textMuted)
                        .lineLimit(1)
                }
            } else {
                Text("Nothing scheduled")
                    .font(.caption)
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(2)
            }
        }
        .padding(10)
    }

    private func systemBody(limit: Int, columns: Int = 1, dense: Bool = false, rowHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: dense ? 0 : 2) {
            currentDateHeader
            if visibleItems.isEmpty {
                Text("Nothing scheduled")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textMuted)
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                if columns <= 1 {
                    VStack(spacing: 0) {
                        ForEach(Array(visibleItems.prefix(limit).enumerated()), id: \.element.id) { idx, item in
                            WidgetOccurrenceCompactRow(
                                item: item,
                                time: timeLabel(for: item),
                                theme: theme,
                                striped: false,
                                compact: true
                            )
                            .frame(height: rowHeight, alignment: .center)

                            if idx != min(limit, visibleItems.count) - 1 {
                                Divider()
                                    .background(theme.divider)
                            }
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: dense ? 5 : 8) {
                        ForEach(Array(columnFilledSlots(limit: limit, columns: columns).enumerated()), id: \.offset) { _, columnItems in
                            VStack(spacing: dense ? 1 : 3) {
                                ForEach(columnItems) { slot in
                                    if let item = slot.item {
                                        WidgetOccurrenceCompactRow(
                                            item: item,
                                            time: timeLabel(for: item),
                                            theme: theme,
                                            striped: false,
                                            compact: dense
                                        )
                                        .frame(height: rowHeight, alignment: .center)
                                    } else {
                                        Color.clear
                                            .frame(height: rowHeight)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.top, wideRowsTopPadding(columns: columns))
                }
            }
        }
        .padding(.leading, systemLeadingPadding(dense: dense))
        .padding(.trailing, systemTrailingPadding(dense: dense))
        .padding(.top, systemTopPadding(dense: dense))
        .padding(.bottom, systemBottomPadding(dense: dense))
    }

    private var contentAlignment: Alignment {
        shouldCenterFullSmallWidget ? .center : .top
    }

    private var shouldCenterFullSmallWidget: Bool {
        family == .systemSmall && visibleItems.count >= 3
    }

    private func systemTopPadding(dense: Bool) -> CGFloat {
        if shouldCenterFullSmallWidget {
            return 11
        }
        return dense ? 10 : 11
    }

    private func systemBottomPadding(dense: Bool) -> CGFloat {
        if shouldCenterFullSmallWidget {
            return 3
        }
        if family == .systemMedium {
            return 2
        }
        if family == .systemLarge {
            return 3
        }
        return dense ? 4 : 5
    }

    private func wideRowsTopPadding(columns: Int) -> CGFloat {
        family == .systemMedium && columns > 1 ? 6 : 0
    }

    private func systemLeadingPadding(dense: Bool) -> CGFloat {
        if shouldCenterFullSmallWidget {
            return 18
        }
        return dense ? 18 : 20
    }

    private func systemTrailingPadding(dense: Bool) -> CGFloat {
        if shouldCenterFullSmallWidget {
            return 14
        }
        return dense ? 14 : 16
    }

    private var currentDateHeader: some View {
        Text(currentDateLabel)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(theme.textPrimary)
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: 12, alignment: .top)
            .padding(.horizontal, 2)
    }

    private var visibleItems: [KnotQWidgetOccurrence] {
        entry.snapshot.items.filter { !$0.done }
    }

    private func columnFilledSlots(
        limit: Int,
        columns: Int
    ) -> [[WidgetColumnSlot]] {
        let visible = Array(visibleItems.prefix(limit).enumerated())
        let rowsPerColumn = max(1, Int(ceil(Double(limit) / Double(max(1, columns)))))
        return (0..<columns).map { column in
            (0..<rowsPerColumn).map { row in
                let index = column * rowsPerColumn + row
                return WidgetColumnSlot(id: column * rowsPerColumn + row, item: index < visible.count ? visible[index].element : nil)
            }
        }
    }

    private var inlineSummary: String {
        guard let first = visibleItems.first else { return "Nothing scheduled" }
        let count = max(0, visibleItems.count - 1)
        let suffix = count > 0 ? " +\(count)" : ""
        return "\(timeLabel(for: first)) • \(title(for: first))\(suffix)"
    }

    private func title(for item: KnotQWidgetOccurrence) -> String {
        let trimmed = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? item.kind.capitalized : trimmed
    }

    private func timeLabel(for item: KnotQWidgetOccurrence) -> String {
        if item.kind == "reminder", let start = item.start {
            return "At \(formattedDateTime(start))"
        }
        if item.kind == "assignment", let end = item.end {
            return "Due \(formattedDateTime(end))"
        }
        if let start = item.start, let end = item.end {
            return formattedRange(start: start, end: end)
        }
        if let start = item.start {
            return formattedDateTime(start)
        }
        if let end = item.end {
            return "Due \(formattedDateTime(end))"
        }
        return item.kind.capitalized
    }

    private func formattedRange(start: String, end: String) -> String {
        guard let startDate = Self.iso.date(from: start),
              let endDate = Self.iso.date(from: end) else {
            return "\(formattedDateTime(start)) → \(formattedDateTime(end))"
        }
        if Calendar.current.isDate(startDate, inSameDayAs: endDate) {
            let prefix = upcomingDatePrefix(for: startDate)
            let startTime = formattedTime(start)
            let endTime = formattedTime(end)
            return prefix.isEmpty
                ? "\(startTime) → \(endTime)"
                : "\(prefix) \(startTime) → \(endTime)"
        }
        return "\(formattedDateTime(start)) → \(formattedDateTime(end))"
    }

    private func formattedDateTime(_ raw: String) -> String {
        guard let date = Self.iso.date(from: raw) else { return raw }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: date)
        let time = formattedTime(raw)
        if target == today {
            return time
        }
        let prefix = upcomingDatePrefix(for: date)
        return prefix.isEmpty ? time : "\(prefix) \(time)"
    }

    private func formattedTime(_ raw: String) -> String {
        guard let date = Self.iso.date(from: raw) else { return raw }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = entry.snapshot.timeFormat == "twenty_four_hour" ? "HH:mm" : "h:mm"
        return formatter.string(from: date)
    }

    private var isDark: Bool {
        switch entry.snapshot.themeMode {
        case "dark": true
        case "light": false
        default: colorScheme == .dark
        }
    }

    private var theme: WidgetTheme {
        WidgetTheme.make(dark: isDark)
    }

    private var currentDateLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, MMMM d"
        return formatter.string(from: entry.date)
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private struct WidgetColumnSlot: Identifiable {
    let id: Int
    let item: KnotQWidgetOccurrence?
}

private struct WidgetOccurrenceCompactRow: View {
    let item: KnotQWidgetOccurrence
    let time: String
    let theme: WidgetTheme
    let striped: Bool
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 5 : 7) {
            Rectangle()
                .fill(schemeAccent)
                .frame(width: compact ? 2 : 3)
                .padding(.vertical, compact ? 5 : 8)

            VStack(alignment: .leading, spacing: compact ? 2 : 3) {
                Text(titleLabel)
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .lineLimit(1)
                    .allowsTightening(true)
                    .foregroundStyle(theme.textPrimary)
                    .layoutPriority(2)

                HStack(alignment: .firstTextBaseline, spacing: compact ? 4 : 6) {
                    Text(time)
                        .font(.system(size: compact ? 9 : 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(occurrenceTimeColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .allowsTightening(true)
                        .layoutPriority(2)

                    Spacer(minLength: 2)
                }
            }
            .padding(.vertical, compact ? 4 : 6)
            .padding(.trailing, compact ? 4 : 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(striped ? theme.rowAlt : Color.clear)
        .opacity(item.done ? 0.5 : 1)
    }

    private var titleLabel: String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? item.kind.capitalized : title
    }

    private var schemeAccent: Color {
        item.schemeName == dailyQueueSchemeName
            ? dailyQueueColor(dark: theme.isDark)
            : schemeColor(index: Int32(item.colorIndex), dark: theme.isDark)
    }

    private var occurrenceTimeColor: Color {
        guard !item.done else { return theme.textMuted }

        let now = Date()
        let anchorRaw = item.kind == "assignment"
            ? item.end
            : (item.start ?? item.end)
        guard let anchorRaw,
              let anchor = Self.iso.date(from: anchorRaw) else {
            return theme.textSoft
        }

        if item.kind == "event",
           let endRaw = item.end,
           let end = Self.iso.date(from: endRaw),
           anchor <= now,
           end > now {
            return theme.isDark ? Color(hex: 0xbfbfff) : Color(hex: 0x2f67cf)
        }

        if anchor < now {
            return theme.isDark ? Color(hex: 0xff5a53) : Color(hex: 0xd20f39)
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let startDay = calendar.startOfDay(for: anchor)
        let dayDiff = calendar.dateComponents([.day], from: today, to: startDay).day ?? 0

        if dayDiff <= 0 {
            return theme.isDark ? Color(hex: 0xbfbfff) : Color(hex: 0x2f67cf)
        }
        if dayDiff <= 1 {
            return theme.isDark ? Color(hex: 0xe5e5ff) : Color(hex: 0x4f5f8f)
        }
        return theme.isDark ? Color(hex: 0xb9c0c8) : theme.textSoft
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private struct WidgetTheme {
    let isDark: Bool
    let background: Color
    let rowAlt: Color
    let divider: Color
    let textPrimary: Color
    let textMuted: Color
    let textSoft: Color

    static func make(dark: Bool) -> WidgetTheme {
        if dark {
            return WidgetTheme(
                isDark: true,
                background: Color(hex: 0x151517),
                rowAlt: Color(hex: 0xffffff).opacity(0.04),
                divider: Color(hex: 0xffffff).opacity(0.10),
                textPrimary: Color(hex: 0xf2f2f7),
                textMuted: Color(hex: 0x98a0aa).opacity(0.55),
                textSoft: Color(hex: 0xd2dae2).opacity(0.64)
            )
        }

        return WidgetTheme(
            isDark: false,
            background: Color(hex: 0xf2f5f2),
            rowAlt: Color(hex: 0x3a443d).opacity(0.04),
            divider: Color(hex: 0x3a443d).opacity(0.16),
            textPrimary: Color(hex: 0x171717),
            textMuted: Color(hex: 0x6d746d).opacity(0.80),
            textSoft: Color(hex: 0x393f39).opacity(0.85)
        )
    }
}

private let dailyQueueSchemeName = "Daily"

// Mirrors the app's dailyQueueColor (Theme+Colors.swift): daily rows use the
// steel-blue daily accent everywhere, not palette index 0 (red).
private func dailyQueueColor(dark: Bool) -> Color {
    dark ? Color(hex: 0xb8c9e8) : Color(hex: 0x5a7aad)
}

private func schemeColor(index: Int32, dark: Bool) -> Color {
    let darkPalette: [UInt32] = [0xff453a, 0xff9f0a, 0x30d158, 0x0a84ff, 0xbf5af2, 0xffd60a]
    let lightPalette: [UInt32] = [0xb84433, 0xc47400, 0x28764f, 0x2563a6, 0x735aa6, 0xe0a800]
    let palette = dark ? darkPalette : lightPalette
    return Color(hex: palette[Int(index) % palette.count])
}

private func upcomingDatePrefix(for date: Date) -> String {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let target = calendar.startOfDay(for: date)
    if target == today { return "" }
    if let inAWeek = calendar.date(byAdding: .day, value: 7, to: today), target < inAWeek && target > today {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "MMMM d"
    return formatter.string(from: date)
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
