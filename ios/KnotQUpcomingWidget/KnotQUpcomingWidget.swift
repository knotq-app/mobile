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
        Group {
            switch family {
            case .accessoryInline:
                Text(inlineSummary)
                    .widgetAccentable()
            case .accessoryRectangular:
                accessoryRectangular
            case .systemSmall:
                systemBody(limit: 3)
            case .systemMedium:
                systemBody(limit: 4)
            case .systemLarge:
                systemBody(limit: 8)
            default:
                systemBody(limit: 3)
            }
        }
        .containerBackground(background, for: .widget)
    }

    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Upcoming")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if let first = visibleItems.first {
                Text(title(for: first))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(timeLabel(for: first))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Nothing scheduled")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
        }
    }

    private func systemBody(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                Text("Upcoming")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(primaryText)
                Spacer(minLength: 0)
            }

            if visibleItems.isEmpty {
                Spacer(minLength: 0)
                Text("Nothing scheduled")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: family == .systemLarge ? 5 : 4) {
                    ForEach(Array(visibleItems.prefix(limit))) { item in
                        WidgetUpcomingRow(item: item, time: timeLabel(for: item), dark: isDark)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(2)
    }

    private var visibleItems: [KnotQWidgetOccurrence] {
        entry.snapshot.items.filter { !$0.done }
    }

    private var inlineSummary: String {
        guard let first = visibleItems.first else { return "KnotQ: nothing scheduled" }
        let count = max(0, visibleItems.count - 1)
        let suffix = count > 0 ? " +\(count)" : ""
        return "\(timeLabel(for: first)) \(title(for: first))\(suffix)"
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
            return "\(formattedDateTime(start))-\(formattedTime(end))"
        }
        if let start = item.start {
            return formattedDateTime(start)
        }
        if let end = item.end {
            return "Due \(formattedDateTime(end))"
        }
        return item.kind.capitalized
    }

    private func formattedDateTime(_ raw: String) -> String {
        guard let date = Self.iso.date(from: raw) else { return raw }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: date)
        let time = formattedTime(raw)
        if target == today { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today), target == tomorrow {
            return "Tomorrow \(time)"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = target < today ? "MMM d" : "EEE"
        return "\(formatter.string(from: date)) \(time)"
    }

    private func formattedTime(_ raw: String) -> String {
        guard let date = Self.iso.date(from: raw) else { return raw }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = entry.snapshot.timeFormat == "twenty_four_hour" ? "HH:mm" : "h:mm a"
        return formatter.string(from: date)
    }

    private var isDark: Bool {
        switch entry.snapshot.themeMode {
        case "dark": true
        case "light": false
        default: colorScheme == .dark
        }
    }

    private var background: Color {
        isDark ? Color(red: 0.055, green: 0.055, blue: 0.062) : Color(red: 0.965, green: 0.953, blue: 0.933)
    }

    private var primaryText: Color {
        isDark ? Color(red: 0.925, green: 0.925, blue: 0.900) : Color(red: 0.165, green: 0.145, blue: 0.110)
    }

    private var secondaryText: Color {
        isDark ? Color(red: 0.650, green: 0.650, blue: 0.610) : Color(red: 0.455, green: 0.405, blue: 0.330)
    }

    private var accent: Color {
        isDark ? Color(red: 0.610, green: 0.720, blue: 1.000) : Color(red: 0.210, green: 0.405, blue: 0.810)
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private struct WidgetUpcomingRow: View {
    let item: KnotQWidgetOccurrence
    let time: String
    let dark: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(time)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(timeColor)
                .lineLimit(1)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(titleColor)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        let trimmed = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? item.kind.capitalized : trimmed
    }

    private var color: Color {
        let palette: [Color] = [
            .blue, .green, .orange, .purple, .pink,
            .teal, .red, .indigo, .mint, Color(red: 0.878, green: 0.659, blue: 0.0)
        ]
        return palette[item.colorIndex % palette.count]
    }

    private var timeColor: Color {
        dark ? Color(red: 0.760, green: 0.760, blue: 1.000) : Color(red: 0.165, green: 0.365, blue: 0.760)
    }

    private var titleColor: Color {
        dark ? Color(red: 0.925, green: 0.925, blue: 0.900) : Color(red: 0.165, green: 0.145, blue: 0.110)
    }
}
