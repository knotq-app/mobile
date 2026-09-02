#if ACCOUNTS_ENABLED
import StoreKit
#endif
import SwiftUI

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
        #if !ACCOUNTS_ENABLED
        return SyncPanelState(
            badge: L10n.t("web.download.get_app"),
            detail: L10n.t("web.account.sync_promo_tagline"),
            badgeBackground: theme.isDark ? Color(hex: 0x3b82f6).opacity(0.16) : Color(hex: 0x2f67cf).opacity(0.09),
            badgeForeground: theme.isDark ? Color(hex: 0x9bc2ff) : Color(hex: 0x235ebe)
        )
        #else
        if model.syncSession != nil && model.syncOffline {
            return SyncPanelState(
                badge: L10n.t("sync.status.offline"),
                detail: L10n.t("mobile.sync.offline_detail"),
                badgeBackground: theme.isDark ? Color(hex: 0xf59e0b).opacity(0.16) : Color(hex: 0xd97706).opacity(0.10),
                badgeForeground: theme.isDark ? Color(hex: 0xf8d38d) : Color(hex: 0x9a4b00)
            )
        }
        if model.syncSession?.supportsSync == true && model.subscriptionCancelled {
            return SyncPanelState(
                badge: L10n.t("settings.sync.badge_cancelled"),
                detail: L10n.t("mobile.sync.cancelled_detail"),
                badgeBackground: theme.isDark ? Color(hex: 0xf59e0b).opacity(0.16) : Color(hex: 0xd97706).opacity(0.10),
                badgeForeground: theme.isDark ? Color(hex: 0xf8d38d) : Color(hex: 0x9a4b00)
            )
        }
        if model.syncSession?.supportsSync == true {
            return SyncPanelState(
                badge: L10n.t("settings.sync.badge_subscribed"),
                detail: L10n.t("settings.sync.detail_subscribed"),
                badgeBackground: theme.isDark ? Color(hex: 0x30d158).opacity(0.15) : Color(hex: 0x1f8f4d).opacity(0.09),
                badgeForeground: theme.isDark ? Color(hex: 0x9af0b6) : Color(hex: 0x176b38)
            )
        }
        if model.syncSession != nil && model.emailVerified == false {
            return SyncPanelState(
                badge: L10n.t("mobile.sync.badge_verify_email"),
                detail: L10n.t("mobile.sync.verify_email_detail"),
                badgeBackground: theme.isDark ? Color(hex: 0xf59e0b).opacity(0.16) : Color(hex: 0xd97706).opacity(0.10),
                badgeForeground: theme.isDark ? Color(hex: 0xf8d38d) : Color(hex: 0x9a4b00)
            )
        }
        if model.syncSession != nil {
            return SyncPanelState(
                badge: L10n.t("sync.status.sync_inactive"),
                detail: L10n.t("settings.sync.detail_available"),
                badgeBackground: theme.isDark ? Color(hex: 0xf59e0b).opacity(0.16) : Color(hex: 0xd97706).opacity(0.10),
                badgeForeground: theme.isDark ? Color(hex: 0xf8d38d) : Color(hex: 0x9a4b00)
            )
        }
        return SyncPanelState(
            badge: L10n.t("settings.sync.badge_available"),
            detail: L10n.t("settings.sync.detail_available"),
            badgeBackground: theme.isDark ? Color(hex: 0x3b82f6).opacity(0.16) : Color(hex: 0x2f67cf).opacity(0.09),
            badgeForeground: theme.isDark ? Color(hex: 0x9bc2ff) : Color(hex: 0x235ebe)
        )
        #endif
    }

    private var detail: String {
        #if !ACCOUNTS_ENABLED
        return state.detail
        #else
        if model.syncSession != nil && model.syncOffline {
            return state.detail
        }
        return model.syncSession?.email ?? state.detail
        #endif
    }

    var body: some View {
        let card = VStack(alignment: .leading, spacing: 11) {
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

        #if ACCOUNTS_ENABLED
        card
        #if IN_APP_PURCHASES_ENABLED
        .task { await loadProductsIfNeeded() }
        .onChange(of: model.syncSession?.supportsSync) { supportsSync in
            guard supportsSync == false else { return }
            Task { await model.loadSyncProducts() }
        }
        #endif
        .sheet(isPresented: $showingDeleteAccount) {
            DeleteSyncAccountSheet(theme: theme)
                .environmentObject(model)
        }
        #else
        card
        #endif
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
                    Text(L10n.t("settings.sync.title"))
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
        #if ACCOUNTS_ENABLED
        if let session = model.syncSession {
            if session.supportsSync {
                enabledActions
            } else if model.emailVerified == false {
                verifyEmailActions
            } else {
                #if IN_APP_PURCHASES_ENABLED
                upgradeActions
                #else
                manageOnlyActions
                #endif
            }
        } else {
            // This interim build supports an existing account and sync without
            // presenting any purchase flow in the app.
            Button(L10n.t("sync.sign_in")) {
                Task { await model.beginBrowserSignIn(mode: .signIn) }
            }
            .buttonStyle(SyncCardButtonStyle(theme: theme, prominence: .primary))
            .frame(maxWidth: .infinity)
            .disabled(model.syncAuthInProgress)
        }
        #else
        Text(L10n.t("mobile.sync.coming_soon_detail"))
            .font(.system(size: 12))
            .lineSpacing(1)
            .foregroundStyle(theme.textSoft)
            .fixedSize(horizontal: false, vertical: true)
        #endif
    }

    #if ACCOUNTS_ENABLED
    private var enabledActions: some View {
        HStack(spacing: 8) {
            #if IN_APP_PURCHASES_ENABLED
            if model.subscriptionCancelled {
                Button {
                    Task { await model.reEnableSyncSubscription() }
                } label: {
                    Text(L10n.t("account.reenable.label"))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SyncCardButtonStyle(theme: theme, prominence: .primary))
                .disabled(model.syncAccountActionInProgress)
            } else {
                checkStatusButton
            }
            #else
            checkStatusButton
            #endif
            Spacer(minLength: 8)
            manageAccountMenu
        }
    }

    #if IN_APP_PURCHASES_ENABLED
    private var upgradeActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if model.syncProducts.isEmpty {
                    Text(L10n.t("sync.products.loading"))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(model.syncProducts, id: \.id) { product in
                        Button {
                            Task { await model.purchaseSync(product) }
                        } label: {
                            HStack(spacing: 8) {
                                Text(model.syncProducts.count == 1 ? L10n.t("account.subscribe.label") : product.displayName)
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

            subscriptionDisclosure
        }
    }

    /// Auto-renewable-subscription disclosures required next to the purchase
    /// control (App Store Guideline 3.1.2): length, price-per-period, auto-renew
    /// statement, and functional Terms of Use (EULA) + Privacy Policy links.
    @ViewBuilder
    private var subscriptionDisclosure: some View {
        if let product = model.syncProducts.first {
            VStack(alignment: .leading, spacing: 5) {
                Text(disclosureText(for: product))
                    .font(.system(size: 10))
                    .lineSpacing(1)
                    .foregroundStyle(theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Link(L10n.t("sync.disclosure.terms_of_use"), destination: SyncSettingsCard.termsURL)
                    Link(L10n.t("sync.disclosure.privacy_policy"), destination: SyncSettingsCard.privacyURL)
                }
                .font(.system(size: 10, weight: .medium))
                .tint(theme.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let termsURL = URL(string: "https://www.knotq.com/terms.html")!
    private static let privacyURL = URL(string: "https://www.knotq.com/privacy.html")!

    private func disclosureText(for product: Product) -> String {
        let period = product.subscription
            .map { Self.periodDescription($0.subscriptionPeriod) } ?? L10n.t("sync.disclosure.period_generic")
        return L10n.t("sync.disclosure.subscription_terms", [
            "price": product.displayPrice,
            "period": period,
        ])
    }

    /// "month" / "year" / "2 weeks" etc. for the auto-renew disclosure.
    private static func periodDescription(_ period: Product.SubscriptionPeriod) -> String {
        let key: String
        switch period.unit {
        case .day: key = "sync.disclosure.period_days"
        case .week: key = "sync.disclosure.period_weeks"
        case .month: key = "sync.disclosure.period_months"
        case .year: key = "sync.disclosure.period_years"
        @unknown default: return L10n.t("sync.disclosure.period_generic")
        }
        return L10n.plural(key, period.value)
    }
    #endif

    /// Interim account surface while App Store purchases are awaiting approval.
    /// Existing entitled accounts continue to sync; this intentionally contains no
    /// offer, pricing, restore, or external purchase link.
    private var manageOnlyActions: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            manageAccountMenu
        }
    }

    /// Shown when the account email isn't verified: subscribing is blocked, so we
    /// explain why and offer to resend the verification link (with a soft cooldown).
    private var verifyEmailActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("account.verify.notice"))
                .font(.system(size: 11))
                .lineSpacing(1)
                .foregroundStyle(theme.isDark ? Color(hex: 0xf8d38d) : Color(hex: 0x9a4b00))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button {
                    Task { await model.resendVerificationEmail() }
                } label: {
                    Text(resendLabel)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SyncCardButtonStyle(theme: theme, prominence: .primary))
                .disabled(model.resendVerificationInProgress || model.resendVerificationCooldown > 0)
                Spacer(minLength: 8)
                manageAccountMenu
            }
        }
    }

    private var resendLabel: String {
        if model.resendVerificationInProgress { return L10n.t("account.verify.sending") }
        if model.resendVerificationCooldown > 0 {
            return L10n.t("account.verify.resend_countdown", ["seconds": "\(model.resendVerificationCooldown)"])
        }
        return L10n.t("account.verify.resend")
    }

    /// Account housekeeping (sign out, cancel, delete) lives behind one standard
    /// menu so destructive options are reachable without dominating the card.
    private var manageAccountMenu: some View {
        Menu {
            #if IN_APP_PURCHASES_ENABLED
            // Restore only matters when this device shows no active subscription
            // (new device / reinstall). AppStore.sync() forces an Apple Account
            // auth prompt, so keep it out of the way until it's actually needed.
            if model.syncSession?.supportsSync != true {
                Button(L10n.t("mobile.sync.restore_purchases_ios")) {
                    Task { await model.restorePurchases() }
                }
                .disabled(model.purchaseInProgress)
            }
            if model.syncSession?.supportsSync == true {
                if model.subscriptionCancelled {
                    Button(L10n.t("mobile.sync.reenable_subscription")) {
                        Task { await model.reEnableSyncSubscription() }
                    }
                    .disabled(model.syncAccountActionInProgress)
                } else {
                    Button(L10n.t("mobile.settings.cancel_sync_subscription_confirm"), role: .destructive) {
                        showingCancelConfirm = true
                    }
                }
            }
            #endif
            // Sign-out is account/session housekeeping, not a StoreKit action.
            // Keep it available in accounts-only builds as well, so a stalled
            // transport can be reset without deleting local workspace data.
            Button(L10n.t("mobile.sync.sign_out")) {
                model.signOutSync()
            }
            Button(L10n.t("mobile.sync.delete_account"), role: .destructive) {
                showingDeleteAccount = true
            }
        } label: {
            HStack(spacing: 4) {
                Text(L10n.t("account.manage.label"))
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
                    Text(L10n.t("sync.action.resyncing"))
                }
            } else {
                Text(L10n.t("sync.action.resync"))
            }
        }
        .buttonStyle(SyncCardButtonStyle(theme: theme))
        .disabled(model.syncInProgress || model.syncAccountActionInProgress)
    }
    #endif

    private var syncPanelBackground: Color {
        theme.isDark ? Color(hex: 0x3b82f6).opacity(0.086) : Color(hex: 0xeaf2ff)
    }

    private var syncPanelBorder: Color {
        theme.isDark ? Color(hex: 0x7aa0ff).opacity(0.27) : Color(hex: 0x2f67cf).opacity(0.22)
    }

    #if ACCOUNTS_ENABLED
    #if IN_APP_PURCHASES_ENABLED
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
    #endif
    #endif
}

#if ACCOUNTS_ENABLED
private struct DeleteSyncAccountSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let theme: KnotQTheme
    @State private var emailConfirmation = ""
    @State private var password = ""
    @State private var code = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case email
        case password
        case code
    }

    // Step 2 begins once the backend has accepted the re-auth and emailed a code.
    private var awaitingCode: Bool { model.pendingDeletionChallengeId != nil }

    var body: some View {
        NavigationStack {
            Form {
                if awaitingCode {
                    codeSection
                } else {
                    confirmSections
                }

                if model.syncAccountActionInProgress {
                    Section {
                        ProgressView(awaitingCode ? L10n.t("mobile.delete_account.deleting_progress") : L10n.t("mobile.delete_account.sending_code_progress"))
                    }
                }
            }
            .navigationTitle(L10n.t("mobile.sync.delete_account"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("common.cancel")) {
                        model.pendingDeletionChallengeId = nil
                        dismiss()
                    }
                    .disabled(model.syncAccountActionInProgress)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if awaitingCode {
                        Button(L10n.t("common.delete"), role: .destructive) {
                            Task { await confirmDeletion() }
                        }
                        .disabled(!canConfirmCode)
                    } else {
                        Button(L10n.t("mobile.delete_account.send_code")) {
                            Task { await requestDeletion() }
                        }
                        .disabled(!canRequestDeletion)
                    }
                }
            }
        }
        .tint(theme.accent)
        .onAppear {
            focusedField = awaitingCode ? .code : .email
        }
    }

    // Step 1: re-authenticate and (for store subscriptions) nudge to cancel first.
    @ViewBuilder
    private var confirmSections: some View {
        if hasActiveStoreSubscription {
            Section {
                Label {
                    Text(.init(L10n.t("mobile.delete_account.store_subscription_warning", ["store": subscriptionStoreName])))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Button(L10n.t("mobile.delete_account.manage_store_subscription", ["store": subscriptionStoreName])) {
                    Task { await manageSubscription() }
                }
                .disabled(model.syncAccountActionInProgress)
            } header: {
                Text(L10n.t("mobile.delete_account.cancel_subscription_first_header"))
            }
        }

        Section {
            if let email = model.syncSession?.email {
                LabeledContent(L10n.t("mobile.delete_account.account_label"), value: email)
            }
            TextField(L10n.t("mobile.delete_account.email_placeholder"), text: $emailConfirmation)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .email)
            SecureField(L10n.t("mobile.delete_account.password_placeholder"), text: $password)
                .textContentType(.password)
                .focused($focusedField, equals: .password)
        } header: {
            Text(L10n.t("mobile.delete_account.confirm_section_header"))
        } footer: {
            Text(L10n.t("mobile.delete_account.confirm_footer"))
        }

        if hasActiveWebSubscription {
            Section {
                Button(L10n.t("mobile.settings.cancel_sync_subscription_confirm")) {
                    Task { await manageSubscription() }
                }
                .disabled(model.syncAccountActionInProgress)
            }
        }
    }

    // Step 2: enter the emailed one-time code to actually schedule deletion.
    @ViewBuilder
    private var codeSection: some View {
        Section {
            TextField(L10n.t("mobile.delete_account.code_placeholder"), text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focusedField, equals: .code)
        } header: {
            Text(L10n.t("mobile.delete_account.code_section_header"))
        } footer: {
            Text(L10n.t("mobile.delete_account.code_footer", [
                "email": model.syncSession?.email ?? L10n.t("mobile.delete_account.email_fallback"),
            ]))
        }
    }

    private var canRequestDeletion: Bool {
        guard !model.syncAccountActionInProgress else { return false }
        guard !password.isEmpty else { return false }
        guard let accountEmail = model.syncSession?.email else { return false }
        let expected = accountEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return emailConfirmation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == expected
    }

    private var canConfirmCode: Bool {
        guard !model.syncAccountActionInProgress else { return false }
        return code.trimmingCharacters(in: .whitespacesAndNewlines).count == 6
    }

    private func requestDeletion() async {
        await model.requestSyncAccountDeletion(confirmEmail: emailConfirmation, password: password)
        if model.pendingDeletionChallengeId != nil {
            focusedField = .code
        }
    }

    private func confirmDeletion() async {
        await model.confirmSyncAccountDeletion(code: code)
        if model.syncSession == nil {
            dismiss()
        }
    }

    /// An active, not-yet-cancelled subscription billed through Apple/Google. These
    /// keep charging through the store even after the account is deleted, so we lead
    /// with a prominent warning and a shortcut to the store's cancel page.
    private var hasActiveStoreSubscription: Bool {
        guard model.syncSession?.supportsSync == true, !model.subscriptionCancelled else { return false }
        return (model.subscriptionProvider ?? "").lowercased() != "web"
    }

    private var hasActiveWebSubscription: Bool {
        guard model.syncSession?.supportsSync == true, !model.subscriptionCancelled else { return false }
        return (model.subscriptionProvider ?? "").lowercased() == "web"
    }

    private var subscriptionStoreName: String {
        (model.subscriptionProvider ?? "").lowercased() == "google" ? "Google Play" : "App Store"
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
#endif
