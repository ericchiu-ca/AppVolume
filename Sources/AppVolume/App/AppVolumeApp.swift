import AppKit
import SwiftUI
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // The project build script uses SIGTERM for its own instance. Route it through
        // AppKit termination so AudioControlService receives willTerminate and stops taps.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source
    }
}

@main
struct AppVolumeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var control = AudioControlService()

    var body: some Scene {
        MenuBarExtra("AppVolume", systemImage: "speaker.wave.2.fill") {
            VolumePanel(control: control)
        }
        .menuBarExtraStyle(.window)
    }
}
