import Foundation
import XCTest
@testable import KnotQMobile

final class SyncSessionStoreTests: XCTestCase {
    private var key = ""

    override func setUp() {
        super.setUp()
        key = "test.\(UUID().uuidString)"
        SyncSessionStore.remove(key: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        SyncSessionStore.remove(key: key)
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func testKeychainRoundTripAndRemoval() throws {
        let original = Data("credential-payload".utf8)

        XCTAssertTrue(SyncSessionStore.save(original, key: key))
        XCTAssertEqual(SyncSessionStore.load(key: key), original)
        XCTAssertTrue(SyncSessionStore.save(Data("rotated".utf8), key: key))
        XCTAssertEqual(SyncSessionStore.load(key: key), Data("rotated".utf8))
        XCTAssertTrue(SyncSessionStore.remove(key: key))
        XCTAssertNil(SyncSessionStore.load(key: key))
        XCTAssertTrue(SyncSessionStore.remove(key: key), "removing an absent session is idempotent")
    }

    func testPushTokenStoreRoundTripRotationAndRemoval() {
        PushTokenStore.remove()
        defer { PushTokenStore.remove() }

        let first = PushTokenStore.Registration(token: "fcm-first", environment: "sandbox")
        let rotated = PushTokenStore.Registration(token: "fcm-rotated", environment: "production")
        XCTAssertTrue(PushTokenStore.save(first))
        XCTAssertEqual(PushTokenStore.load(), first)
        XCTAssertTrue(PushTokenStore.save(rotated))
        XCTAssertEqual(PushTokenStore.load(), rotated)
        XCTAssertTrue(PushTokenStore.remove())
        XCTAssertNil(PushTokenStore.load())
        XCTAssertTrue(PushTokenStore.remove(), "removing an absent push token is idempotent")
    }

    @MainActor
    func testLegacySessionMigratesAndIsRemovedOnlyAfterProtectedWrite() throws {
        let session = LocalSyncSession(
            apiBase: "https://api.example.test",
            userId: "user",
            email: "user@example.test",
            bearerToken: "bearer",
            expiresAt: "2030-01-01T00:00:00Z",
            refreshToken: "refresh",
            refreshExpiresAt: "2031-01-01T00:00:00Z"
        )
        let data = try JSONEncoder().encode(session)
        UserDefaults.standard.set(data, forKey: key)

        XCTAssertEqual(AppModel.loadSyncSession(key: key), session)
        XCTAssertEqual(SyncSessionStore.load(key: key), data)
        XCTAssertNil(UserDefaults.standard.data(forKey: key))
    }
}
