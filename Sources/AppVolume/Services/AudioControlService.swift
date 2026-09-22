import AppKit
import AudioBackend

@MainActor
final class AudioControlService: NSObject, ObservableObject {
    @Published private(set) var applications: [AudioApplication] = []
    @Published private(set) var outputName = "No output device"
    @Published private(set) var paused = true
    @Published private(set) var notice: String? = "Control paused. Apps play at their original volume."
    @Published private(set) var canRetry = false

    private let store = VolumePreferencesStore()
    private var sessions: [String: AVTapSession] = [:]
    private var identities: [String: ApplicationIdentity] = [:]
    private var timer: Timer?
    private var outputID = AVSystemAudio.defaultOutputID()
    private var deviceReconnecting = false
    private var waking = false
    private var lastNonzero: [String: UInt64] = [:]
    private var sessionStartedAt: [String: Date] = [:]
    private var blockedErrors: [String: String] = [:]
    private var lastRefresh = Date.distantPast

    override init() {
        super.init()
        outputName = AVSystemAudio.defaultOutputName() ?? "No output device"
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willTerminate), name: NSApplication.willTerminateNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    @objc private func willSleep() {
        waking = true
        stopAll()
        notice = "Mac is sleeping. Audio will reconnect after wake."
        canRetry = false
    }

    @objc private func didWake() {
        stopAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.waking = false
            self?.refresh()
        }
    }

    @objc private func willTerminate() {
        timer?.invalidate()
        stopAll()
    }

    func togglePause() {
        paused.toggle()
        if paused {
            stopAll()
            notice = "Control paused. Apps play at their original volume."
            canRetry = false
        } else {
            notice = nil
            canRetry = false
            refresh()
        }
    }

    func retry() {
        notice = nil
        canRetry = false
        blockedErrors.removeAll()
        stopAll()
        paused = false
        refresh()
    }

    func setVolume(_ value: Double, for key: String) {
        guard let index = applications.firstIndex(where: { $0.id == key }), let identity = identities[key] else { return }
        applications[index].setting.setVolume(value)
        store.save(applications[index].setting, for: identity)
        sessions[key]?.setGain(applications[index].effectiveGain)
    }

    func toggleMute(for key: String) {
        guard let index = applications.firstIndex(where: { $0.id == key }), let identity = identities[key] else { return }
        applications[index].setting.muted.toggle()
        store.save(applications[index].setting, for: identity)
        sessions[key]?.setGain(applications[index].effectiveGain)
    }

    func resetAll() {
        store.reset()
        for index in applications.indices {
            applications[index].setting = VolumeSetting()
            sessions[applications[index].id]?.setGain(1)
        }
    }

    private func stopAll() {
        for session in sessions.values { session.stop() }
        sessions.removeAll()
        sessionStartedAt.removeAll()
    }

    private func refresh() {
        let currentOutput = AVSystemAudio.defaultOutputID()
        outputName = AVSystemAudio.defaultOutputName() ?? "No output device"
        if currentOutput != outputID {
            stopAll()
            blockedErrors.removeAll()
            outputID = currentOutput
            deviceReconnecting = true
            notice = "Output device changed. Reconnecting audio."
            canRetry = false
            lastRefresh = Date()
            return
        }
        if Date().timeIntervalSince(lastRefresh) < 0.5 { return }
        lastRefresh = Date()
        if deviceReconnecting {
            deviceReconnecting = false
            notice = paused ? "Control paused. Apps play at their original volume." : nil
        }
        let processes = AVSystemAudio.outputProcesses()
        let groups = Dictionary(grouping: processes, by: { ApplicationIdentityResolver.resolve($0).key })
        var rows: [AudioApplication] = []
        var seen: Set<String> = []
        for (key, members) in groups {
            guard let first = members.first else { continue }
            let identity = ApplicationIdentityResolver.resolve(first)
            identities[key] = identity
            let ids = members.map { NSNumber(value: $0.objectID) }.sorted { $0.uint32Value < $1.uint32Value }
            let routeOK = members.allSatisfy(\.usesDefaultOutput)
            let old = applications.first { $0.id == key }
            let setting = old?.setting ?? store.setting(for: identity)
            if old?.processIDs != ids { blockedErrors.removeValue(forKey: key) }
            var status: String? = routeOK ? nil : "Different output device; bypassed"
            if let session = sessions[key], session.faulted {
                session.stop(); sessions.removeValue(forKey: key)
                sessionStartedAt.removeValue(forKey: key)
                status = "Audio format changed; original playback restored"
                blockedErrors[key] = status
                notice = "Unsupported audio format. Control stopped; click Retry."
                canRetry = true
            }
            if let session = sessions[key], session.callbackCount == 0,
               Date().timeIntervalSince(sessionStartedAt[key] ?? Date()) > 3 {
                session.stop(); sessions.removeValue(forKey: key)
                sessionStartedAt.removeValue(forKey: key)
                blockedErrors[key] = "No audio callback; original playback restored"
                notice = "Audio did not start. Check system audio capture access, then click Retry."
                canRetry = true
            }
            if let blocked = blockedErrors[key] { status = blocked }
            if !paused && !waking && routeOK && currentOutput != kAudioObjectUnknown && status == nil {
                if old?.processIDs != ids {
                    sessions[key]?.stop()
                    sessions.removeValue(forKey: key)
                    sessionStartedAt.removeValue(forKey: key)
                }
                if sessions[key] == nil {
                    let session = AVTapSession(processObjectIDs: ids, outputDevice: currentOutput,
                                               gain: setting.muted ? 0 : Float(setting.volume / 100))
                    do {
                        try session.start()
                        sessions[key] = session
                        sessionStartedAt[key] = Date()
                    } catch {
                        status = "\(error.localizedDescription)"
                        blockedErrors[key] = status
                        notice = "Audio control did not start. Check system audio capture access, then click Retry."
                        canRetry = true
                    }
                }
            }
            let count = sessions[key]?.nonzeroFrameCount ?? 0
            let nonzero = count > (lastNonzero[key] ?? count)
            lastNonzero[key] = count
            let icon = identity.iconPath.map { NSWorkspace.shared.icon(forFile: $0) }
                ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Audio process")!
            rows.append(AudioApplication(id: key, name: identity.name, icon: icon, processIDs: ids,
                                         usesDefaultOutput: routeOK, lastSeen: Date(), hasNonzeroSamples: nonzero,
                                         status: status, setting: setting))
            seen.insert(key)
        }
        for old in applications where !seen.contains(old.id) && Date().timeIntervalSince(old.lastSeen) < 5 {
            rows.append(old)
            seen.insert(old.id)
        }
        for key in Array(sessions.keys) where !seen.contains(key) {
            sessions[key]?.stop(); sessions.removeValue(forKey: key)
            sessionStartedAt.removeValue(forKey: key)
            identities.removeValue(forKey: key); lastNonzero.removeValue(forKey: key)
            blockedErrors.removeValue(forKey: key)
        }
        applications = rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
