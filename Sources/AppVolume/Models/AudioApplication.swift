import AppKit
import AudioBackend

struct AudioApplication: Identifiable {
    let id: String
    let name: String
    let icon: NSImage
    let processIDs: [NSNumber]
    let usesDefaultOutput: Bool
    let lastSeen: Date
    let hasNonzeroSamples: Bool
    let status: String?
    var setting: VolumeSetting

    var effectiveGain: Float { setting.muted ? 0 : Float(setting.volume) / 100 }
}

struct ApplicationIdentity: Equatable {
    let key: String
    let name: String
    let iconPath: String?
    let persistent: Bool
}
