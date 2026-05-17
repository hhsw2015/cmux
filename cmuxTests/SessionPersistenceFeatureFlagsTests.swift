import XCTest
@testable import cmux

final class SessionPersistenceFeatureFlagsTests: XCTestCase {
    override func tearDown() {
        SessionPersistenceFeatureFlags.current = .default
        super.tearDown()
    }

    func testEnvKeyFormat() {
        XCTAssertEqual(SessionPersistenceFeature.engine.envKey,
                       "CMUX_SESSION_PERSISTENCE_ENGINE")
        XCTAssertEqual(SessionPersistenceFeature.keepAlive.envKey,
                       "CMUX_SESSION_PERSISTENCE_KEEPALIVE")
    }

    func testDefaultsKeyFormat() {
        XCTAssertEqual(SessionPersistenceFeature.engine.defaultsKey,
                       "session.persistence.engine.enabled")
    }

    func testCustomReader() {
        SessionPersistenceFeatureFlags.current = .init { feature in
            feature == .keepAlive
        }
        XCTAssertTrue(SessionPersistenceFeatureFlags.isEnabled(.keepAlive))
        XCTAssertFalse(SessionPersistenceFeatureFlags.isEnabled(.background))
    }

    func testEffectiveRespectsEngineGate() {
        SessionPersistenceFeatureFlags.current = .init { _ in true }
        XCTAssertTrue(SessionPersistenceFeatureFlags.effective(.keepAlive))

        SessionPersistenceFeatureFlags.current = .init { feature in
            feature != .engine
        }
        XCTAssertFalse(SessionPersistenceFeatureFlags.effective(.keepAlive),
                       "Master engine flag must gate every feature")
    }

    func testEffectiveEngineSelfReportsConsistently() {
        SessionPersistenceFeatureFlags.current = .init { $0 == .engine }
        XCTAssertTrue(SessionPersistenceFeatureFlags.effective(.engine))

        SessionPersistenceFeatureFlags.current = .init { _ in false }
        XCTAssertFalse(SessionPersistenceFeatureFlags.effective(.engine))
    }

    func testAllFeaturesEnumerable() {
        // Sanity: every case produces unique env/defaults keys, no collisions.
        let envKeys = SessionPersistenceFeature.allCases.map(\.envKey)
        XCTAssertEqual(Set(envKeys).count, envKeys.count)
        let defaultsKeys = SessionPersistenceFeature.allCases.map(\.defaultsKey)
        XCTAssertEqual(Set(defaultsKeys).count, defaultsKeys.count)
    }
}
