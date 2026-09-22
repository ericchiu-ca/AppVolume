import XCTest
import AudioBackend
@testable import AppVolume

final class AppVolumeTests: XCTestCase {
    func testGainBounds() {
        XCTAssertEqual(AVClampedGain(-1), 0)
        XCTAssertEqual(AVClampedGain(0.5), 0.5)
        XCTAssertEqual(AVClampedGain(2), 1)
        XCTAssertEqual(AVClampedGain(.nan), 1)
    }

    func testRampContinuityAndEndpoint() {
        var gain: Float = 1
        let frames = 384 // 8 ms at 48 kHz
        for remaining in (1...frames).reversed() {
            let next = AVGainRampStep(gain, 0.5, UInt32(remaining))
            XCTAssertLessThanOrEqual(abs(next - gain), 0.002)
            gain = next
        }
        XCTAssertEqual(gain, 0.5, accuracy: 0.000001)
    }

    func testMutePreservesSavedVolumeAndRestartRestoresIt() {
        let suite = "AppVolumeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = ApplicationIdentity(key: "bundle:org.example.player", name: "Player", iconPath: nil, persistent: true)
        let store = VolumePreferencesStore(defaults: defaults)
        var setting = store.setting(for: identity)
        setting.setVolume(37)
        setting.muted = true
        store.save(setting, for: identity)
        var restored = VolumePreferencesStore(defaults: defaults).setting(for: identity)
        XCTAssertEqual(restored.volume, 37)
        XCTAssertTrue(restored.muted)
        restored.muted = false
        XCTAssertEqual(restored.volume, 37)
        store.reset()
        XCTAssertEqual(VolumePreferencesStore(defaults: defaults).setting(for: identity), VolumeSetting())
    }

    func testTemporaryIdentityDoesNotPersist() {
        let suite = "AppVolumeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = ApplicationIdentity(key: "temporary:123:456", name: "Process", iconPath: nil, persistent: false)
        let store = VolumePreferencesStore(defaults: defaults)
        store.save(VolumeSetting(volume: 20, muted: true), for: identity)
        XCTAssertEqual(VolumePreferencesStore(defaults: defaults).setting(for: identity), VolumeSetting())
    }

    func testNestedHelperPathGroupsWithOuterApplication() {
        let url = URL(fileURLWithPath: "/Applications/Browser.app/Contents/Frameworks/Browser Helper.app")
        XCTAssertEqual(ApplicationIdentityResolver.outermostApplicationURL(for: url).path, "/Applications/Browser.app")
    }

    func testFailedAudioStartLeavesSessionInactiveAndCanBeStoppedAgain() {
        let session = AVTapSession(processObjectIDs: [NSNumber(value: 1)], outputDevice: 0, gain: 0.5)
        XCTAssertThrowsError(try session.start())
        XCTAssertFalse(session.active)
        session.stop()
        XCTAssertFalse(session.active)
    }
}
