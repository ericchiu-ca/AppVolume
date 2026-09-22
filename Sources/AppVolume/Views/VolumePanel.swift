import SwiftUI

struct VolumePanel: View {
    @ObservedObject var control: AudioControlService

    private var availableListHeight: CGFloat {
        max(180, (NSScreen.main?.visibleFrame.height ?? 800) - 180)
    }

    private var estimatedListHeight: CGFloat {
        control.applications.reduce(0) { height, app in
            height + (app.status == nil ? 39 : 55)
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(control.applications) { app in
                ApplicationVolumeRow(application: app,
                                     onVolume: { control.setVolume($0, for: app.id) },
                                     onMute: { control.toggleMute(for: app.id) })
                if app.id != control.applications.last?.id { Divider() }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("App Volumes").font(.headline)
                Spacer()
                Text("\(control.applications.count) apps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let notice = control.notice {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(notice).font(.caption).lineLimit(2)
                    if control.canRetry {
                        Spacer(minLength: 4)
                        Button("Retry") { control.retry() }.font(.caption)
                    }
                }
                .foregroundStyle(control.canRetry ? .orange : .secondary)
            }
            if control.applications.isEmpty {
                Text("No apps are currently playing audio")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
            } else if estimatedListHeight <= availableListHeight {
                rows
            } else {
                ScrollView { rows }
                    .frame(height: availableListHeight)
            }
            Divider()
            Label(control.outputName, systemImage: "hifispeaker")
                .lineLimit(1).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(control.paused ? "Resume Control" : "Pause Control") { control.togglePause() }
                Button("Reset All") { control.resetAll() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 470)
    }
}
