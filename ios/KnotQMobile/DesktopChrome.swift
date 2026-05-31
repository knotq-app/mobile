import SwiftUI

struct DesktopTitleBar: View {
    let title: String
    let pane: MobilePane
    let scheme: MobileScheme?
    let theme: KnotQTheme
    let onSearch: () -> Void
    let onAddCalendar: () -> Void
    let onAddItem: () -> Void
    let onNewScheme: () -> Void
    let onNewFolder: () -> Void
    let onGoogleCalendar: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(markerColor)
                .frame(width: 14, height: 14)

            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(TitleIconButton(theme: theme))

                Menu {
                    Button("Calendar Item", systemImage: "calendar.badge.plus", action: onAddCalendar)
                    Button("Item", systemImage: "plus", action: onAddItem)
                        .disabled(!(pane == .daily || (pane == .scheme && scheme?.isReadOnly != true)))
                    Button("New Scheme", systemImage: "doc.badge.plus", action: onNewScheme)
                    Button("Folder", systemImage: "folder.badge.plus", action: onNewFolder)
                    Button("Google Calendar", systemImage: "calendar.badge.plus", action: onGoogleCalendar)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(TitleIconButton(theme: theme))

                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(TitleIconButton(theme: theme))
            }
        }
        .frame(height: 34)
        .padding(.horizontal, 12)
        .background(theme.bgToolbar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.divider).frame(height: 1)
        }
    }

    private var markerColor: Color {
        if let scheme, pane == .scheme {
            return schemeColor(scheme.colorIndex, dark: theme.isDark)
        }
        if pane == .daily {
            return dailyQueueColor(dark: theme.isDark)
        }
        if pane == .home {
            return theme.accent
        }
        if pane == .calendar {
            return theme.textPrimary
        }
        return theme.textDim
    }
}

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

struct SyncSignInSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let theme: KnotQTheme

    @State private var apiBase = "http://127.0.0.1:8787"
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                if let session = model.syncSession {
                    Section("Current account") {
                        LabeledContent("Email", value: session.email)
                        LabeledContent("Backend", value: session.apiBase)
                        Button("Sign out", role: .destructive) {
                            model.signOutSync()
                            password = ""
                        }
                    }
                    .listRowBackground(theme.bgModal)
                }

                Section("Local sync backend") {
                    TextField("Sync API", text: $apiBase)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                    SecureField("Password", text: $password)
                    Button {
                        Task {
                            await model.signInToSync(apiBase: apiBase, email: email, password: password)
                            if model.syncSession != nil {
                                dismiss()
                            }
                        }
                    } label: {
                        if model.syncAuthInProgress {
                            ProgressView()
                        } else {
                            Text("Sign in")
                        }
                    }
                    .disabled(model.syncAuthInProgress)
                }
                .listRowBackground(theme.bgModal)
            }
            .scrollContentBackground(.hidden)
            .background(theme.bgApp)
            .navigationTitle("Sync account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                apiBase = model.syncSession?.apiBase ?? apiBase
                email = model.syncSession?.email ?? email
            }
        }
        .tint(theme.accent)
    }
}

struct DesktopNavigator: View {
    let root: MobileNode?
    let selectedPane: MobilePane
    let selectedSchemeID: String?
    let theme: KnotQTheme
    let onSelectPane: (MobilePane) -> Void
    let onSelectScheme: (String) -> Void
    let onNewScheme: () -> Void
    let onNewFolder: () -> Void
    let onGoogleCalendar: (String?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                NavigatorSpecialRow(title: "Home", color: theme.accent, selected: selectedPane == .home, theme: theme) {
                    onSelectPane(.home)
                }
                NavigatorSpecialRow(title: "Calendar", color: theme.textPrimary, selected: selectedPane == .calendar, theme: theme) {
                    onSelectPane(.calendar)
                }
                NavigatorSpecialRow(title: "Daily", color: dailyQueueColor(dark: theme.isDark), selected: selectedPane == .daily, theme: theme) {
                    onSelectPane(.daily)
                }
            }
            .padding(.bottom, 7)

            Rectangle().fill(theme.divider).frame(height: 1).padding(.horizontal, 3).padding(.bottom, 8)

            SchemeNavigatorListView(
                root: root,
                selectedSchemeID: selectedSchemeID,
                theme: theme,
                compact: true,
                onOpenScheme: onSelectScheme
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 6) {
                Menu {
                    Button("New Scheme", systemImage: "doc.badge.plus", action: onNewScheme)
                    Button("Folder", systemImage: "folder.badge.plus", action: onNewFolder)
                    Button("Google Calendar", systemImage: "calendar.badge.plus") {
                        onGoogleCalendar(nil)
                    }
                } label: {
                    Label("New", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textDim)

                Button {
                    onSelectPane(.settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(TitleIconButton(theme: theme))
            }
            .padding(.top, 5)
        }
        .padding(.top, 10)
        .padding(.horizontal, 7)
        .padding(.bottom, 8)
        .background(theme.bgSidebar, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(theme.borderOverlay, lineWidth: 1)
        }
        .shadow(color: .black.opacity(theme.isDark ? 0.18 : 0.035), radius: theme.isDark ? 9 : 5, x: 0, y: theme.isDark ? 5 : 2)
    }
}

struct NavigatorSpecialRow: View {
    let title: String
    let color: Color
    let selected: Bool
    let theme: KnotQTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 11, height: 11)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 25)
            .padding(.horizontal, 6)
            .foregroundStyle(theme.textPrimary)
            .background(selected ? theme.rowSelected : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
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
    let theme: KnotQTheme
    let timeFormat: String
    let onToggleOccurrence: (MobileOccurrence) -> Void
    let onOpenOccurrence: (MobileOccurrence) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                UpcomingSection(title: "Overdue", empty: "None", occurrences: calendar?.overdue ?? [], theme: theme, timeFormat: timeFormat, onToggleOccurrence: onToggleOccurrence, onOpenOccurrence: onOpenOccurrence)
                UpcomingSection(title: "Today", empty: "None today", occurrences: todayOccurrences, theme: theme, timeFormat: timeFormat, onToggleOccurrence: onToggleOccurrence, onOpenOccurrence: onOpenOccurrence)
                UpcomingSection(title: "Upcoming", empty: "None", occurrences: calendar?.upcoming ?? [], theme: theme, timeFormat: timeFormat, onToggleOccurrence: onToggleOccurrence, onOpenOccurrence: onOpenOccurrence)
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)
        }
        .background(theme.bgApp)
    }

    private var todayOccurrences: [MobileOccurrence] {
        guard let today = calendar?.days.first(where: { $0.date == AppModel.dateOnly(Date()) }) else {
            return []
        }
        return today.occurrences
    }
}

