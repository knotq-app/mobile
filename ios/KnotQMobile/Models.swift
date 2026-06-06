import SwiftUI

extension MobileNode: Identifiable {}
extension MobileScheme: Identifiable {}
extension MobileItem: Identifiable {}

extension MobileDailyEntry: Identifiable {
    public var id: String { date }
}

extension MobileCalendarDay: Identifiable {
    public var id: String { date }
}

extension MobileCalendar {
    var visibleDays: [MobileCalendarDay] {
        let filtered = days.filter { $0.date >= startDate && $0.date <= endDate }
        return filtered.isEmpty ? Array(days.prefix(7)) : filtered
    }
}

extension MobileOccurrence: Identifiable {
    public var id: String { "\(schemeId)-\(itemId)-\(occurrenceJson)-\(start ?? end ?? kind)" }

    var localAnchorDateKey: String? {
        guard let date = MobileDate.parseDateTime(start ?? end) else {
            return localDate
        }
        return MobileDate.dateOnly(date)
    }
}

extension MobileNotificationRequest: Identifiable {}

extension MobileSearchHit: Identifiable {
    public var id: String { "\(targetKind)-\(schemeId ?? "")-\(itemId ?? "")-\(title)-\(detail)" }
}

struct MobileNotificationActionRequest: Sendable {
    let actionID: String
    let schemeID: String
    let itemID: String
    let occurrenceJSON: String
    let triggerAt: String
}

struct LocalSyncSession: Codable, Equatable, Sendable {
    var apiBase: String
    var userId: String
    var email: String
    var supportsSync: Bool = true
    // Short-lived access token; `expiresAt` is its expiry.
    var bearerToken: String
    var expiresAt: String
    // Long-lived, rotated-on-refresh credential and its (sliding) expiry.
    var refreshToken: String
    var refreshExpiresAt: String?

    enum CodingKeys: String, CodingKey {
        case apiBase
        case userId
        case email
        case supportsSync
        case bearerToken
        case expiresAt
        case refreshToken
        case refreshExpiresAt
    }

    init(
        apiBase: String,
        userId: String,
        email: String,
        supportsSync: Bool = true,
        bearerToken: String,
        expiresAt: String,
        refreshToken: String,
        refreshExpiresAt: String? = nil
    ) {
        self.apiBase = apiBase
        self.userId = userId
        self.email = email
        self.supportsSync = supportsSync
        self.bearerToken = bearerToken
        self.expiresAt = expiresAt
        self.refreshToken = refreshToken
        self.refreshExpiresAt = refreshExpiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiBase = try container.decode(String.self, forKey: .apiBase)
        userId = try container.decode(String.self, forKey: .userId)
        email = try container.decode(String.self, forKey: .email)
        supportsSync = try container.decodeIfPresent(Bool.self, forKey: .supportsSync) ?? true
        bearerToken = try container.decode(String.self, forKey: .bearerToken)
        expiresAt = try container.decode(String.self, forKey: .expiresAt)
        refreshToken = try container.decode(String.self, forKey: .refreshToken)
        refreshExpiresAt = try container.decodeIfPresent(String.self, forKey: .refreshExpiresAt)
    }
}

enum Marker: String, CaseIterable, Identifiable {
    case blank
    case checkbox
    case bullet
    case numbered

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blank: "Text"
        case .checkbox: "Task"
        case .bullet: "Bullet"
        case .numbered: "Numbered"
        }
    }

    var icon: String {
        switch self {
        case .blank: "text.alignleft"
        case .checkbox: "checkmark.circle"
        case .bullet: "list.bullet"
        case .numbered: "list.number"
        }
    }
}

enum CalendarKind: String, CaseIterable, Identifiable {
    case event
    case reminder
    case assignment
    case task

    var id: String { rawValue }

    var label: String {
        switch self {
        case .event: "Event"
        case .reminder: "Reminder"
        case .assignment: "Assignment"
        case .task: "Task"
        }
    }

    var icon: String {
        switch self {
        case .event: "calendar"
        case .reminder: "bell"
        case .assignment: "flag"
        case .task: "checkmark.circle"
        }
    }
}

struct CalendarKindSelector: View {
    @Binding var selection: CalendarKind
    var disabled = false

    private let columns = [
        GridItem(.flexible(), spacing: 7),
        GridItem(.flexible(), spacing: 7),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 7) {
            ForEach(CalendarKind.allCases) { kind in
                Button {
                    selection = kind
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: kind.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 14)
                        Text(kind.label)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .padding(.horizontal, 7)
                    .foregroundStyle(selection == kind ? Color.white : Color.primary)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selection == kind ? Color.accentColor : Color.secondary.opacity(0.12))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.secondary.opacity(selection == kind ? 0 : 0.22), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(disabled)
            }
        }
        .opacity(disabled ? 0.55 : 1)
    }
}

enum EventOccurrenceScope: String, Identifiable {
    case thisEvent = "this_event"
    case allFuture = "all_future"
    case allEvents = "all_events"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .thisEvent: "This task"
        case .allFuture: "This and future tasks"
        case .allEvents: "All tasks"
        }
    }
}

struct NotificationLeadTimeOption: Identifiable, Hashable {
    let label: String
    let offsetSecs: Int32

    var id: Int32 { offsetSecs }
}

let defaultEventNotificationOffsetSecs: Int32 = 10 * 60
let defaultAssignmentNotificationOffsetSecs: Int32 = 2 * 60 * 60

let eventDefaultNotificationOptions: [NotificationLeadTimeOption] = [
    .init(label: "At start", offsetSecs: 0),
    .init(label: "5 minutes before", offsetSecs: 5 * 60),
    .init(label: "10 minutes before", offsetSecs: defaultEventNotificationOffsetSecs),
    .init(label: "15 minutes before", offsetSecs: 15 * 60),
    .init(label: "30 minutes before", offsetSecs: 30 * 60),
    .init(label: "1 hour before", offsetSecs: 60 * 60),
]

let assignmentDefaultNotificationOptions: [NotificationLeadTimeOption] = [
    .init(label: "At due time", offsetSecs: 0),
    .init(label: "1 hour before", offsetSecs: 60 * 60),
    .init(label: "2 hours before", offsetSecs: defaultAssignmentNotificationOffsetSecs),
    .init(label: "6 hours before", offsetSecs: 6 * 60 * 60),
    .init(label: "1 day before", offsetSecs: 24 * 60 * 60),
    .init(label: "2 days before", offsetSecs: 2 * 24 * 60 * 60),
]

let occurrenceNotificationOptions: [NotificationLeadTimeOption] = [
    .init(label: "At time", offsetSecs: 0),
    .init(label: "5 minutes before", offsetSecs: 5 * 60),
    .init(label: "10 minutes before", offsetSecs: defaultEventNotificationOffsetSecs),
    .init(label: "30 minutes before", offsetSecs: 30 * 60),
    .init(label: "1 hour before", offsetSecs: 60 * 60),
    .init(label: "1 day before", offsetSecs: 24 * 60 * 60),
]

func defaultNotificationOffset(kind: CalendarKind, settings: MobileSettings?) -> Int32 {
    switch kind {
    case .event:
        return settings?.eventNotificationOffsetSecs ?? defaultEventNotificationOffsetSecs
    case .assignment:
        return settings?.assignmentNotificationOffsetSecs ?? defaultAssignmentNotificationOffsetSecs
    case .reminder, .task:
        return 0
    }
}

func notificationLeadTimeLabel(_ offsetSecs: Int32) -> String {
    occurrenceNotificationOptions.first { $0.offsetSecs == offsetSecs }?.label
        ?? eventDefaultNotificationOptions.first { $0.offsetSecs == offsetSecs }?.label
        ?? assignmentDefaultNotificationOptions.first { $0.offsetSecs == offsetSecs }?.label
        ?? "\(offsetSecs / 60) minutes before"
}

func occurrenceNotificationOptionsIncluding(_ offsetSecs: Int32) -> [NotificationLeadTimeOption] {
    if occurrenceNotificationOptions.contains(where: { $0.offsetSecs == offsetSecs }) {
        return occurrenceNotificationOptions
    }
    var options = occurrenceNotificationOptions
    options.append(.init(label: notificationLeadTimeLabel(offsetSecs), offsetSecs: offsetSecs))
    return options.sorted { $0.offsetSecs < $1.offsetSecs }
}

enum RepeatWeekdayChoice: String, CaseIterable, Identifiable, Hashable {
    case sun = "SU"
    case mon = "MO"
    case tue = "TU"
    case wed = "WE"
    case thu = "TH"
    case fri = "FR"
    case sat = "SA"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sun: "S"
        case .mon: "M"
        case .tue: "T"
        case .wed: "W"
        case .thu: "T"
        case .fri: "F"
        case .sat: "S"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .sun: "Sunday"
        case .mon: "Monday"
        case .tue: "Tuesday"
        case .wed: "Wednesday"
        case .thu: "Thursday"
        case .fri: "Friday"
        case .sat: "Saturday"
        }
    }

    static func defaultFor(date: Date) -> RepeatWeekdayChoice {
        switch Calendar.current.component(.weekday, from: date) {
        case 1: .sun
        case 2: .mon
        case 3: .tue
        case 4: .wed
        case 5: .thu
        case 6: .fri
        default: .sat
        }
    }

    static func selected(from rrule: String?, fallbackDate: Date) -> Set<RepeatWeekdayChoice> {
        guard let rrule = rrule?.uppercased(), !rrule.isEmpty else {
            return [defaultFor(date: fallbackDate)]
        }
        let fields = rrule
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "RRULE:", with: "")
            .split(separator: ";")
        guard let byday = fields.first(where: { $0.hasPrefix("BYDAY=") }) else {
            return [defaultFor(date: fallbackDate)]
        }
        let parsed = byday
            .dropFirst("BYDAY=".count)
            .split(separator: ",")
            .compactMap { part -> RepeatWeekdayChoice? in
                let code = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
                return RepeatWeekdayChoice(rawValue: String(code.suffix(2)))
            }
        return parsed.isEmpty ? [defaultFor(date: fallbackDate)] : Set(parsed)
    }

    static func orderedCodes(_ selection: Set<RepeatWeekdayChoice>) -> [String] {
        [.mon, .tue, .wed, .thu, .fri, .sat, .sun]
            .filter { selection.contains($0) }
            .map(\.rawValue)
    }
}

struct WeeklyRepeatDaysPicker: View {
    @Binding var selection: Set<RepeatWeekdayChoice>
    var disabled = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(RepeatWeekdayChoice.allCases) { day in
                Button {
                    toggle(day)
                } label: {
                    Text(day.label)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(selection.contains(day) ? Color.white : Color.primary)
                        .background(
                            Circle()
                                .fill(selection.contains(day) ? Color.accentColor : Color.clear)
                        )
                        .overlay {
                            Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .opacity(disabled ? 0.45 : 1)
                .accessibilityLabel(day.accessibilityLabel)
            }
        }
    }

    private func toggle(_ day: RepeatWeekdayChoice) {
        if selection.contains(day) {
            if selection.count > 1 {
                selection.remove(day)
            }
        } else {
            selection.insert(day)
        }
    }
}

let schemeColors: [Color] = [
    .blue, .green, .orange, .purple, .pink,
    .teal, .red, .indigo, .mint, Color(red: 0.878, green: 0.659, blue: 0.0)
]

func colorForIndex(_ index: Int32?) -> Color {
    guard let index else { return .secondary }
    return schemeColors[Int(index) % schemeColors.count]
}
