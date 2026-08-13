import AuthenticationServices
import CryptoKit
import Foundation
import StoreKit
import SwiftUI
import UIKit

extension AppModel {
    func normalizedApiBase(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// The authorization code is minted by the hosted page and redeemed here, so the
    /// only failures the app surfaces are a stale/replayed code.
    static func authorizeErrorMessage(_ code: String?) -> String {
        switch code {
        case "invalid_authorization_code", "authorization_code_expired", "invalid_code_challenge":
            return "Sign-in could not be completed. Please try signing in again."
        default:
            return "Sign in failed."
        }
    }

    static func accountActionErrorMessage(_ code: String?) -> String {
        switch code {
        case "unauthorized":
            return "Your sync session expired. Sign in again, then retry."
        case "delete_confirmation_mismatch":
            return "Could not confirm the account. Please try again."
        case "password_required":
            return "Enter your current password."
        case "password_too_long":
            return "That password is too long."
        case "invalid_credentials":
            return "That password is incorrect."
        case "billing_api_not_configured":
            return "Subscription cancellation is not configured yet."
        case "cancel_in_app_store":
            return "Manage this App Store subscription from your Apple account subscriptions."
        case "cancel_in_play_store":
            return "Manage this subscription from your Google Play account subscriptions."
        case "resume_in_app_store":
            return "Re-enable this subscription from your Apple account subscriptions."
        case "resume_in_play_store":
            return "Re-enable this subscription from your Google Play account subscriptions."
        case "no_active_subscription":
            return "There's no active paid subscription on this account to change."
        case "invalid_code":
            return "That code is incorrect."
        case "code_expired", "invalid_or_expired_code":
            return "That code has expired. Start the deletion again to get a new one."
        case "too_many_attempts":
            return "Too many incorrect codes. Start the deletion again to get a new one."
        default:
            return "The request to the sync API failed."
        }
    }

    static func googleOAuthConfigForImport() throws -> GoogleOAuthMobileConfig {
        guard let clientID = configuredGoogleClientID() else {
            throw GoogleOAuthConfigError.message("Bundle GoogleService-Info.plist or set KnotQGoogleClientID to connect Google Calendar.")
        }
        let redirectScheme = configuredGoogleRedirectScheme()
            ?? derivedGoogleRedirectScheme(clientID: clientID)
        guard let redirectScheme else {
            throw GoogleOAuthConfigError.message("Bundle GoogleService-Info.plist or set KnotQGoogleRedirectScheme for the Google OAuth callback.")
        }
        let redirectURI = configuredGoogleRedirectURI() ?? "\(redirectScheme):/oauth2redirect"
        return GoogleOAuthMobileConfig(
            clientID: clientID,
            redirectScheme: redirectScheme,
            redirectURI: redirectURI
        )
    }

    static func configuredGoogleClientID() -> String? {
        googleConfigString(infoKey: "KnotQGoogleClientID", envKeys: ["KNOTQ_GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_ID"])
            ?? bundledGoogleServiceValue("CLIENT_ID")
    }

    static func configuredGoogleRedirectScheme() -> String? {
        googleConfigString(infoKey: "KnotQGoogleRedirectScheme", envKeys: ["KNOTQ_GOOGLE_REDIRECT_SCHEME", "GOOGLE_REDIRECT_SCHEME"])
            ?? bundledGoogleServiceValue("REVERSED_CLIENT_ID")
    }

    static func configuredGoogleRedirectURI() -> String? {
        googleConfigString(infoKey: "KnotQGoogleRedirectURI", envKeys: ["KNOTQ_GOOGLE_REDIRECT_URI", "GOOGLE_REDIRECT_URI"])
    }

    static func googleConfigString(infoKey: String, envKeys: [String]) -> String? {
        if let value = usableGoogleConfigString(Bundle.main.object(forInfoDictionaryKey: infoKey) as? String) {
            return value
        }
        for key in envKeys {
            if let value = usableGoogleConfigString(ProcessInfo.processInfo.environment[key]) {
                return value
            }
        }
        return nil
    }

    static func bundledGoogleServiceValue(_ key: String) -> String? {
        guard let url = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any],
              let value = dictionary[key] as? String else {
            return nil
        }
        return usableGoogleConfigString(value)
    }

    static func usableGoogleConfigString(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.contains("$(") else {
            return nil
        }
        return trimmed
    }

    static func derivedGoogleRedirectScheme(clientID: String) -> String? {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix) else { return nil }
        return "com.googleusercontent.apps.\(clientID.dropLast(suffix.count))"
    }

    static func isWebAuthCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == ASWebAuthenticationSessionError.errorDomain
            && nsError.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue
    }

    #if DEBUG
    static var screenshotFixtureRequested: Bool {
        #if targetEnvironment(simulator)
        let process = ProcessInfo.processInfo
        return process.arguments.contains("--knotq-screenshot-fixture")
            || process.environment["KNOTQ_SCREENSHOT_FIXTURE"] == "1"
        #else
        return false
        #endif
    }

    /// The store screenshots are shot dark, but the fixture is also the only way
    /// to drive the app into a known screen without tapping, and some things only
    /// go wrong in light (a keyboard rendering against the wrong backdrop is
    /// invisible on a dark one). `KNOTQ_SCREENSHOT_THEME=light` opts into that.
    static var screenshotFixtureThemeMode: String {
        ProcessInfo.processInfo.environment["KNOTQ_SCREENSHOT_THEME"] == "light" ? "light" : "dark"
    }

    @discardableResult
    func seedScreenshotFixtureIfRequested() -> Bool {
        guard Self.screenshotFixtureRequested, let bridge else { return false }

        do {
            syncSession = nil
            UserDefaults.standard.removeObject(forKey: syncSessionKey)
            UserDefaults.standard.set(true, forKey: "knotq.mobile.onboardingCompleted.v1")

            selectedDate = Date()
            weekOffset = 0

            try bridge.resetWorkspace()
            try bridge.setThemeMode(Self.screenshotFixtureThemeMode)
            try bridge.setTimeFormat("twelve_hour")
            try bridge.setNotificationDefaults(
                eventOffsetSecs: 10 * 60,
                assignmentOffsetSecs: 2 * 60 * 60
            )

            let launchID = try renameOrCreateScreenshotScheme(
                bridge: bridge,
                currentNames: ["Start Here", "Example Plan", "Coursework"],
                targetName: "Semester Plan",
                colorIndex: 4
            )
            let scheduleID = try renameOrCreateScreenshotScheme(
                bridge: bridge,
                currentNames: ["Scheduling"],
                targetName: "Schedule",
                colorIndex: 5
            )
            let roadmapID = try renameOrCreateScreenshotScheme(
                bridge: bridge,
                currentNames: ["Projects"],
                targetName: "Research Project",
                colorIndex: 2
            )
            let classesID = try createScreenshotScheme(bridge: bridge, name: "Classes", colorIndex: 3)
            let fitnessID = try createScreenshotScheme(bridge: bridge, name: "Fitness", colorIndex: 0)
            let musicID = try createScreenshotScheme(bridge: bridge, name: "Music", colorIndex: 5)
            let lifeID = try createScreenshotScheme(bridge: bridge, name: "Life Admin", colorIndex: 9)
            let financeID = try createScreenshotScheme(bridge: bridge, name: "Finances", colorIndex: 7)

            try bridge.replaceSchemeItems(schemeID: launchID, items: launchPlanItems())
            try bridge.replaceSchemeItems(schemeID: scheduleID, items: scheduleItems())
            try bridge.replaceSchemeItems(schemeID: roadmapID, items: roadmapItems())
            try bridge.replaceSchemeItems(schemeID: classesID, items: classesItems())
            try bridge.replaceSchemeItems(schemeID: fitnessID, items: fitnessItems())
            try bridge.replaceSchemeItems(schemeID: musicID, items: musicItems())
            try bridge.replaceSchemeItems(schemeID: lifeID, items: lifeAdminItems())
            try bridge.replaceSchemeItems(schemeID: financeID, items: financeItems())
            try seedDailyScreenshotItems(bridge: bridge)

            snapshot = try bridge.snapshot(today: Self.dateOnly(selectedDate), weekOffset: weekOffset)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }

        return true
    }

    func renameOrCreateScreenshotScheme(
        bridge: RustBridge,
        currentNames: [String],
        targetName: String,
        colorIndex: Int32
    ) throws -> String {
        let snapshot = try bridge.snapshot(today: Self.dateOnly(selectedDate), weekOffset: weekOffset)
        if let existing = snapshot.schemes.first(where: { currentNames.contains($0.name) || $0.name == targetName }) {
            if existing.name != targetName {
                try bridge.renameScheme(id: existing.id, name: targetName)
            }
            try bridge.setSchemeColor(id: existing.id, colorIndex: colorIndex)
            return existing.id
        }
        return try createScreenshotScheme(bridge: bridge, name: targetName, colorIndex: colorIndex)
    }

    func createScreenshotScheme(bridge: RustBridge, name: String, colorIndex: Int32) throws -> String {
        let before = Set(try bridge.snapshot(today: Self.dateOnly(selectedDate), weekOffset: weekOffset).schemes.map(\.id))
        try bridge.createScheme(name: name, folderID: nil, position: nil)
        let snapshot = try bridge.snapshot(today: Self.dateOnly(selectedDate), weekOffset: weekOffset)
        guard let scheme = snapshot.schemes.first(where: { !before.contains($0.id) && $0.name == name })
            ?? snapshot.schemes.first(where: { $0.name == name }) else {
            throw ScreenshotFixtureError.message("Could not create screenshot scheme \(name).")
        }
        try bridge.setSchemeColor(id: scheme.id, colorIndex: colorIndex)
        return scheme.id
    }

    func seedDailyScreenshotItems(bridge: RustBridge) throws {
        let todayKey = Self.dateOnly(selectedDate)
        try bridge.ensureDailyQueue(date: todayKey)
        let snapshot = try bridge.snapshot(today: todayKey, weekOffset: weekOffset)
        guard let dailyID = snapshot.daily.first(where: { $0.date == todayKey })?.scheme.id else {
            throw ScreenshotFixtureError.message("Could not prepare today's daily queue.")
        }
        try bridge.replaceSchemeItems(schemeID: dailyID, items: [
            screenshotItem("Today", marker: .blank),
            screenshotItem("Review lecture notes", marker: .checkbox, done: true),
            screenshotItem("Finish calculus questions", marker: .checkbox),
            screenshotItem("Email lab partner", marker: .checkbox),
            screenshotItem("Pack books for tutoring", marker: .checkbox),
            screenshotItem("Draft history thesis paragraph", marker: .checkbox, end: screenshotDate(dayOffset: 0, hour: 21, minute: 15)),
            screenshotItem("Inbox", marker: .blank),
            screenshotItem("Check scholarship portal", marker: .checkbox),
            screenshotItem("Text study group", marker: .checkbox),
            screenshotItem("Loose notes", marker: .blank),
            screenshotItem("Bring blue notebook to art history", marker: .bullet, indent: 1),
        ])
    }

    func launchPlanItems() -> [MobileItemEdit] {
        [
            screenshotItem("Spring semester", marker: .blank),
            screenshotItem("Coursework", marker: .bullet),
            screenshotItem("Read philosophy chapter 8", marker: .checkbox, indent: 1, done: true),
            screenshotItem("Outline art history essay", marker: .checkbox, indent: 1),
            screenshotItem("Prepare stats lab questions", marker: .checkbox, indent: 1, end: screenshotDate(dayOffset: 1, hour: 16, minute: 45)),
            screenshotItem("Campus", marker: .bullet),
            screenshotItem("Reserve library study room", marker: .checkbox, indent: 1, done: true),
            screenshotItem("Meet writing tutor", marker: .checkbox, indent: 1),
            screenshotItem("Print music theory worksheet", marker: .checkbox, indent: 1),
            screenshotItem("Submit financial aid form", marker: .checkbox, indent: 1),
            screenshotItem("Exam prep", marker: .bullet),
            screenshotItem("Make flashcards for psychology", marker: .checkbox, indent: 1),
            screenshotItem("Archive last week's notes", marker: .checkbox, indent: 1),
        ]
    }

    func scheduleItems() -> [MobileItemEdit] {
        [
            screenshotItem("Calendar blocks", marker: .blank),
            screenshotItem("Morning review", marker: .checkbox, done: true, start: screenshotDate(dayOffset: 0, hour: 11, minute: 15), end: screenshotDate(dayOffset: 0, hour: 11, minute: 45)),
            screenshotItem("Library study block", marker: .checkbox, done: true),
            screenshotItem("Essay drafting", marker: .checkbox, done: true),
            screenshotItem("Group project meeting", marker: .checkbox, start: screenshotDate(dayOffset: 1, hour: 12, minute: 30), end: screenshotDate(dayOffset: 1, hour: 13, minute: 15)),
            screenshotItem("Office hours", marker: .checkbox),
            screenshotItem("Weekly planning", marker: .checkbox),
        ]
    }

    func roadmapItems() -> [MobileItemEdit] {
        [
            screenshotItem("History research paper", marker: .blank),
            screenshotItem("Find five primary sources", marker: .checkbox, done: true),
            screenshotItem("Annotate museum catalog", marker: .checkbox),
            screenshotItem("Send thesis to professor", marker: .checkbox, end: screenshotDate(dayOffset: 2, hour: 12, minute: 0)),
            screenshotItem("Draft sections", marker: .blank),
            screenshotItem("Write intro paragraph", marker: .checkbox),
            screenshotItem("Revise source notes", marker: .checkbox),
        ]
    }

    func classesItems() -> [MobileItemEdit] {
        [
            screenshotItem("Coursework", marker: .blank),
            screenshotItem("Calculus problem set", marker: .checkbox, done: true),
            screenshotItem("Art History critique", marker: .checkbox, end: screenshotDate(dayOffset: 1, hour: 22, minute: 0)),
            screenshotItem("Psych reading response Ch. 7", marker: .checkbox, end: screenshotDate(dayOffset: 1, hour: 23, minute: 0)),
            screenshotItem("Stats problem set 8", marker: .checkbox),
            screenshotItem("Creative writing portfolio", marker: .checkbox),
            screenshotItem("Seminars", marker: .blank),
            screenshotItem("Chemistry lecture", marker: .checkbox, done: true, start: screenshotDate(dayOffset: 0, hour: 12, minute: 0), end: screenshotDate(dayOffset: 0, hour: 12, minute: 50)),
            screenshotItem("Art History seminar", marker: .checkbox, start: screenshotDate(dayOffset: 1, hour: 11, minute: 15), end: screenshotDate(dayOffset: 1, hour: 12, minute: 0)),
            screenshotItem("Stats lab", marker: .checkbox, start: screenshotDate(dayOffset: 3, hour: 14, minute: 0), end: screenshotDate(dayOffset: 3, hour: 15, minute: 15)),
        ]
    }

    func fitnessItems() -> [MobileItemEdit] {
        [
            screenshotItem("Training", marker: .blank),
            screenshotItem("Club run", marker: .checkbox, start: screenshotDate(dayOffset: 1, hour: 15, minute: 15), end: screenshotDate(dayOffset: 1, hour: 16, minute: 0)),
            screenshotItem("Gym: upper body", marker: .checkbox, start: screenshotDate(dayOffset: 2, hour: 8, minute: 0), end: screenshotDate(dayOffset: 2, hour: 9, minute: 0)),
            screenshotItem("Yoga class", marker: .checkbox),
            screenshotItem("Pack running shoes", marker: .checkbox, done: true),
        ]
    }

    func musicItems() -> [MobileItemEdit] {
        [
            screenshotItem("Practice", marker: .blank),
            screenshotItem("Piano practice", marker: .checkbox, done: true),
            screenshotItem("Band rehearsal", marker: .checkbox, start: screenshotDate(dayOffset: 2, hour: 14, minute: 0), end: screenshotDate(dayOffset: 2, hour: 15, minute: 30)),
            screenshotItem("Theory analysis", marker: .checkbox),
        ]
    }

    func lifeAdminItems() -> [MobileItemEdit] {
        [
            screenshotItem("Errands", marker: .blank),
            screenshotItem("Pick up groceries", marker: .checkbox, start: screenshotDate(dayOffset: 4, hour: 17, minute: 0)),
            screenshotItem("Call Maya", marker: .checkbox),
            screenshotItem("Renew library books", marker: .checkbox),
            screenshotItem("Movie night", marker: .checkbox),
        ]
    }

    func financeItems() -> [MobileItemEdit] {
        [
            screenshotItem("Monthly", marker: .blank),
            screenshotItem("Rent due", marker: .checkbox, end: screenshotDate(dayOffset: 6, hour: 9, minute: 0)),
            screenshotItem("Reconcile subscriptions", marker: .checkbox),
            screenshotItem("Update budget notes", marker: .checkbox),
        ]
    }

    func screenshotItem(
        _ text: String,
        marker: Marker,
        indent: Int32 = 0,
        done: Bool = false,
        start: Date? = nil,
        end: Date? = nil,
        notificationOffsetSecs: Int32? = nil,
        repeatRule: String? = nil
    ) -> MobileItemEdit {
        MobileItemEdit(
            id: nil,
            text: text,
            marker: marker.rawValue,
            indent: indent,
            done: done,
            start: start.map { iso.string(from: $0) },
            end: end.map { iso.string(from: $0) },
            notificationOffsetSecs: notificationOffsetSecs,
            repeatRule: repeatRule,
            media: [],
            content: []
        )
    }

    func screenshotDate(dayOffset: Int, hour: Int, minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let base = calendar.startOfDay(for: selectedDate)
        let day = calendar.date(byAdding: .day, value: dayOffset, to: base) ?? base
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    func seedEditorImageFixture() {
        guard let bridge else { return }
        do {
            try bridge.seedEditorImageFixture()
            snapshot = try bridge.snapshot(today: Self.dateOnly(selectedDate), weekOffset: weekOffset)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif

    static func initialDailyHistoryDays(for date: Date) -> Int {
        // Open on just the last few days so the first snapshot is cheap; the feed
        // pages in older days on scroll. (Was: the whole previous month → today,
        // which loaded dozens of daily queues up front.)
        min(max(initialDailyHistoryWindowDays, minimumDailyHistoryDays), maxDailyHistoryDays)
    }
}
