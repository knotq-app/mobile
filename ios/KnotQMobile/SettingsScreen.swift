import SwiftUI

/// Trims whatever the core reports about a Google Calendar sync down to the part
/// worth putting on screen.
///
/// The core passes transport failures through verbatim, so settings was showing
/// the raw payload — five lines of
/// `mbhat@…: Google OAuth HTTP 400: { "error": "invalid_request", … }` — in the
/// middle of the form. Serialized detail belongs in the logs; a JSON brace tells
/// nobody anything.
///
/// Deliberately only *trims*, and invents no wording of its own: new copy would
/// need keys in the shared `app/l10n` catalog (and a regenerate across three
/// repos), and an untranslated English sentence here would be worse than the
/// core's own already-localized message. So: drop the payload, flatten to one
/// line, cap the length.
enum GoogleCalendarStatusText {
    /// The trimmed form, or nil when there is nothing worth showing.
    static func readable(_ raw: String?) -> String? {
        guard let raw else { return nil }
        // Anything from the first brace on is a serialized payload.
        let collapsed = raw
            .prefix(while: { $0 != "{" })
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t:;,-–—"))
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > maxLength
            ? String(collapsed.prefix(maxLength - 1)) + "…"
            : collapsed
    }

    /// Roughly three lines at footnote size on the narrowest supported phone.
    private static let maxLength = 160
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
                if let status = GoogleCalendarStatusText.readable(model.googleCalendarStatus) {
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
            connectAccountButton(hasAccounts: !accounts.isEmpty)
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

    /// Links a Google account from Settings, the way the Android settings page
    /// already does. The only other way in is the add menu on a folder, which
    /// gives a user who wants to connect an account nowhere obvious to look.
    private func connectAccountButton(hasAccounts: Bool) -> some View {
        Button {
            Task { await model.connectGoogleCalendar() }
        } label: {
            if model.googleAuthInProgress {
                Label(L10n.t("mobile.settings.google_connecting"), systemImage: "arrow.triangle.2.circlepath")
            } else {
                Label(
                    L10n.t(
                        hasAccounts
                            ? "mobile.settings.connect_another_google_account"
                            : "mobile.settings.connect_google_calendar"
                    ),
                    systemImage: "plus.circle"
                )
            }
        }
        .disabled(model.googleAuthInProgress || model.googleSyncInProgress)
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

enum UpcomingDisplayDefaults {
    static let eventLookaheadDays: Int32 = 14
    static let reminderLookaheadDays: Int32 = 14
    static let assignmentLookaheadDays: Int32 = 14
    static let maximumItems: Int32 = 14
    static let showOverdue = true
    static let showCompleted = true
}

private struct LookaheadOption: Identifiable {
    let days: Int32
    var id: Int32 { days }

    var label: String {
        switch days {
        case 7: L10n.plural("sync.disclosure.period_weeks", 1)
        case 14: L10n.plural("sync.disclosure.period_weeks", 2)
        case 30: L10n.plural("sync.disclosure.period_months", 1)
        case 90: L10n.plural("sync.disclosure.period_months", 3)
        case 180: L10n.plural("sync.disclosure.period_months", 6)
        case 365: L10n.plural("sync.disclosure.period_years", 1)
        default: L10n.plural("sync.disclosure.period_days", Int(days))
        }
    }
}

struct TimingSettingsScreen: View {
    @EnvironmentObject private var model: AppModel
    let theme: KnotQTheme

    private let lookaheadOptions = [1, 2, 3, 7, 14, 30, 90, 180, 365]
        .map { LookaheadOption(days: Int32($0)) }
    private let itemLimitOptions: [Int32] = [5, 10, 14, 20, 30, 50, 100]

    var body: some View {
        Form {
            Section {
                Picker(L10n.t("settings.time.clock_label"), selection: timeFormatBinding) {
                    Text(L10n.t("settings.time.clock_12h")).tag("twelve_hour")
                    Text(L10n.t("settings.time.clock_24h")).tag("twenty_four_hour")
                }
                .pickerStyle(.menu)
            } header: {
                Text(L10n.t("settings.time.section"))
            }
            .listRowBackground(theme.bgModal)

            Section {
                lookaheadPicker(
                    L10n.t("settings.notifications.events_label"),
                    selection: eventLookaheadBinding
                )
                lookaheadPicker(
                    L10n.t("upcoming.section.reminders"),
                    selection: reminderLookaheadBinding
                )
                lookaheadPicker(
                    L10n.t("upcoming.section.assignments"),
                    selection: assignmentLookaheadBinding
                )
            } header: {
                Text(L10n.t("settings.display.upcoming_section"))
            } footer: {
                Text(L10n.t("settings.display.lookahead_footer"))
            }
            .listRowBackground(theme.bgModal)

            Section {
                Toggle(L10n.t("settings.display.show_overdue"), isOn: showOverdueBinding)
                Toggle(L10n.t("settings.display.show_completed"), isOn: showCompletedBinding)
                Picker(L10n.t("settings.display.maximum_items"), selection: maximumItemsBinding) {
                    ForEach(itemLimitOptions, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text(L10n.t("settings.display.visibility_section"))
            }
            .listRowBackground(theme.bgModal)

            NotificationDefaultsSettingsSection(theme: theme)

            Section {
                Button(L10n.t("settings.display.restore_defaults"), action: restoreDefaults)
                    .disabled(isUsingDefaults)
            }
            .listRowBackground(theme.bgModal)
        }
        .navigationTitle(L10n.t("settings.timing.title"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(theme.bgApp)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(theme.bgApp, for: .navigationBar)
        .tint(theme.accent)
    }

    @ViewBuilder
    private func lookaheadPicker(_ title: String, selection: Binding<Int32>) -> some View {
        Picker(title, selection: selection) {
            ForEach(lookaheadOptions) { option in
                Text(option.label).tag(option.days)
            }
        }
        .pickerStyle(.menu)
    }

    private var settings: MobileSettings? { model.snapshot?.settings }

    private var timeFormatBinding: Binding<String> {
        Binding(
            get: { settings?.timeFormat ?? "twelve_hour" },
            set: { model.setTimeFormat($0) }
        )
    }

    private var eventLookaheadBinding: Binding<Int32> {
        Binding(
            get: { settings?.eventLookaheadDays ?? UpcomingDisplayDefaults.eventLookaheadDays },
            set: { update(eventLookaheadDays: $0) }
        )
    }

    private var reminderLookaheadBinding: Binding<Int32> {
        Binding(
            get: { settings?.reminderLookaheadDays ?? UpcomingDisplayDefaults.reminderLookaheadDays },
            set: { update(reminderLookaheadDays: $0) }
        )
    }

    private var assignmentLookaheadBinding: Binding<Int32> {
        Binding(
            get: { settings?.assignmentLookaheadDays ?? UpcomingDisplayDefaults.assignmentLookaheadDays },
            set: { update(assignmentLookaheadDays: $0) }
        )
    }

    private var maximumItemsBinding: Binding<Int32> {
        Binding(
            get: { settings?.maximumUpcomingItems ?? UpcomingDisplayDefaults.maximumItems },
            set: { update(maximumItems: $0) }
        )
    }

    private var showOverdueBinding: Binding<Bool> {
        Binding(
            get: { settings?.showOverdue ?? UpcomingDisplayDefaults.showOverdue },
            set: { update(showOverdue: $0) }
        )
    }

    private var showCompletedBinding: Binding<Bool> {
        Binding(
            get: { settings?.showCompleted ?? UpcomingDisplayDefaults.showCompleted },
            set: { update(showCompleted: $0) }
        )
    }

    private func update(
        eventLookaheadDays: Int32? = nil,
        reminderLookaheadDays: Int32? = nil,
        assignmentLookaheadDays: Int32? = nil,
        maximumItems: Int32? = nil,
        showOverdue: Bool? = nil,
        showCompleted: Bool? = nil
    ) {
        model.setUpcomingDisplaySettings(
            eventLookaheadDays: eventLookaheadDays
                ?? settings?.eventLookaheadDays
                ?? UpcomingDisplayDefaults.eventLookaheadDays,
            reminderLookaheadDays: reminderLookaheadDays
                ?? settings?.reminderLookaheadDays
                ?? UpcomingDisplayDefaults.reminderLookaheadDays,
            assignmentLookaheadDays: assignmentLookaheadDays
                ?? settings?.assignmentLookaheadDays
                ?? UpcomingDisplayDefaults.assignmentLookaheadDays,
            maximumItems: maximumItems
                ?? settings?.maximumUpcomingItems
                ?? UpcomingDisplayDefaults.maximumItems,
            showOverdue: showOverdue
                ?? settings?.showOverdue
                ?? UpcomingDisplayDefaults.showOverdue,
            showCompleted: showCompleted
                ?? settings?.showCompleted
                ?? UpcomingDisplayDefaults.showCompleted
        )
    }

    private var isUsingDefaults: Bool {
        (settings?.eventLookaheadDays ?? UpcomingDisplayDefaults.eventLookaheadDays)
            == UpcomingDisplayDefaults.eventLookaheadDays
            && (settings?.reminderLookaheadDays ?? UpcomingDisplayDefaults.reminderLookaheadDays)
                == UpcomingDisplayDefaults.reminderLookaheadDays
            && (settings?.assignmentLookaheadDays ?? UpcomingDisplayDefaults.assignmentLookaheadDays)
                == UpcomingDisplayDefaults.assignmentLookaheadDays
            && (settings?.maximumUpcomingItems ?? UpcomingDisplayDefaults.maximumItems)
                == UpcomingDisplayDefaults.maximumItems
            && (settings?.showOverdue ?? UpcomingDisplayDefaults.showOverdue)
                == UpcomingDisplayDefaults.showOverdue
            && (settings?.showCompleted ?? UpcomingDisplayDefaults.showCompleted)
                == UpcomingDisplayDefaults.showCompleted
            && (settings?.eventNotificationOffsetSecs ?? defaultEventNotificationOffsetSecs)
                == defaultEventNotificationOffsetSecs
            && (settings?.assignmentNotificationOffsetSecs ?? defaultAssignmentNotificationOffsetSecs)
                == defaultAssignmentNotificationOffsetSecs
            && (settings?.timeFormat ?? "twelve_hour") == "twelve_hour"
    }

    private func restoreDefaults() {
        model.setUpcomingDisplaySettings(
            eventLookaheadDays: UpcomingDisplayDefaults.eventLookaheadDays,
            reminderLookaheadDays: UpcomingDisplayDefaults.reminderLookaheadDays,
            assignmentLookaheadDays: UpcomingDisplayDefaults.assignmentLookaheadDays,
            maximumItems: UpcomingDisplayDefaults.maximumItems,
            showOverdue: UpcomingDisplayDefaults.showOverdue,
            showCompleted: UpcomingDisplayDefaults.showCompleted
        )
        model.setNotificationDefaults(
            eventOffsetSecs: defaultEventNotificationOffsetSecs,
            assignmentOffsetSecs: defaultAssignmentNotificationOffsetSecs
        )
        model.setTimeFormat("twelve_hour")
    }
}
