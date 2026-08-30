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
@MainActor
final class WebAuthenticationSessionCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        session?.cancel()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let next = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
                    Task { @MainActor in
                        guard let self else { return }
                        let pending = self.continuation
                        self.continuation = nil
                        self.session = nil
                        if let error {
                            pending?.resume(throwing: error)
                        } else if let callbackURL {
                            pending?.resume(returning: callbackURL)
                        } else {
                            pending?.resume(throwing: GoogleOAuthConfigError.message("The browser did not return a callback URL."))
                        }
                    }
                }
                next.presentationContextProvider = self
                next.prefersEphemeralWebBrowserSession = false
                self.session = next
                if !next.start() {
                    self.session = nil
                    self.continuation = nil
                    continuation.resume(throwing: GoogleOAuthConfigError.message("Could not open the browser."))
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.cancel()
            }
        }
    }

    func cancel() {
        session?.cancel()
        session = nil
        continuation = nil
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
