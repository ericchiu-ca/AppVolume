import SwiftUI

struct ApplicationVolumeRow: View {
    let application: AudioApplication
    let onVolume: (Double) -> Void
    let onMute: () -> Void

    private var displayedVolume: Double {
        application.setting.muted ? 0 : application.setting.volume
    }

    private var speakerSymbol: String {
        if application.setting.muted { return "speaker.slash.fill" }
        switch displayedVolume {
        case 0: return "speaker.fill"
        case ..<34: return "speaker.wave.1.fill"
        case ..<67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    private var speakerSize: CGFloat {
        12 + CGFloat(displayedVolume / 100) * 6
    }

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
                    Image(systemName: speakerSymbol)
                        .font(.system(size: speakerSize, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentTransition(.symbolEffect(.replace))
                        .animation(.easeOut(duration: 0.12), value: speakerSize)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(application.setting.muted ? "Unmute" : "Mute") \(application.name)")
                .accessibilityValue(application.setting.muted ? "Muted" : "\(Int(displayedVolume)) percent")
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
