import AppKit
import AudioBackend

enum ApplicationIdentityResolver {
    static func resolve(_ process: AVAudioProcess) -> ApplicationIdentity {
        let pid = process.pid
        let running = NSRunningApplication(processIdentifier: pid)
        if let url = running?.bundleURL {
            let root = outermostApplicationURL(for: url)
            if let bundle = Bundle(url: root), let bundleID = bundle.bundleIdentifier, !bundleID.isEmpty {
                return ApplicationIdentity(key: "bundle:\(bundleID)", name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                                           ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                                           ?? root.deletingPathExtension().lastPathComponent,
                                           iconPath: root.path, persistent: true)
            }
        }
        if let bundleID = process.bundleID, !bundleID.isEmpty {
            let shortName = String(bundleID.split(separator: ".").last ?? Substring(bundleID))
            let displayName = running?.localizedName ?? (bundleID.hasPrefix("com.apple.") ? "System · \(shortName)" : shortName)
            return ApplicationIdentity(key: "bundle:\(bundleID)", name: displayName,
                                       iconPath: running?.bundleURL?.path, persistent: true)
        }
        return ApplicationIdentity(key: "temporary:\(pid):\(process.objectID)",
                                   name: running?.localizedName ?? "Process \(pid)", iconPath: running?.bundleURL?.path,
                                   persistent: false)
    }

    static func outermostApplicationURL(for url: URL) -> URL {
        var candidate = url
        var parent = url.deletingLastPathComponent()
        while parent.path != "/" {
            if parent.pathExtension == "app" { candidate = parent }
            parent.deleteLastPathComponent()
        }
        return candidate
    }
}
