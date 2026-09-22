import SwiftUI

struct ApplicationVolumeRow: View {
    let application: AudioApplication
    let onVolume: (Double) -> Void
    let onMute: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                Image(nsImage: application.icon)
                    .resizable()
                    .frame(width: 22, height: 22)
                    .overlay(alignment: .bottomTrailing) {
                        if application.hasNonzeroSamples {
                            Circle().fill(.green).frame(width: 7, height: 7)
                                .help("Nonzero audio samples detected")
                        }
                    }
                Text(application.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 122, alignment: .leading)
                    .help(application.name)
                Slider(value: Binding(get: { application.setting.volume }, set: onVolume), in: 0...100, step: 1)
                    .accessibilityLabel("\(application.name) volume")
                Text("\(Int(application.setting.volume))%")
                    .font(.body.monospacedDigit())
                    .frame(width: 42, alignment: .trailing)
                Button(action: onMute) {
                    Image(systemName: application.setting.muted ? "speaker.slash.fill" : "speaker.wave.2")
                        .frame(width: 20)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(application.setting.muted ? "Unmute" : "Mute") \(application.name)")
            }
            if let status = application.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(status)
                    .padding(.leading, 31)
            }
        }
        .padding(.vertical, 4)
    }
}
