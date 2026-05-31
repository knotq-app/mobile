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
    // Long-lived, rotated-on-refresh credential and its (sliding) expiry. Optional
    // so a session persisted before refresh tokens existed still decodes; a missing
    // refresh token just forces a one-time re-login.
    var refreshToken: String?
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
        refreshToken: String? = nil,
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
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
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
}

let schemeColors: [Color] = [
    .blue, .green, .orange, .purple, .pink,
    .teal, .red, .indigo, .mint, Color(red: 0.878, green: 0.659, blue: 0.0)
]

func colorForIndex(_ index: Int32?) -> Color {
    guard let index else { return .secondary }
    return schemeColors[Int(index) % schemeColors.count]
}
