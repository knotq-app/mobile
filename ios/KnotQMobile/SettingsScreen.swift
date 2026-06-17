import StoreKit
import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var systemScheme
    @State private var showingCancelConfirm = false

    private var theme: KnotQTheme {
        KnotQTheme.resolve(mode: model.snapshot?.settings.themeMode, systemScheme: systemScheme)
    }

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

            Section("Appearance") {
                Picker("Theme", selection: Binding(
                    get: { model.snapshot?.settings.themeMode ?? "dark" },
                    set: { model.setThemeMode($0) }
                )) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                    Text("System").tag("system")
                }
                .pickerStyle(.menu)
            }
            .listRowBackground(theme.bgModal)

            Section("Time") {
                Picker("Clock", selection: Binding(
                    get: { model.snapshot?.settings.timeFormat ?? "twelve_hour" },
                    set: { model.setTimeFormat($0) }
                )) {
                    Text("12-hour").tag("twelve_hour")
                    Text("24-hour").tag("twenty_four_hour")
                }
            }
            .listRowBackground(theme.bgModal)

            NotificationDefaultsSettingsSection(theme: theme)

            GoogleCalendarSettingsSection(theme: theme)
        }
        .scrollContentBackground(.hidden)
        .background(theme.bgApp)
        .navigationTitle("Settings")
        .task {
            // Load products when an account has no entitlement, so the paywall can
            // show real prices.
            if let session = model.syncSession, !session.supportsSync {
                await model.loadSyncProducts()
            }
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
}

struct GoogleCalendarSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    let theme: KnotQTheme
    @State private var accountPendingUnlink: MobileGoogleAccount?

    var body: some View {
        let accounts = model.snapshot?.settings.googleAccounts ?? []

        Section("Google Calendar") {
            if accounts.isEmpty {
                LabeledContent("Status") {
                    Text("Not connected")
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
                        Label("Syncing Google Calendars", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("Sync Google Calendars", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(model.googleSyncInProgress || model.googleAuthInProgress)
            }
        }
        .listRowBackground(theme.bgModal)
        .confirmationDialog(
            "Unlink Google Calendar account?",
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
            Button("Unlink", role: .destructive) {
                guard let account = accountPendingUnlink else { return }
                model.unlinkGoogleCalendarAccount(account)
                accountPendingUnlink = nil
            }
            Button("Keep Account", role: .cancel) {
                accountPendingUnlink = nil
            }
        } message: {
            let title = accountPendingUnlink?.title ?? "this account"
            Text("KnotQ will stop refreshing calendars for \(title). Imported calendar schemes stay in your workspace.")
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
            Button("Unlink", role: .destructive, action: onUnlink)
                .buttonStyle(.borderless)
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(.vertical, 2)
    }
}
