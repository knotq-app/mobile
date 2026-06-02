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

struct SyncSignInSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let theme: KnotQTheme

    @State private var apiBase = "http://127.0.0.1:8787"
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""

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

                if let challenge = model.syncLoginChallenge {
                    Section("Two-factor code") {
                        Text("Enter the code we emailed to \(challenge.email).")
                            .font(.footnote)
                            .foregroundStyle(theme.textSoft)
                        TextField("6-digit code", text: $code)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numberPad)
                        Button {
                            Task {
                                await model.verifyLoginCode(code)
                                if model.syncSession != nil {
                                    dismiss()
                                }
                            }
                        } label: {
                            if model.syncAuthInProgress {
                                ProgressView()
                            } else {
                                Text("Verify")
                            }
                        }
                        .disabled(model.syncAuthInProgress || code.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Use a different account") {
                            model.cancelLoginChallenge()
                            code = ""
                        }
                        .foregroundStyle(theme.textDim)
                    }
                    .listRowBackground(theme.bgModal)
                } else {
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
            // Against a dev backend the emailed code is echoed back; prefill it so
            // local testing is one tap. Real backends never send it.
            .onChange(of: model.syncLoginChallenge?.challengeId) { _, _ in
                if let devCode = model.syncLoginChallenge?.devCode {
                    code = devCode
                }
            }
        }
        .tint(theme.accent)
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
                UpcomingSection(title: "Assignments", empty: "None", occurrences: assignments, theme: theme, timeFormat: timeFormat, onToggleOccurrence: onToggleOccurrence, onOpenOccurrence: onOpenOccurrence)
                UpcomingSection(title: "Reminders", empty: "None", occurrences: reminders, theme: theme, timeFormat: timeFormat, onToggleOccurrence: onToggleOccurrence, onOpenOccurrence: onOpenOccurrence)
                UpcomingSection(title: "Upcoming", empty: "None today", occurrences: upcomingEvents, theme: theme, timeFormat: timeFormat, onToggleOccurrence: onToggleOccurrence, onOpenOccurrence: onOpenOccurrence)
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

    /// Mirrors the desktop upcoming panel (`render_upcoming`): due-dated tasks
    /// (assignments) and alert points (reminders) span overdue + upcoming, while
    /// the "Upcoming" bucket is today's (and still-overdue) events only.
    private var assignments: [MobileOccurrence] {
        bucket(kind: "assignment", base: overduePlusUpcoming)
    }

    private var reminders: [MobileOccurrence] {
        bucket(kind: "reminder", base: overduePlusUpcoming)
    }

    private var upcomingEvents: [MobileOccurrence] {
        bucket(kind: "event", base: (calendar?.overdue ?? []) + todayOccurrences)
    }

    private var overduePlusUpcoming: [MobileOccurrence] {
        (calendar?.overdue ?? []) + (calendar?.upcoming ?? [])
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
/// (Home/Calendar/Daily/Settings) as native rows, then the reused UIKit scheme
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 2) {
                row(.home, title: "Home", icon: "square.stack.3d.up", color: theme.accent)
                row(.calendar, title: "Calendar", icon: "calendar", color: theme.textPrimary)
                row(.daily, title: "Daily", icon: "checklist", color: dailyQueueColor(dark: theme.isDark))
                row(.settings, title: "Settings", icon: "gearshape", color: theme.textDim)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            HStack(spacing: 6) {
                Text("Schemes")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.textDim)
                Spacer(minLength: 0)
                Menu {
                    Button("New Scheme", systemImage: "doc.badge.plus", action: onNewScheme)
                    Button("Folder", systemImage: "folder.badge.plus", action: onNewFolder)
                    Button("Google Calendar", systemImage: "calendar.badge.plus") {
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
                onOpenScheme: onSelectScheme
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bgSidebar.ignoresSafeArea())
    }

    @ViewBuilder
    private func row(_ item: SidebarItem, title: String, icon: String, color: Color) -> some View {
        let selected = selection == item
        Button {
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
    }
}

