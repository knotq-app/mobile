import AuthenticationServices
import CryptoKit
import Foundation
import StoreKit
import SwiftUI
import UIKit

extension AppModel {
    func setThemeMode(_ mode: String) {
        mutate { try $0.setThemeMode(mode) }
    }

    func setTimeFormat(_ format: String) {
        mutate { try $0.setTimeFormat(format) }
    }

    func setNotificationDefaults(eventOffsetSecs: Int32, assignmentOffsetSecs: Int32) {
        mutate {
            try $0.setNotificationDefaults(
                eventOffsetSecs: eventOffsetSecs,
                assignmentOffsetSecs: assignmentOffsetSecs
            )
        }
    }

    func setUpcomingDisplaySettings(
        eventLookaheadDays: Int32,
        reminderLookaheadDays: Int32,
        assignmentLookaheadDays: Int32,
        maximumItems: Int32,
        showOverdue: Bool,
        showCompleted: Bool
    ) {
        mutate {
            try $0.setUpcomingDisplaySettings(
                eventLookaheadDays: eventLookaheadDays,
                reminderLookaheadDays: reminderLookaheadDays,
                assignmentLookaheadDays: assignmentLookaheadDays,
                maximumItems: maximumItems,
                showOverdue: showOverdue,
                showCompleted: showCompleted
            )
        }
    }

    func resetWorkspace() {
        mutate { try $0.resetWorkspace() }
    }

    func connectGoogleCalendar(parentID: String? = nil) async {
        guard !googleAuthInProgress, let bridge else { return }
        googleAuthInProgress = true
        defer {
            googleAuthInProgress = false
            googleOAuthSession = nil
        }

        do {
            let config = try Self.googleOAuthConfigForImport()
            let clientID = config.clientID
            let redirectURI = config.redirectURI
            let request = try await bridge.perform { try $0.googleAuthRequest(clientID: clientID, redirectURI: redirectURI) }
            guard let authURL = URL(string: request.authUrl) else {
                throw GoogleOAuthConfigError.message("Google returned an invalid authorization URL.")
            }

            let session = WebAuthenticationSessionCoordinator()
            googleOAuthSession = session
            let callbackURL = try await session.authenticate(url: authURL, callbackScheme: config.redirectScheme)
            let callback = callbackURL.absoluteString
            let result = try await bridge.perform { b in
                try b.completeGoogleCalendarImport(
                    request: request,
                    callbackURL: callback,
                    parentID: parentID
                )
            }
            googleCalendarStatus = result.message
            refresh()
            if syncSession != nil {
                scheduleSync()
            }
            errorMessage = nil
        } catch {
            if Self.isWebAuthCancellation(error) {
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func syncGoogleCalendars(silent: Bool = false) async -> Bool {
        guard !googleSyncInProgress, let bridge else { return false }
        guard snapshot?.settings.googleAccountCount ?? 0 > 0 else { return false }
        googleSyncInProgress = true
        defer { googleSyncInProgress = false }

        do {
            let result = try await bridge.perform { try $0.syncGoogleCalendars() }
            googleCalendarStatus = result.message
            refresh()
            if syncSession != nil {
                scheduleSync()
            }
            if !silent {
                errorMessage = nil
            }
            return result.importedCount > 0 || result.syncedCount > 0
        } catch {
            if silent {
                googleCalendarStatus = error.localizedDescription
            } else {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    func unlinkGoogleCalendarAccount(_ account: MobileGoogleAccount) {
        mutate { try $0.unlinkGoogleAccount(accountID: account.id) }
    }

    static let prodWebBase = "https://www.knotq.com"
    static let sandboxWebBase = "https://sandbox.knotq.com"
    // The knotq.com site origin matching a sync API base, so a sandbox/local-dev
    // build opens the sandbox site instead of production. The sign-in page also
    // receives the API base via the allowlisted `?api=` param, which is what
    // actually pins the backend (needed for local, where the site is the sandbox
    // host but the API is the loopback Worker).
    static func webBase(forApiBase apiBase: String) -> String {
        if apiBase.contains("sandbox.api.knotq.com")
            || apiBase.contains("127.0.0.1")
            || apiBase.contains("localhost") {
            return sandboxWebBase
        }
        return prodWebBase
    }
    static let signInRedirectScheme = "knotq"
    static let signInRedirectURI = "knotq://auth-callback"
    // Base URL used for a *new* sign-in when no session is stored yet. A
    // `KNOTQ_API_BASE` override (set it in the Xcode Run scheme's environment)
    // always wins; otherwise the default is build-aware — Debug builds target the
    // hosted sandbox (https://sandbox.api.knotq.com) so development never touches
    // production, while Release (App Store) builds target production. Existing
    // sessions keep their stored apiBase, so this never silently moves a signed-in
    // account between environments.
    static var defaultSyncApiBase: String {
        if let override = ProcessInfo.processInfo.environment["KNOTQ_API_BASE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        #if DEBUG
        return "https://sandbox.api.knotq.com"
        #else
        return "https://api.knotq.com"
        #endif
    }
}
