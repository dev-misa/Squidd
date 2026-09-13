import AppKit
import Observation

enum SpotifyPlaybackState: Equatable {
    case disconnected, loading, idle, playing, paused, offline, rateLimited, quotaExceeded, accessDenied, commandError
}

@MainActor @Observable
final class SpotifyPlayback {
    private(set) var state: SpotifyPlaybackState = .disconnected
    private(set) var snapshot: SpotifyPlaybackSnapshot?
    private(set) var elapsed: Double = 0
    private(set) var isPlaying = false
    private(set) var artwork: NSImage?
    private(set) var artworkKey = "idle"
    /// Key of the image in `artwork`. Trails `artworkKey` while a replacement loads, since the old image stays up.
    private(set) var loadedArtworkKey = "idle"
    private(set) var busy = false
    private(set) var message: String?
    private let auth: any SpotifySessionProviding
    private let api: any SpotifyPlaybackRequesting
    private let images: any SpotifyArtworkLoading
    private let pollInterval: Double
    private let idlePollInterval: Double
    private let emptyPollInterval: Double
    private let backgroundPollInterval: Double
    private let backgroundIdlePollInterval: Double
    private let boostInterval: Double
    private var boostUntil: Date?
    private var background = false
    private let reconciliationDelay: Double
    private var worker: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?
    private var artworkRetryAt: Date?
    private var generation = UUID()
    private var revision = 0
    private var pending: PlaybackCommand?
    private var suspended = false
    private var previewing = false
    private var stopped = false
    private var retryAt: Date?
    private var halted = false
    /// When a quota halt lifts on its own. Kept apart from `resumeTask` so a suspension can reschedule it.
    private var quotaResumeAt: Date?
    private var failures = 0
    private var commandMessageUntil: Date?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var seekRollback: Double?
    private let defaults: UserDefaults?
    private static let retryKey = "spotifyPlaybackRetryAt"

    /// `pollInterval` applies while a track plays and `idlePollInterval` while paused, defaulting to three times the
    /// playing rate; `emptyPollInterval` applies when no track is loaded at all, defaulting to the paused rate.
    /// While `setBackground(true)` is in effect — the card hidden, only the launcher showing — the two background
    /// rates replace those, defaulting to three times the foreground ones. `boostInterval` is the quick rate used
    /// briefly after `boost()`. Each poll is one request per running copy against the Spotify app's quota, so steady
    /// rates stay modest and bursts cover the moments a change is likely.
    init(auth: any SpotifySessionProviding, api: (any SpotifyPlaybackRequesting)? = nil,
         images: (any SpotifyArtworkLoading)? = nil, pollInterval: Double = 5, idlePollInterval: Double? = nil,
         emptyPollInterval: Double? = nil, backgroundPollInterval: Double? = nil,
         backgroundIdlePollInterval: Double? = nil,
         boostInterval: Double = 1.5, reconciliationDelay: Double = 0.4, defaults: UserDefaults? = nil) {
        self.auth = auth
        self.defaults = defaults
        self.api = api ?? SpotifyPlaybackAPI(auth: auth)
        self.images = images ?? SpotifyArtworkCache()
        self.pollInterval = max(0.05, pollInterval)
        self.idlePollInterval = max(0.05, idlePollInterval ?? pollInterval * 3)
        self.emptyPollInterval = max(0.05, emptyPollInterval ?? self.idlePollInterval)
        self.backgroundPollInterval = max(0.05, backgroundPollInterval ?? self.pollInterval * 3)
        self.backgroundIdlePollInterval = max(0.05, backgroundIdlePollInterval ?? self.idlePollInterval * 3)
        self.boostInterval = max(0.05, boostInterval)
        self.reconciliationDelay = max(0, reconciliationDelay)
        auth.sessionDidChange = { [weak self] in self?.sessionChanged() }
        if auth.hasSession { sessionChanged() }
    }

    var duration: Double { snapshot?.duration ?? 0 }
    var title: String { snapshot?.title ?? "Nothing playing" }
    var identity: String { snapshot?.identity ?? "idle" }
    var artist: String { message ?? snapshot?.item?.artist ?? status }
    var status: String {
        switch state {
        case .disconnected: "Spotify not connected"
        case .loading: "Checking Spotify…"
        case .idle: "Open Spotify to start listening"
        case .playing: "Playing on \(snapshot?.device?.name ?? "Spotify")"
        case .paused: "Paused on \(snapshot?.device?.name ?? "Spotify")"
        case .offline: "Spotify unavailable · Retrying"
        case .rateLimited: "Spotify rate limit · Waiting"
        case .quotaExceeded: "Spotify quota exhausted"
        case .accessDenied: "Spotify playback access denied"
        case .commandError: "Playback command failed"
        }
    }
    var canRetry: Bool { auth.hasSession && !busy && !suspended && !previewing && (retryAt == nil || retryAt! <= Date()) }
    /// Whether `command` is available at all, regardless of a command already on its way. Buttons use this, so
    /// sending one doesn't dim the others for the moment Spotify takes to confirm it.
    func offers(_ command: PlaybackCommand) -> Bool {
        auth.hasSession && !suspended && !previewing && !stopped && !halted &&
        [.playing, .paused, .commandError].contains(state) && snapshot?.permits(command) == true
    }
    /// Whether `send` would accept `command` right now: offered, and no other command still in flight.
    func permits(_ command: PlaybackCommand) -> Bool { !busy && offers(command) }

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
        revision += 1 // Any already-running GET predates this user action.
        pending = command; busy = true
        message = nil; commandMessageUntil = nil
        sleeper?.cancel()
    }

    func setSuspended(_ value: Bool) {
        guard value != suspended else { return }
        suspended = value
        cancelWork(clear: false)
        if !value { resumeAfterPause() }
    }
    func setPreviewing(_ value: Bool) {
        guard previewing != value else { return }
        previewing = value
        cancelWork(clear: true)
        if !value { resumeAfterPause() }
    }
    /// Pausing cancels the timer that lifts a quota halt, so re-arm it for whatever remains of the wait.
    private func resumeAfterPause() {
        if halted, let quotaResumeAt { scheduleQuotaResume(after: quotaResumeAt.timeIntervalSinceNow) }
        start()
    }
    /// Slows steady polling while only the launcher is showing. It still wakes at the end of a playing track, so the
    /// launcher's artwork keeps up; returning to the foreground takes effect after the current wait, or at once
    /// with `boost()`.
    func setBackground(_ value: Bool) { background = value }
    func retry() {
        guard canRetry else { return }
        resumeTask?.cancel(); resumeTask = nil
        halted = false; quotaResumeAt = nil; failures = 0; retryAt = nil
        message = nil; commandMessageUntil = nil
        if worker == nil { start() } else { sleeper?.cancel() }
    }

    /// Polls quickly for a short while, for moments when something is likely to change: Spotify coming to the front,
    /// the player card opening, or waking from sleep. A pending rate limit or quota wait is left alone.
    func boost(for seconds: Double = 45) {
        guard enabled, !halted else { return }
        boostUntil = Date().addingTimeInterval(seconds)
        if worker == nil { start() } else if retryAt == nil { sleeper?.cancel() }
    }

    /// Lifts a quota halt once Spotify's allowance has had time to recover, so the widget comes back on its own.
    private func scheduleQuotaResume(after seconds: Double) {
        resumeTask?.cancel()
        let current = generation
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, seconds)))
            guard !Task.isCancelled, let self, self.generation == current, self.halted else { return }
            self.resumeTask = nil
            self.halted = false
            self.quotaResumeAt = nil
            self.failures = 0
            self.message = nil
            self.start()
        }
    }
    func stop() { stopped = true; cancelWork(clear: true) }

    private func sessionChanged() {
        cancelWork(clear: true)
        halted = false; quotaResumeAt = nil; failures = 0
        // Rate limits apply to the Client ID, so a pending wait outlives relaunches and reconnects.
        retryAt = (defaults?.object(forKey: Self.retryKey) as? Date).flatMap { $0 > Date() ? $0 : nil }
        guard auth.hasSession else { return }
        if let retryAt { state = .rateLimited; message = Self.rateLimitMessage(until: retryAt) }
        start()
    }
    private var enabled: Bool { auth.hasSession && !suspended && !previewing && !stopped }
    private func start() {
        guard enabled, worker == nil, !halted else { return }
        if retryAt == nil || retryAt! <= Date() { state = .loading } // Keep showing a pending wait.
        let current = generation
        worker = Task { [weak self] in
            guard let self else { return }
            while self.enabled && !Task.isCancelled && self.generation == current && !self.halted {
                if let retryAt = self.retryAt, retryAt > Date() {
                    await self.sleep(retryAt.timeIntervalSinceNow)
                    continue
                }
                self.retryAt = nil
                if let command = self.pending {
                    self.pending = nil
                    do {
                        try await self.api.send(command)
                        guard self.valid(current) else { return }
                        self.seekRollback = nil
                        try await Task.sleep(for: .seconds(self.reconciliationDelay))
                        guard self.valid(current) else { return }
                        await self.poll(current)
                    } catch {
                        guard self.valid(current) else { return }
                        if let rollback = self.seekRollback { self.elapsed = rollback; self.seekRollback = nil }
                        self.handle(error, command: true)
                    }
                    guard self.valid(current) else { return }
                    self.busy = false
                } else { await self.poll(current) }
                guard self.valid(current) else { return }
                if self.pending != nil { continue }
                await self.sleep(self.nextPollDelay)
            }
            if self.generation == current { self.worker = nil }
        }
    }
    private func valid(_ current: UUID) -> Bool { generation == current && enabled && !Task.isCancelled }
    /// Wakes near the end of a playing track so the next one shows promptly; polls rarely when nothing changes.
    private var nextPollDelay: Double {
        if let boostUntil, boostUntil > Date() { return boostInterval }
        guard isPlaying else {
            if background { return backgroundIdlePollInterval }
            return snapshot?.item == nil ? emptyPollInterval : idlePollInterval
        }
        let steady = background ? backgroundPollInterval : pollInterval
        guard duration > 0 else { return steady }
        return min(steady, max(2, duration - elapsed + 0.5))
    }
    private static func rateLimitMessage(until date: Date) -> String {
        let time = Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
        return "Spotify rate limit · Retrying at \(time)"
    }
    private static func quotaMessage(until date: Date) -> String {
        let time = Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
        return "Spotify’s development quota is exhausted · Retrying at \(time)"
    }
    private func sleep(_ seconds: Double) async {
        guard !Task.isCancelled else { return }
        let current = generation
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(max(0.01, seconds))) }
        sleeper = task
        await task.value
        if generation == current { sleeper = nil }
    }
    private func poll(_ current: UUID) async {
        let startedAtRevision = revision
        do {
            let value = try await api.snapshot()
            guard valid(current), startedAtRevision == revision else { return }
            failures = 0
            if defaults?.object(forKey: Self.retryKey) != nil { defaults?.removeObject(forKey: Self.retryKey) }
            apply(value)
        } catch {
            guard valid(current) else { return }
            // Rate/quota failures constrain even a command queued during this GET.
            if startedAtRevision != revision {
                switch error {
                case SpotifyPlaybackError.rateLimited, SpotifyPlaybackError.quotaExceeded,
                     SpotifyPlaybackError.forbidden, SpotifyAuthError.retryAfter:
                    if let rollback = seekRollback { elapsed = rollback; seekRollback = nil }
                    pending = nil; busy = false
                default: return
                }
            }
            handle(error, command: false)
        }
    }
    private func apply(_ value: SpotifyPlaybackSnapshot?) {
        snapshot = value
        elapsed = value?.elapsed ?? 0
        isPlaying = value?.is_playing == true
        state = value?.item == nil ? .idle : (isPlaying ? .playing : .paused)
        if commandMessageUntil == nil || commandMessageUntil! <= Date() {
            message = nil; commandMessageUntil = nil
        }
        if value?.currently_playing_type == "ad" { message = "Advertisement · Controls unavailable" }
        else if value?.item == nil && value?.is_playing == true { message = "Spotify is playing · Metadata unavailable" }
        updateArtwork(value?.item?.artworkURL)
        reconcileClock()
    }
    private func handle(_ error: Error, command: Bool) {
        isPlaying = false; clock?.cancel(); clock = nil
        if command {
            state = .commandError
            commandMessageUntil = Date().addingTimeInterval(6)
        } else { state = .offline }
        failures = min(8, failures + 1)
        let backoff = min(60, pow(2, Double(failures)))
        switch error {
        case SpotifyPlaybackError.rateLimited(let delay), SpotifyAuthError.retryAfter(let delay):
            let until = Date().addingTimeInterval(delay)
            retryAt = until; state = .rateLimited
            defaults?.set(until, forKey: Self.retryKey)
            message = Self.rateLimitMessage(until: until)
            return
        case SpotifyPlaybackError.quotaExceeded:
            // Stop polling, but lift the halt unaided once the quota has had time to free up: 10 minutes, doubling
            // to an hour if it keeps failing. Access denial below stays halted, since waiting doesn't fix that.
            halted = true; state = .quotaExceeded
            let wait = min(3600, 600 * pow(2, Double(max(0, failures - 1))))
            quotaResumeAt = Date().addingTimeInterval(wait)
            scheduleQuotaResume(after: wait)
            message = Self.quotaMessage(until: Date().addingTimeInterval(wait))
            return
        case SpotifyPlaybackError.forbidden:
            halted = true; state = .accessDenied
        case SpotifyPlaybackError.noDevice:
            snapshot = nil; elapsed = 0; updateArtwork(nil); state = .idle
            retryAt = Date().addingTimeInterval(max(2, pollInterval))
        case SpotifyPlaybackError.unauthorized, SpotifyAuthError.reconnect:
            auth.requireReconnect()
            return
        default:
            retryAt = Date().addingTimeInterval(backoff)
        }
        if let known = error as? SpotifyPlaybackError { message = known.localizedDescription }
        else if let known = error as? SpotifyAuthError { message = known.localizedDescription }
        else { message = command ? "Command failed. Check your connection and try again." : "Connection lost · Retrying Spotify" }
    }
    private func reconcileClock() {
        clock?.cancel(); clock = nil
        guard isPlaying, enabled else { return }
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
    private func updateArtwork(_ url: URL?) {
        let key = url?.absoluteString ?? "idle"
        let changed = key != artworkKey
        guard changed || (loadedArtworkKey != key && artworkTask == nil && (artworkRetryAt == nil || artworkRetryAt! <= Date())) else { return }
        artworkTask?.cancel(); artworkTask = nil
        if changed { artworkRetryAt = nil }
        artworkKey = key
        guard let url else { artwork = nil; loadedArtworkKey = "idle"; return }
        guard enabled else { return }
        // Keep the displayed image until its replacement is decoded.
        let current = generation
        artworkTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled && self.generation == current && self.artworkKey == key { self.artworkTask = nil }
            }
            do {
                let cgImage = try await self.images.image(for: url)
                guard !Task.isCancelled, self.generation == current, self.artworkKey == key else { return }
                self.artwork = NSImage(cgImage: cgImage, size: .zero)
                self.loadedArtworkKey = key
            } catch {
                if !Task.isCancelled && self.generation == current && self.artworkKey == key {
                    self.artwork = nil
                    self.loadedArtworkKey = "idle"
                    self.artworkRetryAt = Date().addingTimeInterval(30)
                }
            }
        }
    }
    private func cancelWork(clear: Bool) {
        generation = UUID(); revision += 1
        worker?.cancel(); worker = nil
        sleeper?.cancel(); sleeper = nil
        clock?.cancel(); clock = nil
        artworkTask?.cancel(); artworkTask = nil
        resumeTask?.cancel(); resumeTask = nil
        pending = nil; busy = false; seekRollback = nil; isPlaying = false
        if clear {
            snapshot = nil; elapsed = 0; artwork = nil; artworkKey = "idle"; loadedArtworkKey = "idle"; artworkRetryAt = nil
            message = nil; commandMessageUntil = nil; state = .disconnected
        } else if artwork == nil { artworkKey = "idle" }
    }
}
