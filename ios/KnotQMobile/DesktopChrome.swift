import SwiftUI

struct TitleIconButton: ButtonStyle {
    let theme: KnotQTheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
            .frame(width: 25, height: 25)
            .background(configuration.isPressed ? theme.rowSelected : theme.buttonBg, in: RoundedRectangle(cornerRadius: 4))
    }
}

enum SyncAuthMode: String, CaseIterable, Identifiable {
    case signIn
    case createAccount

    var id: String { rawValue }

    var title: String {
        switch self {
        case .signIn: L10n.t("mobile.auth.sign_in")
        case .createAccount: L10n.t("mobile.auth.create_account")
        }
    }
}

func findNode(id: String, in node: MobileNode) -> MobileNode? {
    if node.id == id {
        return node
    }
    for child in node.children {
        if let found = findNode(id: id, in: child) {
            return found
        }
    }
    return nil
}

func findChildPlacement(childID: String, in node: MobileNode) -> (parentID: String, position: Int)? {
    for (index, child) in node.children.enumerated() {
        if child.id == childID {
            return (node.id, index)
        }
        if let found = findChildPlacement(childID: childID, in: child) {
            return found
        }
    }
    return nil
}

func containsNode(_ targetID: String, within container: MobileNode) -> Bool {
    for child in container.children {
        if child.id == targetID || containsNode(targetID, within: child) {
            return true
        }
    }
    return false
}

struct SchemeTreePrefix: View {
    let depth: Int
    let showsDisclosure: Bool
    let expanded: Bool
    let compact: Bool
    let theme: KnotQTheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<visibleDepth, id: \.self) { _ in
                Color.clear
                    .frame(width: indentUnit, height: rowHeight)
            }
            if showsDisclosure {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: compact ? 9 : 10, weight: .bold))
                    .foregroundStyle(theme.textMuted)
                    .frame(width: disclosureWidth)
            } else {
                Color.clear
                    .frame(width: 0, height: rowHeight)
            }
        }
        .frame(height: rowHeight)
    }

    private var indentUnit: CGFloat { compact ? 8 : 9 }
    private var disclosureWidth: CGFloat { compact ? 12 : 14 }
    private var rowHeight: CGFloat { compact ? 25 : 30 }
    private var visibleDepth: Int { max(0, depth) }
}

struct SchemeTreeIconSlot<Content: View>: View {
    let compact: Bool
    let content: Content

    init(compact: Bool, @ViewBuilder content: () -> Content) {
        self.compact = compact
        self.content = content()
    }

    var body: some View {
        content
            .frame(width: compact ? 14 : 17, height: compact ? 14 : 17)
    }
}

struct DesktopUpcomingRail: View {
    let calendar: MobileCalendar?
    let settings: MobileSettings?
    let theme: KnotQTheme
    let timeFormat: String
    let onToggleOccurrence: (MobileOccurrence) -> Void
    let onOpenOccurrence: (MobileOccurrence) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                UpcomingSection(title: L10n.t("upcoming.section.assignments"), empty: L10n.t("upcoming.empty.none"), occurrences: assignments, theme: theme, timeFormat: timeFormat, onToggleOccurrence: onToggleOccurrence, onOpenOccurrence: onOpenOccurrence)
                UpcomingSection(title: L10n.t("upcoming.section.reminders"), empty: L10n.t("upcoming.empty.none"), occurrences: reminders, theme: theme, timeFormat: timeFormat, onToggleOccurrence: onToggleOccurrence, onOpenOccurrence: onOpenOccurrence)
                UpcomingSection(title: L10n.t("upcoming.section.upcoming"), empty: L10n.t("upcoming.empty.none_today"), occurrences: upcomingEvents, theme: theme, timeFormat: timeFormat, onToggleOccurrence: onToggleOccurrence, onOpenOccurrence: onOpenOccurrence)
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)
        }
        .background(theme.bgApp)
    }

    private var assignments: [MobileOccurrence] {
        bucket(kind: "assignment", base: displayedOccurrences)
    }

    private var reminders: [MobileOccurrence] {
        bucket(kind: "reminder", base: displayedOccurrences)
    }

    private var upcomingEvents: [MobileOccurrence] {
        bucket(kind: "event", base: displayedOccurrences)
    }

    private var displayedOccurrences: [MobileOccurrence] {
        MobileUpcomingDisplay.visibleOccurrences(
            overdue: calendar?.overdue ?? [],
            upcoming: calendar?.upcoming ?? [],
            maximumItems: settings?.maximumUpcomingItems ?? UpcomingDisplayDefaults.maximumItems,
            showOverdue: settings?.showOverdue ?? UpcomingDisplayDefaults.showOverdue,
            showCompleted: settings?.showCompleted ?? UpcomingDisplayDefaults.showCompleted
        )
    }

    private func bucket(kind: String, base: [MobileOccurrence]) -> [MobileOccurrence] {
        var seen = Set<String>()
        return base
            .filter { $0.kind == kind && seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                let l = MobileDate.parseDateTime(lhs.start ?? lhs.end) ?? .distantFuture
                let r = MobileDate.parseDateTime(rhs.start ?? rhs.end) ?? .distantFuture
                return l < r
            }
    }
}

/// Native iPad sidebar for the NavigationSplitView: the fixed destinations
/// (Calendar/Daily/Settings) as native rows, then the reused UIKit scheme
/// tree (folders, drag-drop, archive) sized up for iPad.
struct IPadSidebar: View {
    let root: MobileNode?
    @Binding var selection: SidebarItem?
    let selectedSchemeID: String?
    let theme: KnotQTheme
    let onSelectScheme: (String) -> Void
    let onNewScheme: () -> Void
    let onNewFolder: () -> Void
    let onGoogleCalendar: (String?) -> Void
    let searchQuery: Binding<String>
    let searchHits: [MobileSearchHit]
    let onSearch: () -> Void
    let onOpenSearchHit: (MobileSearchHit) -> Void

    var body: some View {
        // Fixed top section, then the scheme tree fills the remaining height.
        // The tree is a UIKit table (its own scroll view), so it needs a
        // concrete height — nesting it in an outer ScrollView collapses it to
        // zero and the schemes vanish.
        VStack(alignment: .leading, spacing: 0) {
            iPadSearchRow()
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 10)

            iPadSearchResults()
                .padding(.horizontal, 4)
                .padding(.bottom, 10)

            VStack(spacing: 2) {
                row(.calendar, title: L10n.t("menu.calendar"), icon: "calendar", color: theme.textPrimary)
                row(.daily, title: L10n.t("menu.daily"), icon: "checklist", color: dailyQueueColor(dark: theme.isDark))
                row(.settings, title: L10n.t("settings.header.title"), icon: "gearshape", color: theme.textDim)
            }
            .padding(.horizontal, 10)

            HStack(spacing: 6) {
                Text(L10n.t("onboarding.step.schemes.title"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.textDim)
                Spacer(minLength: 0)
                Menu {
                    Button(L10n.t("mobile.sidebar.new_scheme"), systemImage: "doc.badge.plus", action: onNewScheme)
                    Button(L10n.t("sidebar.context.folder"), systemImage: "folder.badge.plus", action: onNewFolder)
                    Button(L10n.t("settings.google_calendar.section"), systemImage: "calendar.badge.plus") {
                        onGoogleCalendar(nil)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.textDim)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 2)

            SchemeNavigatorListView(
                root: root,
                selectedSchemeID: selectedSchemeID,
                theme: theme,
                compact: false,
                hidesChevron: true,
                onOpenScheme: onSelectScheme
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bgSidebar.ignoresSafeArea())
    }

    @ViewBuilder
    private func iPadSearchRow() -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textDim)
                .frame(width: 18)

            TextField(L10n.t("mobile.search.nav_title"), text: searchQuery)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { onSearch() }

            if !searchQuery.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    searchQuery.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(theme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 14))
        .frame(height: 38)
        .padding(.horizontal, 12)
        .background(theme.rowSelected.opacity(0.32), in: Capsule())
        .overlay {
            Capsule().stroke(theme.borderOverlay.opacity(0.7), lineWidth: 0.8)
        }
    }

    @ViewBuilder
    private func iPadSearchResults() -> some View {
        if searchQuery.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else if searchHits.isEmpty {
            Text(L10n.t("mobile.search.no_results"))
                .font(.system(size: 13))
                .foregroundStyle(theme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(searchHits.enumerated()), id: \.element.id) { idx, hit in
                    Button {
                        onOpenSearchHit(hit)
                    } label: {
                        HomeSearchHitRow(hit: hit, theme: theme, striped: idx % 2 == 1)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: SidebarItem, title: String, icon: String, color: Color) -> some View {
        let selected = selection == item
        let button = Button {
            selection = item
        } label: {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 26)
                Text(title)
                    .font(.body)
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(
                selected ? theme.rowSelected : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        // The onboarding tour navigates into each destination and rings its
        // content, so the sidebar rows are no longer spotlight targets themselves.
        button
    }
}
