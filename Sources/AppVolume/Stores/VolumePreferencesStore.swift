import Foundation

struct VolumeSetting: Codable, Equatable {
    var volume: Double = 100
    var muted: Bool = false

    mutating func setVolume(_ value: Double) {
        volume = value.isFinite ? min(100, max(0, value)) : 100
    }
}

final class VolumePreferencesStore {
    private let defaults: UserDefaults
    private let key = "savedApplicationVolumes.v1"
    private(set) var values: [String: VolumeSetting]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode([String: VolumeSetting].self, from: data) {
            values = decoded
        } else { values = [:] }
    }

    func setting(for identity: ApplicationIdentity) -> VolumeSetting {
        guard identity.persistent else { return VolumeSetting() }
        var setting = values[identity.key] ?? VolumeSetting()
        setting.setVolume(setting.volume)
        return setting
    }

    func save(_ setting: VolumeSetting, for identity: ApplicationIdentity) {
        guard identity.persistent else { return }
        values[identity.key] = setting
        persist()
    }

    func reset() {
        values.removeAll()
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: key) }
    }
}
