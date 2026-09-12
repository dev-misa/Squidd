import AppKit
import Observation

enum AppleMusicPlaybackState: Equatable {
    case notRunning, needsPermission, denied, idle, playing, paused, commandError
}

/// Live playback from the Music app.
///
/// Where the Spotify backend has to poll a rate-limited web service, this one is mostly event driven: the Music app
/// broadcasts `com.apple.Music.playerInfo` whenever the track or player state changes, and that notification arrives
/// with no permission required. Apple events are then sent only to fill in what the notification omits — the play
/// position — and to carry transport commands. A slow refresh on top of that catches scrubbing done inside Music
/// itself, which is silent.
@MainActor @Observable
final class AppleMusicPlayback: MusicSource {
    private(set) var state: AppleMusicPlaybackState = .notRunning
    private(set) var track: AppleMusicTrack?
    private(set) var elapsed: Double = 0
    private(set) var isPlaying = false
    private(set) var artwork: NSImage?
    private(set) var artworkKey = "idle"
    private(set) var message: String?
    private(set) var lastActiveAt: Date?
    private(set) var busy = false
    /// Metadata from the notification alone, kept so the card still shows a title when Automation is refused.
    private(set) var permission: AppleMusicPermission = .musicNotRunning

    @ObservationIgnored var didChange: (() -> Void)?

    private let music: any AppleMusicControlling
    private let pollInterval: Double
    private let idlePollInterval: Double
    private let boostInterval: Double
    private let notifications: DistributedNotificationCenter?
    private let workspace: NotificationCenter?
    private var boostUntil: Date?
    private var worker: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private nonisolated let observers = ObserverTokens()
    private var generation = UUID()
    private var revision = 0
    private var pending: PlaybackCommand?
    private var suspended = false
    private var previewing = false
    private var stopped = false
    private var seekRollback: Double?
    private var commandMessageUntil: Date?
    private var lastTick = ProcessInfo.processInfo.systemUptime

    var kind: MusicSourceKind { .appleMusic }

    /// `pollInterval` refreshes the play position while a track runs and `idlePollInterval` while it is paused;
    /// neither costs anything but a local Apple event, so they exist only to catch changes the Music app makes
    /// without announcing them. `boostInterval` is the quick rate used briefly after `boost()`.
    init(music: (any AppleMusicControlling)? = nil, pollInterval: Double = 5, idlePollInterval: Double? = nil,
         boostInterval: Double = 1, notifications: DistributedNotificationCenter? = .default(),
         workspace: NotificationCenter? = NSWorkspace.shared.notificationCenter) {
        self.music = music ?? AppleMusicBridge()
        self.pollInterval = max(0.05, pollInterval)
        self.idlePollInterval = max(0.05, idlePollInterval ?? pollInterval * 3)
        self.boostInterval = max(0.05, boostInterval)
        self.notifications = notifications
        self.workspace = workspace
        observe()
        start()
    }

    /// Registration tokens, held outside the main actor so `deinit` — which is nonisolated — can still hand them
    /// back. A distributed observer outlives the object that registered it and has to be removed explicitly.
    nonisolated final class ObserverTokens: @unchecked Sendable {
        var distributed: [any NSObjectProtocol] = []
        var local: [any NSObjectProtocol] = []
    }

    deinit {
        for token in observers.distributed { notifications?.removeObserver(token) }
        for token in observers.local { workspace?.removeObserver(token) }
    }

    var duration: Double { track?.duration ?? 0 }
    var title: String { track?.title ?? "Nothing playing" }
    var identity: String { track?.identity ?? "idle" }
    var artist: String { message ?? track?.artist ?? status }
    var hasTrack: Bool { track != nil }
    var isAvailable: Bool { state != .notRunning }

    var status: String {
        switch state {
        case .notRunning: "Open Music to start listening"
        case .needsPermission: "Allow Squidd to control Music"
        case .denied: "Music control denied · Open Privacy settings"
        case .idle: "Nothing playing in Music"
        case .playing: "Playing in Music"
        case .paused: "Paused in Music"
        case .commandError: "Playback command failed"
        }
    }

    /// True once Apple events are getting through. Without it the card still shows what the Music app broadcasts,
    /// but the transport buttons and the seek bar stay disabled because nothing can be sent.
    var canControl: Bool { permission == .granted }

    func permits(_ command: PlaybackCommand) -> Bool {
        guard canControl, !busy, !suspended, !previewing, !stopped,
              [.playing, .paused, .commandError].contains(state), track != nil else { return false }
        if case .seek = command { return duration > 0 }
        return true
    }

    func send(_ requested: PlaybackCommand) {
        guard permits(requested) else { return }
        var command = requested
        if case .seek(let seconds) = command {
            guard seconds.isFinite else { return }
            let target = min(max(0, seconds), duration)
            command = .seek(target)
            seekRollback = elapsed
            elapsed = target; lastTick = ProcessInfo.processInfo.systemUptime
        }
        revision += 1 // Any refresh already in flight predates this action.
        pending = command; busy = true
        message = nil; commandMessageUntil = nil
        sleeper?.cancel()
    }

    func setSuspended(_ value: Bool) {
        guard value != suspended else { return }
        suspended = value
        cancelWork(clear: false)
        if !value { start() }
    }

    func setPreviewing(_ value: Bool) {
        guard previewing != value else { return }
        previewing = value
        cancelWork(clear: true)
        if !value { start() }
    }

    func boost(for seconds: Double = 45) {
        guard enabled else { return }
        boostUntil = Date().addingTimeInterval(seconds)
        if worker == nil { start() } else { sleeper?.cancel() }
    }

    func stop() { stopped = true; cancelWork(clear: true) }

    /// Asks macOS for Automation access, showing the system prompt. Only ever called from an explicit button;
    /// every other permission read passes `prompt: false` so the widget never interrupts on its own.
    func requestPermission() async {
        guard !stopped else { return }
        permission = await music.permission(prompt: true)
        refreshNow()
    }

    func openPrivacySettings() {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        NSWorkspace.shared.open(URL(string: url)!)
    }

    func openMusic() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: kind.bundleIdentifier) else {
            NSWorkspace.shared.open(URL(string: "music:")!)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Event sources

    private func observe() {
        // The Music app broadcasts this on every track change and play/pause, so the widget reacts immediately
        // rather than on the next refresh. It carries metadata too, which is the only thing that still works when
        // Automation permission has been refused.
        if let notifications {
            observers.distributed.append(notifications.addObserver(
                forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated { self?.received(note.userInfo) }
                })
        }
        // Launching or quitting Music changes what is reachable, and neither one announces itself over playerInfo.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            guard let workspace else { break }
            observers.local.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == MusicSourceKind.appleMusic.bundleIdentifier else { return }
                MainActor.assumeIsolated { self?.refreshNow() }
            })
        }
    }

    /// Applies what the notification carries, then refreshes so the play position catches up.
    private func received(_ info: [AnyHashable: Any]?) {
        guard enabled else { return }
        if let text = info?["Player State"] as? String {
            let state = AppleMusicPlayerState(notification: text)
            // Only trusted while Apple events are unavailable; otherwise the refresh below is the authority and
            // letting both write would make the state flicker between them.
            if !canControl {
                isPlaying = state.isPlaying
                self.state = state == .stopped ? .idle : (state.isPlaying ? .playing : .paused)
                if let title = info?["Name"] as? String, !title.isEmpty {
                    let seconds = ((info?["Total Time"] as? Double) ?? 0) / 1000
                    let artist = (info?["Artist"] as? String) ?? ""
                    track = AppleMusicTrack(identity: "\(title)|\(artist)|\(Int(seconds))", title: title,
                                            artist: artist.isEmpty ? "Unknown artist" : artist,
                                            album: (info?["Album"] as? String) ?? "", duration: max(0, seconds))
                } else if state == .stopped { track = nil }
                if isPlaying { lastActiveAt = Date() }
                reconcileClock()
                didChange?()
            }
        }
        refreshNow()
    }

    private func refreshNow() {
        guard enabled else { return }
        if worker == nil { start() } else { sleeper?.cancel() }
    }

    // MARK: Loop

    private var enabled: Bool { !suspended && !previewing && !stopped }

    private func start() {
        guard enabled, worker == nil else { return }
        let current = generation
        worker = Task { [weak self] in
            guard let self else { return }
            while self.enabled && !Task.isCancelled && self.generation == current {
                if let command = self.pending {
                    self.pending = nil
                    do {
                        try await self.music.send(command)
                        guard self.valid(current) else { return }
                        self.seekRollback = nil
                    } catch {
                        guard self.valid(current) else { return }
                        if let rollback = self.seekRollback { self.elapsed = rollback; self.seekRollback = nil }
                        self.fail(error)
                    }
                    guard self.valid(current) else { return }
                    self.busy = false
                }
                await self.refresh(current)
                guard self.valid(current) else { return }
                if self.pending != nil { continue }
                await self.sleep(self.nextPollDelay)
            }
            if self.generation == current { self.worker = nil }
        }
    }

    private func valid(_ current: UUID) -> Bool { generation == current && enabled && !Task.isCancelled }

    private var nextPollDelay: Double {
        if let boostUntil, boostUntil > Date() { return boostInterval }
        guard isPlaying else { return idlePollInterval }
        guard duration > 0 else { return pollInterval }
        // Wake as the track ends so the next one appears without waiting out a full interval.
        return min(pollInterval, max(1, duration - elapsed + 0.3))
    }

    private func refresh(_ current: UUID) async {
        let startedAtRevision = revision
        let status = await music.status()
        guard valid(current), startedAtRevision == revision else { return }
        apply(status)
        if status.isRunning && !status.responded {
            // Distinguishes "never asked" from "refused"; neither sends a prompt.
            permission = await music.permission(prompt: false)
            guard valid(current) else { return }
            // With a track from the notification there is still something worth showing, so only the controls go
            // away; with nothing to show, the outstanding permission step becomes the message.
            if track == nil { applyPermissionState() }
        } else if status.responded, permission != .granted {
            permission = .granted
        } else if !status.isRunning, permission != .musicNotRunning {
            permission = .musicNotRunning
        }
    }

    private func apply(_ status: AppleMusicStatus) {
        guard status.isRunning else {
            track = nil; elapsed = 0; isPlaying = false
            state = .notRunning; updateArtwork(nil)
            reconcileClock(); didChange?()
            return
        }
        // Without a reply the notification is all we have, so leave what it set rather than blanking the card.
        guard status.responded else { return }

        let changedTrack = status.track?.identity != track?.identity
        track = status.track
        isPlaying = status.state.isPlaying
        state = status.track == nil ? .idle : (isPlaying ? .playing : .paused)
        // A reported position always wins. Without one, a new track starts at zero rather than inheriting the last
        // one's progress, while the same track keeps whatever the local tick has reached. Clamping to duration
        // pins this at zero for streams, which report no length.
        elapsed = min(duration, max(0, status.position ?? (changedTrack ? 0 : elapsed)))
        if isPlaying { lastActiveAt = Date() }
        if commandMessageUntil == nil || commandMessageUntil! <= Date() {
            message = nil; commandMessageUntil = nil
        }
        updateArtwork(status.track?.identity)
        reconcileClock()
        didChange?()
    }

    private func applyPermissionState() {
        switch permission {
        case .denied: state = .denied
        case .notDetermined: state = .needsPermission
        case .musicNotRunning: state = .notRunning
        case .unknown(let code): state = .denied; message = "Music did not respond (\(code))."
        case .granted: break
        }
        didChange?()
    }

    private func fail(_ error: Error) {
        state = .commandError
        commandMessageUntil = Date().addingTimeInterval(6)
        message = (error as? AppleMusicError)?.localizedDescription ?? "The Music app did not respond to that command."
        if case AppleMusicError.notPermitted = error { permission = .denied }
    }

    private func sleep(_ seconds: Double) async {
        guard !Task.isCancelled else { return }
        let current = generation
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(max(0.01, seconds))) }
        sleeper = task
        await task.value
        if generation == current { sleeper = nil }
    }

    private func reconcileClock() {
        clock?.cancel(); clock = nil
        // Streamed Apple Music tracks report no duration, so there is nothing for a tick to advance towards.
        guard isPlaying, enabled, duration > 0 else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        clock = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.elapsed = min(self.duration, self.elapsed + now - self.lastTick)
                self.lastTick = now
            }
        }
    }

    private func updateArtwork(_ identity: String?) {
        let key = identity.map { "apple-music:\($0)" } ?? "idle"
        guard key != artworkKey else { return }
        artworkTask?.cancel(); artworkTask = nil
        artworkKey = key; artwork = nil
        guard let identity, enabled, canControl else { return }
        let current = generation
        artworkTask = Task { [weak self] in
            guard let self else { return }
            let image = await self.music.artwork(for: identity)
            guard !Task.isCancelled, self.generation == current, self.artworkKey == key else { return }
            self.artworkTask = nil
            if let image { self.artwork = NSImage(cgImage: image, size: .zero) }
        }
    }

    private func cancelWork(clear: Bool) {
        generation = UUID(); revision += 1
        worker?.cancel(); worker = nil
        sleeper?.cancel(); sleeper = nil
        clock?.cancel(); clock = nil
        artworkTask?.cancel(); artworkTask = nil
        pending = nil; busy = false; seekRollback = nil; isPlaying = false
        if clear {
            track = nil; elapsed = 0; artwork = nil; artworkKey = "idle"
            message = nil; commandMessageUntil = nil; state = .notRunning
        }
        didChange?()
    }
}
