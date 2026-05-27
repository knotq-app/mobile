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

extension MobileOccurrence: Identifiable {
    public var id: String { "\(schemeId)-\(itemId)-\(start ?? end ?? kind)" }
}

extension MobileSearchHit: Identifiable {
    public var id: String { "\(targetKind)-\(schemeId ?? "")-\(itemId ?? "")-\(title)-\(detail)" }
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
    .teal, .red, .indigo, .mint, .yellow
]

func colorForIndex(_ index: Int32?) -> Color {
    guard let index else { return .secondary }
    return schemeColors[Int(index) % schemeColors.count]
}
