import AuthenticationServices
import CryptoKit
import Foundation
import StoreKit
import SwiftUI
import UIKit

/// Collapses a burst of requests for the same expensive snapshot into the
/// currently-running read plus, at most, one read of the latest model state.
///
/// `AppModel` owns this on the main actor. Keeping the state machine value-typed
/// makes the no-lost-refresh contract independently testable without a Rust
/// core, notification scheduler, or SwiftUI view tree.
struct RefreshFlightGate: Equatable {
    private(set) var isInFlight = false
    private(set) var followUpRequested = false

    /// Returns whether the caller should start a bridge read now.
    mutating func request() -> Bool {
        guard !isInFlight else {
            followUpRequested = true
            return false
        }
        isInFlight = true
        return true
    }

    /// Completes the active read. When this returns true, the caller must start
    /// exactly one more read directly (rather than calling `request()` again),
    /// because that follow-up remains the active flight.
    mutating func finish() -> Bool {
        guard isInFlight else { return false }
        guard followUpRequested else {
            isInFlight = false
            return false
        }
        followUpRequested = false
        return true
    }
}

/// The view query captured by an asynchronous snapshot read. A read can finish
/// after the user has changed day/week/history, so its snapshot must not be
/// allowed to replace the newer selection. Notification reconciliation is
/// independent of this view query and can still use the completed read.
struct RefreshQuery: Equatable, Sendable {
    let dateKey: String
    let weekOffset: Int
    let dailyHistoryDays: Int

    func matches(dateKey: String, weekOffset: Int, dailyHistoryDays: Int) -> Bool {
        self.dateKey == dateKey
            && self.weekOffset == weekOffset
            && self.dailyHistoryDays == dailyHistoryDays
    }
}

/// Invalidates asynchronous account work when the signed-in session changes.
/// Network responses can arrive after sign-out or after a second account has
/// been installed. Comparing this revision before applying a response prevents
/// stale account state from crossing that boundary. Bearer-token rotation does
/// not advance it because it is still the same logical session.
struct SyncSessionGeneration: Equatable, Sendable {
    private(set) var value: UInt64 = 0

    mutating func advance() {
        value &+= 1
    }

    func matches(_ captured: UInt64) -> Bool {
        value == captured
    }
}

/// Serializes user-facing error alerts. SwiftUI can rebuild the root view while
/// an alert is still dismissing (especially when a core write publishes a new
/// snapshot), and a plain `errorMessage != nil` binding can ask UIKit to present
/// a second `UIAlertController` on top of the first one. Keep one message visible
/// and retain the newest replacement for the next presentation instead.
struct ErrorAlertGate: Equatable {
    private(set) var presentedMessage: String?
    private(set) var pendingMessage: String?

    /// Returns true only when the caller should present a new alert now.
    mutating func receive(_ message: String?) -> Bool {
        guard let message else {
            // A successful operation cleared the source error while the alert
            // was visible; do not resurrect an obsolete queued replacement
            // after the user dismisses the current alert.
            pendingMessage = nil
            return false
        }
        guard let presentedMessage else {
            self.presentedMessage = message
            return true
        }
        guard message != presentedMessage else { return false }
        pendingMessage = message
        return false
    }

    /// Dismisses the visible message and promotes the latest queued error, if
    /// any. The caller should defer that next presentation until UIKit has
    /// completed the current dismissal animation.
    mutating func dismiss() -> Bool {
        presentedMessage = pendingMessage
        pendingMessage = nil
        return presentedMessage != nil
    }
}

#if DEBUG
enum ScreenshotFixtureError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}
#endif

struct SyncLoginResponse: Decodable {
    let userId: String
    let email: String
    let supportsSync: Bool
    let bearerToken: String
    let expiresAt: String
    let refreshToken: String
    let refreshExpiresAt: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case email
        case supportsSync = "supports_sync"
        case bearerToken = "bearer_token"
        case expiresAt = "expires_at"
        case refreshToken = "refresh_token"
        case refreshExpiresAt = "refresh_expires_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decode(String.self, forKey: .userId)
        email = try container.decode(String.self, forKey: .email)
        supportsSync = try container.decodeIfPresent(Bool.self, forKey: .supportsSync) ?? true
        bearerToken = try container.decode(String.self, forKey: .bearerToken)
        expiresAt = try container.decode(String.self, forKey: .expiresAt)
        refreshToken = try container.decode(String.self, forKey: .refreshToken)
        refreshExpiresAt = try container.decodeIfPresent(String.self, forKey: .refreshExpiresAt)
    }
}

/// The subset of /v1/auth/account/status the app needs to reflect a cancelled
/// subscription. `subscription_state` is optional so older backends still decode.
struct AccountStatusPayload: Decodable {
    let supportsSync: Bool
    let subscriptionState: String?
    let subscriptionProvider: String?
    // Fail closed: a response that omits the field decodes as unverified rather than
    // silently allowing checkout. The current backend always sends it.
    let emailVerified: Bool

    enum CodingKeys: String, CodingKey {
        case supportsSync = "supports_sync"
        case subscriptionState = "subscription_state"
        case subscriptionProvider = "subscription_provider"
        case emailVerified = "email_verified"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        supportsSync = try container.decodeIfPresent(Bool.self, forKey: .supportsSync) ?? true
        subscriptionState = try container.decodeIfPresent(String.self, forKey: .subscriptionState)
        subscriptionProvider = try container.decodeIfPresent(String.self, forKey: .subscriptionProvider)
        emailVerified = try container.decodeIfPresent(Bool.self, forKey: .emailVerified) ?? false
    }
}

struct DeleteAccountResponse: Decodable {
    let deletionScheduled: Bool
    let purgeAfter: String?

    enum CodingKeys: String, CodingKey {
        case deletionScheduled = "deletion_scheduled"
        case purgeAfter = "purge_after"
    }
}

// A pending one-time-code challenge (e.g. account-deletion confirmation).
struct ChallengeResponse: Decodable {
    let challengeId: String

    enum CodingKeys: String, CodingKey {
        case challengeId = "challenge_id"
    }
}

enum SyncAuthError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}

enum MobileHTTPResponseError: LocalizedError, Equatable {
    case invalidResponse
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Sync backend returned an invalid response."
        case .tooLarge:
            return "Sync backend returned an unexpectedly large response."
        }
    }
}

/// Reads small JSON control-plane responses without allowing a malformed or
/// compromised endpoint to make the app allocate an arbitrary amount of memory.
/// The sync payload itself is handled by the Rust transport; these limits cover
/// auth, billing, and account-management responses owned by this Swift client.
enum MobileHTTPResponseLimits {
    static let maxResponseBytes = 1_048_576
    static let maxRequestTimeout: TimeInterval = 15

    /// Keep every small control-plane request bounded even when a caller forgets
    /// to set a timeout. Callers may choose a shorter deadline, but no auth,
    /// billing, or account request is allowed to pin the serialized bridge for
    /// URLSession's much longer default timeout.
    static func boundedRequest(_ request: URLRequest) -> URLRequest {
        var request = request
        request.timeoutInterval = request.timeoutInterval > 0
            ? min(request.timeoutInterval, maxRequestTimeout)
            : maxRequestTimeout
        return request
    }

    static func data(
        for request: URLRequest,
        maxBytes: Int = maxResponseBytes
    ) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await URLSession.shared.bytes(for: boundedRequest(request))
        guard let http = response as? HTTPURLResponse else {
            throw MobileHTTPResponseError.invalidResponse
        }
        if http.expectedContentLength > Int64(maxBytes) {
            throw MobileHTTPResponseError.tooLarge
        }

        var body = Data()
        if http.expectedContentLength > 0 {
            body.reserveCapacity(Int(http.expectedContentLength))
        }
        for try await byte in bytes {
            try append(byte, to: &body, maxBytes: maxBytes)
        }
        return (body, http)
    }

    static func append(_ byte: UInt8, to data: inout Data, maxBytes: Int) throws {
        guard maxBytes >= 0, data.count < maxBytes else {
            throw MobileHTTPResponseError.tooLarge
        }
        data.append(byte)
    }
}

enum SyncSessionRefreshResult: Equatable {
    case ready
    case deferred
    case sessionDead
}

struct GoogleOAuthMobileConfig {
    let clientID: String
    let redirectScheme: String
    let redirectURI: String
}

enum GoogleOAuthConfigError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}

/// Drives an `ASWebAuthenticationSession` for any browser-redirect flow (Google
/// Calendar import and sync sign-in), intercepting the custom callback scheme.
struct WebAuthenticationAttemptGate: Equatable {
    private(set) var generation = 0

    mutating func begin() -> Int {
        generation &+= 1
        return generation
    }

    mutating func cancel() {
        generation &+= 1
    }

    func accepts(_ attempt: Int) -> Bool {
        attempt == generation
    }
}

@MainActor
final class WebAuthenticationSessionCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var attemptGate = WebAuthenticationAttemptGate()

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        cancelPendingAuthentication()
        let attempt = attemptGate.begin()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard self.attemptGate.accepts(attempt) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let next = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
                    Task { @MainActor in
                        guard let self else { return }
                        let result: Result<URL, Error>
                        if let error {
                            result = .failure(error)
                        } else if let callbackURL {
                            result = .success(callbackURL)
                        } else {
                            result = .failure(GoogleOAuthConfigError.message("The browser did not return a callback URL."))
                        }
                        self.finish(attempt: attempt, result: result)
                    }
                }
                next.presentationContextProvider = self
                next.prefersEphemeralWebBrowserSession = false
                self.session = next
                if !next.start() {
                    self.finish(
                        attempt: attempt,
                        result: .failure(GoogleOAuthConfigError.message("Could not open the browser."))
                    )
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelPendingAuthentication()
            }
        }
    }

    func cancel() {
        cancelPendingAuthentication()
    }

    private func cancelPendingAuthentication() {
        attemptGate.cancel()
        session?.cancel()
        session = nil
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: CancellationError())
    }

    private func finish(attempt: Int, result: Result<URL, Error>) {
        guard attemptGate.accepts(attempt) else { return }
        session = nil
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
            ?? scenes.first?.windows.first
            ?? ASPresentationAnchor()
    }
}
