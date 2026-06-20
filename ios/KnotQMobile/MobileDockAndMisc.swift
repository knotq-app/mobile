import StoreKit
import SwiftUI

struct SettingsThemeOption: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: systemImage)
                .frame(width: 18, alignment: .center)
            Text("  \(title)")
        }
    }
}

private struct SyncPanelState {
    let badge: String
    let detail: String
    let badgeBackground: Color
    let badgeForeground: Color
}

struct SyncSettingsCard: View {
    @EnvironmentObject private var model: AppModel
    let theme: KnotQTheme
    @Binding var showingCancelConfirm: Bool
    @State private var showingDeleteAccount = false

    private var state: SyncPanelState {
        if model.syncSession != nil && model.syncOffline {
            return SyncPanelState(
                badge: "Offline",
                detail: "Sync will retry when your connection is back.",
                badgeBackground: theme.isDark ? Color(hex: 0xf59e0b).opacity(0.16) : Color(hex: 0xd97706).opacity(0.10),
                badgeForeground: theme.isDark ? Color(hex: 0xf8d38d) : Color(hex: 0x9a4b00)
            )
        }
        if model.syncSession?.supportsSync == true && model.subscriptionCancelled {
            return SyncPanelState(
                badge: "Cancelled",
                detail: "Sync stays active until your billing period ends. Re-enable to keep it.",
                badgeBackground: theme.isDark ? Color(hex: 0xf59e0b).opacity(0.16) : Color(hex: 0xd97706).opacity(0.10),
                badgeForeground: theme.isDark ? Color(hex: 0xf8d38d) : Color(hex: 0x9a4b00)
            )
        }
        if model.syncSession?.supportsSync == true {
            return SyncPanelState(
                badge: "Subscribed",
                detail: "Workspace sync is active for this account.",
                badgeBackground: theme.isDark ? Color(hex: 0x30d158).opacity(0.15) : Color(hex: 0x1f8f4d).opacity(0.09),
                badgeForeground: theme.isDark ? Color(hex: 0x9af0b6) : Color(hex: 0x176b38)
            )
        }
        if model.syncSession != nil {
            return SyncPanelState(
                badge: "Not Subscribed",
                detail: "Subscribe to keep this workspace available across devices.",
                badgeBackground: theme.isDark ? Color(hex: 0xf59e0b).opacity(0.16) : Color(hex: 0xd97706).opacity(0.10),
                badgeForeground: theme.isDark ? Color(hex: 0xf8d38d) : Color(hex: 0x9a4b00)
            )
        }
        return SyncPanelState(
            badge: "Available",
            detail: "Sign in to keep this workspace available across devices.",
            badgeBackground: theme.isDark ? Color(hex: 0x3b82f6).opacity(0.16) : Color(hex: 0x2f67cf).opacity(0.09),
            badgeForeground: theme.isDark ? Color(hex: 0x9bc2ff) : Color(hex: 0x235ebe)
        )
    }

    private var detail: String {
        if model.syncSession != nil && model.syncOffline {
            return state.detail
        }
        return model.syncSession?.email ?? state.detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            bodyContent
        }
        .padding(12)
        .background(syncPanelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(syncPanelBorder, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(theme.isDark ? 0.30 : 0.09), radius: theme.isDark ? 10 : 7, x: 0, y: theme.isDark ? 5 : 3)
        .task { await loadProductsIfNeeded() }
        .onChange(of: model.syncSession?.supportsSync) { _, supportsSync in
            guard supportsSync == false else { return }
            Task { await model.loadSyncProducts() }
        }
        .sheet(isPresented: $showingDeleteAccount) {
            DeleteSyncAccountSheet(theme: theme)
                .environmentObject(model)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image("BrandLogo")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("KnotQ Sync")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(detail)
                        .font(.system(size: 11))
                        .lineSpacing(1)
                        .foregroundStyle(theme.textSoft)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(state.badge)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(state.badgeForeground)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(state.badgeBackground, in: Capsule())
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        if let session = model.syncSession {
            if session.supportsSync {
                enabledActions
            } else {
                upgradeActions
            }
        } else {
            // Straight to the browser in create-account mode — the hosted page
            // handles "already have an account? sign in", so there's no need for
            // an in-app chooser sheet first.
            Button("Sign in") {
                Task { await model.beginBrowserSignIn(mode: .createAccount) }
            }
            .buttonStyle(SyncCardButtonStyle(theme: theme, prominence: .primary))
            .frame(maxWidth: .infinity)
            .disabled(model.syncAuthInProgress)
        }
    }

    private var enabledActions: some View {
        HStack(spacing: 8) {
            if model.subscriptionCancelled {
                Button {
                    Task { await model.reEnableSyncSubscription() }
                } label: {
                    Text("Re-enable")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SyncCardButtonStyle(theme: theme, prominence: .primary))
                .disabled(model.syncAccountActionInProgress)
            } else {
                checkStatusButton
            }
            Spacer(minLength: 8)
            manageAccountMenu
        }
    }

    private var upgradeActions: some View {
        HStack(spacing: 8) {
            if model.syncProducts.isEmpty {
                Text("Loading subscription options…")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(model.syncProducts, id: \.id) { product in
                    Button {
                        Task { await model.purchaseSync(product) }
                    } label: {
                        HStack(spacing: 8) {
                            Text(model.syncProducts.count == 1 ? "Subscribe" : product.displayName)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(product.displayPrice)
                                .foregroundStyle(Color.white.opacity(0.78))
                        }
                    }
                    .buttonStyle(SyncCardButtonStyle(theme: theme, prominence: .primary))
                    .disabled(model.purchaseInProgress)
                }
            }

            manageAccountMenu
        }
    }

    /// Account housekeeping (sign out, cancel, delete) lives behind one standard
    /// menu so destructive options are reachable without dominating the card.
    private var manageAccountMenu: some View {
        Menu {
            // Restore only matters when this device shows no active subscription
            // (new device / reinstall). AppStore.sync() forces an Apple Account
            // auth prompt, so keep it out of the way until it's actually needed.
            if model.syncSession?.supportsSync != true {
                Button("Restore Purchases") {
                    Task { await model.restorePurchases() }
                }
                .disabled(model.purchaseInProgress)
            }
            Button("Sign Out") {
                model.signOutSync()
            }
            if model.syncSession?.supportsSync == true {
                if model.subscriptionCancelled {
                    Button("Re-enable Subscription") {
                        Task { await model.reEnableSyncSubscription() }
                    }
                    .disabled(model.syncAccountActionInProgress)
                } else {
                    Button("Cancel Subscription", role: .destructive) {
                        showingCancelConfirm = true
                    }
                }
            }
            Button("Delete Account", role: .destructive) {
                showingDeleteAccount = true
            }
        } label: {
            HStack(spacing: 4) {
                Text("Manage")
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12))
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 30)
            .background(theme.buttonBg, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .disabled(model.syncAccountActionInProgress)
    }

    private var checkStatusButton: some View {
        Button {
            Task { await model.refreshEntitlement() }
        } label: {
            if model.syncInProgress {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Resyncing...")
                }
            } else {
                Text("Resync")
            }
        }
        .buttonStyle(SyncCardButtonStyle(theme: theme))
        .disabled(model.syncInProgress || model.syncAccountActionInProgress)
    }

    private var syncPanelBackground: Color {
        theme.isDark ? Color(hex: 0x3b82f6).opacity(0.086) : Color(hex: 0xeaf2ff)
    }

    private var syncPanelBorder: Color {
        theme.isDark ? Color(hex: 0x7aa0ff).opacity(0.27) : Color(hex: 0x2f67cf).opacity(0.22)
    }

    private func loadProductsIfNeeded() async {
        guard let session = model.syncSession else { return }
        // Refresh the subscription lifecycle so a cancelled-but-active subscription
        // surfaces its re-enable affordance; load paywall products when not entitled.
        if session.supportsSync {
            await model.refreshAccountStatus()
        } else {
            await model.loadSyncProducts()
        }
    }
}

private struct DeleteSyncAccountSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let theme: KnotQTheme
    @State private var emailConfirmation = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case email
        case password
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let email = model.syncSession?.email {
                        LabeledContent("Account", value: email)
                    }
                    TextField("Email", text: $emailConfirmation)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .email)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                } header: {
                    Text("Confirm Deletion")
                } footer: {
                    Text("This schedules deletion of your sync account and cloud data. Local workspace files stay on this device. Cancel any active store subscription before deleting; billing continues through the store until you cancel it.")
                }

                if model.syncSession?.supportsSync == true && !model.subscriptionCancelled {
                    Section {
                        Button(subscriptionActionTitle) {
                            Task { await manageSubscription() }
                        }
                        .disabled(model.syncAccountActionInProgress)
                    }
                }

                if model.syncAccountActionInProgress {
                    Section {
                        ProgressView("Deleting account...")
                    }
                }
            }
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(model.syncAccountActionInProgress)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Delete", role: .destructive) {
                        Task { await deleteAccount() }
                    }
                    .disabled(!canDelete)
                }
            }
        }
        .tint(theme.accent)
        .onAppear {
            focusedField = .email
        }
    }

    private var canDelete: Bool {
        guard !model.syncAccountActionInProgress else { return false }
        guard !password.isEmpty else { return false }
        guard let accountEmail = model.syncSession?.email else { return false }
        let expected = accountEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return emailConfirmation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == expected
    }

    private func deleteAccount() async {
        await model.deleteSyncAccount(confirmEmail: emailConfirmation, password: password)
        if model.syncSession == nil {
            dismiss()
        }
    }

    private var subscriptionActionTitle: String {
        (model.subscriptionProvider ?? "").lowercased() == "web" ? "Cancel Subscription" : "Manage Subscription"
    }

    private func manageSubscription() async {
        let provider = (model.subscriptionProvider ?? "").lowercased()
        if provider == "web" {
            await model.cancelSyncSubscription()
        } else if provider == "google" {
            model.openManagePlaySubscription()
        } else {
            await model.openManageAppleSubscription()
        }
    }
}

private enum SyncCardButtonProminence {
    case primary
    case secondary
    case destructive
}

private struct SyncCardButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let theme: KnotQTheme
    var prominence: SyncCardButtonProminence = .secondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: prominence == .primary ? .semibold : .regular))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 30)
            .frame(maxWidth: prominence == .primary ? .infinity : nil)
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .opacity(isEnabled ? 1 : 0.52)
    }

    private var foreground: Color {
        switch prominence {
        case .primary:
            Color.white
        case .secondary:
            theme.textPrimary
        case .destructive:
            theme.danger
        }
    }

    private func background(pressed: Bool) -> Color {
        switch prominence {
        case .primary:
            pressed ? Color(hex: 0x1d4ed8) : Color(hex: 0x2563eb)
        case .secondary, .destructive:
            pressed ? theme.rowSelected : theme.buttonBg
        }
    }
}

struct NotificationDefaultsSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    let theme: KnotQTheme

    var body: some View {
        Section {
            Picker("Events", selection: eventOffsetBinding) {
                ForEach(eventDefaultNotificationOptions) { option in
                    Text(option.label).tag(option.offsetSecs)
                }
            }
            .pickerStyle(.menu)

            Picker("Assignments", selection: assignmentOffsetBinding) {
                ForEach(assignmentDefaultNotificationOptions) { option in
                    Text(option.label).tag(option.offsetSecs)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("Notifications")
        }
        .listRowBackground(theme.bgModal)
    }

    private var eventOffsetBinding: Binding<Int32> {
        Binding(
            get: { model.snapshot?.settings.eventNotificationOffsetSecs ?? defaultEventNotificationOffsetSecs },
            set: { offset in
                model.setNotificationDefaults(
                    eventOffsetSecs: offset,
                    assignmentOffsetSecs: model.snapshot?.settings.assignmentNotificationOffsetSecs ?? defaultAssignmentNotificationOffsetSecs
                )
            }
        )
    }

    private var assignmentOffsetBinding: Binding<Int32> {
        Binding(
            get: { model.snapshot?.settings.assignmentNotificationOffsetSecs ?? defaultAssignmentNotificationOffsetSecs },
            set: { offset in
                model.setNotificationDefaults(
                    eventOffsetSecs: model.snapshot?.settings.eventNotificationOffsetSecs ?? defaultEventNotificationOffsetSecs,
                    assignmentOffsetSecs: offset
                )
            }
        )
    }
}

// iPhone settings: the shared `SettingsForm` wrapped in its own NavigationStack
// (with dock clearance). On iPad the detail column provides the NavigationStack,
// so it hosts `SettingsForm` directly instead.
struct DesktopSettingsPane: View {
    @EnvironmentObject private var model: AppModel
    let theme: KnotQTheme

    var body: some View {
        NavigationStack {
            SettingsForm(theme: theme)
                .navigationTitle("Settings")
                .navigationDestination(for: SettingsRoute.self) { route in
                    switch route {
                    case .archive:
                        SettingsArchiveList(theme: theme)
                    }
                }
        }
        .tint(theme.accent)
    }
}

/// The settings `Form` on its own (no NavigationStack), so it can be hosted inside
/// either the iPhone NavigationStack or the iPad NavigationSplitView detail column.
struct SettingsForm: View {
    @EnvironmentObject private var model: AppModel
    let theme: KnotQTheme
    @State private var showingCancelConfirm = false

    var body: some View {
        Form {
            Section {
                SyncSettingsCard(
                    theme: theme,
                    showingCancelConfirm: $showingCancelConfirm
                )
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 6, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Section {
                Picker("Theme", selection: themeBinding) {
                    SettingsThemeOption(title: "Dark", systemImage: "moon.fill").tag("dark")
                    SettingsThemeOption(title: "Light", systemImage: "sun.max.fill").tag("light")
                    SettingsThemeOption(title: "System", systemImage: "circle.lefthalf.filled").tag("system")
                }
                .pickerStyle(.menu)
            } header: {
                Text("Appearance")
            }
            .listRowBackground(theme.bgModal)

            Section {
                Picker("Clock", selection: timeBinding) {
                    Text("12-hour").tag("twelve_hour")
                    Text("24-hour").tag("twenty_four_hour")
                }
                .pickerStyle(.menu)
            } header: {
                Text("Time")
            }
            .listRowBackground(theme.bgModal)

            NotificationDefaultsSettingsSection(theme: theme)

            SettingsArchiveSection(schemes: model.snapshot?.archivedSchemes ?? [], theme: theme)

            GoogleCalendarSettingsSection(theme: theme)

            SettingsHelpSection(theme: theme)

        }
        .scrollContentBackground(.hidden)
        .background(theme.bgApp)
        .tint(theme.accent)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 96)
        }
        .confirmationDialog(
            "Cancel sync subscription?",
            isPresented: $showingCancelConfirm,
            titleVisibility: .visible
        ) {
            Button("Cancel Subscription", role: .destructive) {
                Task { await model.cancelSyncSubscription() }
            }
            Button("Keep Sync", role: .cancel) {}
        } message: {
            Text("Your local workspace stays on this device. Paid sync may remain available until the current billing period ends.")
        }
    }

    private var themeBinding: Binding<String> {
        Binding(
            get: { model.snapshot?.settings.themeMode ?? "system" },
            set: { model.setThemeMode($0) }
        )
    }

    private var timeBinding: Binding<String> {
        Binding(
            get: { model.snapshot?.settings.timeFormat ?? "twelve_hour" },
            set: { model.setTimeFormat($0) }
        )
    }
}

struct SettingsHelpSection: View {
    let theme: KnotQTheme

    private let discordURL = URL(string: "https://discord.gg/zyeHB77scg")!

    var body: some View {
        Section {
            Link(destination: discordURL) {
                HStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Need help with anything?")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                        Text("Join the KnotQ Discord")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSoft)
                    }

                    Spacer(minLength: 12)

                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.textDim)
                }
                .padding(.vertical, 2)
            }
        }
        .listRowBackground(theme.bgModal)
    }
}

struct MobileDock: View {
    let selected: MobilePane
    let theme: KnotQTheme
    let onSelect: (MobilePane) -> Void

    private let panes: [MobilePane] = [.home, .calendar, .settings]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(panes) { pane in
                dockButton(pane)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(AnyShapeStyle(theme.bgToolbar), in: Capsule())
        .overlay(Capsule().strokeBorder(theme.borderOverlay, lineWidth: 0.5))
        .shadow(color: Color.black.opacity(theme.isDark ? 0.28 : 0.025), radius: theme.isDark ? 12 : 4, y: theme.isDark ? 4 : 1)
    }

    @ViewBuilder
    private func dockButton(_ pane: MobilePane) -> some View {
        let button = Button { onSelect(pane) } label: {
            Image(systemName: pane.icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(selected == pane ? theme.textPrimary : theme.textMuted)
                .frame(width: 46, height: 48)
                .background {
                    if selected == pane {
                        Circle()
                            .fill(theme.rowSelected)
                            .frame(width: 40, height: 40)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pane.title)

        // The onboarding tour navigates into each pane and rings its content, so
        // the dock buttons are no longer spotlight targets themselves.
        button
    }
}

struct ColorSwatchStrip: View {
    @EnvironmentObject private var model: AppModel
    let scheme: MobileScheme
    let theme: KnotQTheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach([0, 1, 5, 2, 3, 4], id: \.self) { index in
                Button {
                    model.setSchemeColor(id: scheme.id, colorIndex: Int32(index))
                } label: {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(schemeColor(Int32(index), dark: theme.isDark))
                        .frame(width: 18, height: 18)
                        .overlay {
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(scheme.colorIndex == Int32(index) ? theme.accent : Color.clear, lineWidth: 1.5)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ColorMenu: View {
    @EnvironmentObject private var model: AppModel
    let nodeID: String
    let colorIndex: Int32
    let theme: KnotQTheme

    var body: some View {
        Menu {
            ForEach(0..<6, id: \.self) { index in
                Button {
                    model.setSchemeColor(id: nodeID, colorIndex: Int32(index))
                } label: {
                    Label {
                        Text(index == Int(colorIndex) ? "Selected" : "")
                    } icon: {
                        Image(systemName: colorIndex == Int32(index) ? "checkmark.circle.fill" : "circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(
                                colorIndex == Int32(index) ? theme.textPrimary : schemeColor(Int32(index), dark: theme.isDark),
                                schemeColor(Int32(index), dark: theme.isDark)
                            )
                    }
                }
            }
        } label: {
            Label("Color", systemImage: "paintpalette")
        }
    }
}

struct EmptyState: View {
    let title: String
    let detail: String
    let theme: KnotQTheme

    var body: some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textDim)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(theme.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


struct MonthGridView: View {
    @EnvironmentObject private var model: AppModel
    let theme: KnotQTheme
    let initialDate: Date
    let onSelect: (Date) -> Void

    @State private var displayMonth = Date()
    @State private var dayOccurrences: [String: [MobileOccurrence]] = [:]

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1
        return calendar
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 0) {
                weekdayRow
                grid
            }
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(theme.bgModal)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(theme.borderOverlay, lineWidth: 0.8)
            )
            .padding(.horizontal, 12)
            Spacer(minLength: 0)
        }
        .padding(.top, 18)
        .background(theme.bgApp.ignoresSafeArea())
        .onAppear {
            displayMonth = startOfMonth(initialDate)
            loadMonth()
        }
    }

    private var header: some View {
        HStack {
            chevronButton(systemName: "chevron.left") { shiftMonth(-1) }
            Spacer()
            Text(monthTitle)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            chevronButton(systemName: "chevron.right") { shiftMonth(1) }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private func chevronButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(theme.accent)
                .frame(width: 34, height: 34)
                .background(Circle().fill(theme.buttonBg))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(calendar.veryShortStandaloneWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textMuted.opacity(theme.isDark ? 0.72 : 0.78))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private var grid: some View {
        let cells = monthCells
        return VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        dayCell(cells[row * 7 + col])
                    }
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private func dayCell(_ date: Date) -> some View {
        let inMonth = calendar.isDate(date, equalTo: displayMonth, toGranularity: .month)
        let isToday = calendar.isDateInToday(date)
        let isSelected = calendar.isDate(date, inSameDayAs: initialDate)
        let occurrences = dayOccurrences[AppModel.dateOnly(date)] ?? []
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onSelect(calendar.startOfDay(for: date))
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 15, weight: (isToday || (isSelected && !isToday)) ? .semibold : .regular))
                    .foregroundStyle(dayTextColor(inMonth: inMonth, isToday: isToday, isSelected: isSelected))
                    .frame(width: 34, height: 34)
                    .background(dayBackground(isToday: isToday, isSelected: isSelected))
                dots(for: occurrences)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dots(for occurrences: [MobileOccurrence]) -> some View {
        let dots = orderedDistinctDots(occurrences, limit: 4)
        return HStack(spacing: 3) {
            ForEach(dots, id: \.key) { dot in
                Circle()
                    .fill(dot.color)
                    .frame(width: 5, height: 5)
            }
        }
        .frame(height: 6)
    }

    private func orderedDistinctDots(_ occurrences: [MobileOccurrence], limit: Int) -> [(key: String, color: Color)] {
        var seen = Set<String>()
        var result: [(key: String, color: Color)] = []
        for occurrence in occurrences {
            let key = isDailyQueueOccurrence(occurrence) ? "daily" : "scheme-\(occurrence.colorIndex)"
            guard seen.insert(key).inserted else { continue }
            result.append((key, occurrenceSchemeColor(occurrence, dark: theme.isDark)))
            if result.count >= limit { break }
        }
        return result
    }

    @ViewBuilder
    private func dayBackground(isToday: Bool, isSelected: Bool) -> some View {
        let dayHighlight = calendarDayHighlightColor(dark: theme.isDark)
        if isToday || isSelected {
            Circle().fill(dayHighlight)
        }
    }

    private func dayTextColor(inMonth: Bool, isToday: Bool, isSelected: Bool) -> Color {
        if isToday || isSelected { return .white }
        return inMonth ? theme.textPrimary : theme.textMuted.opacity(0.35)
    }

    private var monthCells: [Date] {
        let first = startOfMonth(displayMonth)
        let weekday = calendar.component(.weekday, from: first)
        let gridStart = calendar.date(byAdding: .day, value: -(weekday - 1), to: first) ?? first
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: displayMonth)
    }

    private func startOfMonth(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    private func shiftMonth(_ delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: displayMonth) {
            displayMonth = startOfMonth(next)
            loadMonth()
        }
    }

    private func loadMonth() {
        let requestedMonth = displayMonth
        let components = calendar.dateComponents([.year, .month], from: requestedMonth)
        guard let year = components.year, let month = components.month else { return }
        Task {
            let days = await model.monthDays(year: year, month: month)
            // The user may have paged to another month while this one loaded.
            guard displayMonth == requestedMonth else { return }
            var map: [String: [MobileOccurrence]] = [:]
            for day in days {
                map[day.date] = day.occurrences
            }
            dayOccurrences = map
        }
    }
}
