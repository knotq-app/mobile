import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var systemScheme
    @State private var showingCancelConfirm = false

    private var theme: KnotQTheme {
        KnotQTheme.resolve(mode: model.snapshot?.settings.themeMode, systemScheme: systemScheme)
    }

    var body: some View {
        let form = Form {
            Section {
                SyncSettingsCard(
                    theme: theme,
                    showingCancelConfirm: $showingCancelConfirm
                )
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 6, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Section(L10n.t("settings.appearance.section")) {
                Picker(L10n.t("settings.appearance.theme_label"), selection: Binding(
                    get: { model.snapshot?.settings.themeMode ?? "system" },
                    set: { model.setThemeMode($0) }
                )) {
                    Text(L10n.t("settings.appearance.theme_dark")).tag("dark")
                    Text(L10n.t("settings.appearance.theme_light")).tag("light")
                    Text(L10n.t("settings.appearance.theme_system")).tag("system")
                }
                .pickerStyle(.menu)
            }
            .listRowBackground(theme.bgModal)

            Section(L10n.t("settings.time.section")) {
                Picker(L10n.t("settings.time.clock_label"), selection: Binding(
                    get: { model.snapshot?.settings.timeFormat ?? "twelve_hour" },
                    set: { model.setTimeFormat($0) }
                )) {
                    Text(L10n.t("settings.time.clock_12h")).tag("twelve_hour")
                    Text(L10n.t("settings.time.clock_24h")).tag("twenty_four_hour")
                }
            }
            .listRowBackground(theme.bgModal)

            NotificationDefaultsSettingsSection(theme: theme)

            GoogleCalendarSettingsSection(theme: theme)

            SettingsHelpSection(theme: theme)
        }
        .scrollContentBackground(.hidden)
        .background(theme.bgApp)
        .navigationTitle(L10n.t("settings.header.title"))

        #if ACCOUNTS_ENABLED
        form
        .task {
            // Load products when an account has no entitlement, so the paywall can
            // show real prices.
            if let session = model.syncSession, !session.supportsSync {
                await model.loadSyncProducts()
            }
        }
        .confirmationDialog(
            L10n.t("mobile.settings.cancel_sync_subscription_title"),
            isPresented: $showingCancelConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.t("mobile.settings.cancel_sync_subscription_confirm"), role: .destructive) {
                Task { await model.cancelSyncSubscription() }
            }
            Button(L10n.t("mobile.settings.keep_sync"), role: .cancel) {}
        } message: {
            Text(L10n.t("mobile.settings.cancel_sync_subscription_message"))
        }
        #else
        form
        #endif
    }
}

struct GoogleCalendarSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    let theme: KnotQTheme
    @State private var accountPendingUnlink: MobileGoogleAccount?

    var body: some View {
        let accounts = model.snapshot?.settings.googleAccounts ?? []

        Section(L10n.t("settings.google_calendar.section")) {
            if accounts.isEmpty {
                LabeledContent(L10n.t("settings.google_calendar.status_label")) {
                    Text(L10n.t("settings.google_calendar.not_connected"))
                        .foregroundStyle(theme.textMuted)
                }
            } else {
                ForEach(accounts) { account in
                    GoogleCalendarAccountSettingsRow(
                        account: account,
                        theme: theme,
                        onUnlink: { accountPendingUnlink = account }
                    )
                }
                if let status = model.googleCalendarStatus, !status.isEmpty {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(theme.textMuted)
                }
                Button {
                    Task { await model.syncGoogleCalendars() }
                } label: {
                    if model.googleSyncInProgress {
                        Label(L10n.t("settings.google_calendar.syncing_button"), systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label(L10n.t("settings.google_calendar.sync_all_button"), systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(model.googleSyncInProgress || model.googleAuthInProgress)
            }
        }
        .listRowBackground(theme.bgModal)
        .confirmationDialog(
            L10n.t("settings.google_calendar.unlink_confirm_title"),
            isPresented: Binding(
                get: { accountPendingUnlink != nil },
                set: { isPresented in
                    if !isPresented {
                        accountPendingUnlink = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.t("settings.google_calendar.unlink_button"), role: .destructive) {
                guard let account = accountPendingUnlink else { return }
                model.unlinkGoogleCalendarAccount(account)
                accountPendingUnlink = nil
            }
            Button(L10n.t("settings.google_calendar.keep_account"), role: .cancel) {
                accountPendingUnlink = nil
            }
        } message: {
            let title = accountPendingUnlink?.title ?? L10n.t("settings.google_calendar.unlink_fallback_name")
            Text(L10n.t("settings.google_calendar.unlink_confirm_message", ["name": title]))
        }
    }
}

private struct GoogleCalendarAccountSettingsRow: View {
    let account: MobileGoogleAccount
    let theme: KnotQTheme
    let onUnlink: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(account.title)
                    .font(.body)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(account.detail)
                    .font(.footnote)
                    .foregroundStyle(theme.textMuted)
            }
            Spacer(minLength: 12)
            Button(L10n.t("settings.google_calendar.unlink_button"), role: .destructive, action: onUnlink)
                .buttonStyle(.borderless)
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(.vertical, 2)
    }
}
