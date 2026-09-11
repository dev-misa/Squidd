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
    private(set) var busy = false
    private(set) var message: String?
    private let auth: any SpotifySessionProviding
    private let api: any SpotifyPlaybackRequesting
    private let images: any SpotifyArtworkLoading
    private let pollInterval: Double
    private let reconciliationDelay: Double
    private var worker: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var artworkRetryAt: Date?
    private var generation = UUID()
    private var revision = 0
    private var pending: SpotifyPlaybackCommand?
    private var suspended = false
    private var previewing = false
    private var stopped = false
    private var retryAt: Date?
    private var halted = false
    private var failures = 0
    private var commandMessageUntil: Date?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var seekRollback: Double?

    init(auth: any SpotifySessionProviding, api: (any SpotifyPlaybackRequesting)? = nil,
         images: (any SpotifyArtworkLoading)? = nil, pollInterval: Double = 1,
         reconciliationDelay: Double = 0.4) {
        self.auth = auth
        self.api = api ?? SpotifyPlaybackAPI(auth: auth)
        self.images = images ?? SpotifyArtworkCache()
        self.pollInterval = max(0.05, pollInterval)
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
    func permits(_ command: SpotifyPlaybackCommand) -> Bool {
        auth.hasSession && !busy && !suspended && !previewing && !stopped && !halted &&
        [.playing, .paused, .commandError].contains(state) && snapshot?.permits(command) == true
    }

    func send(_ requested: SpotifyPlaybackCommand) {
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
        if !value { start() }
    }
    func setPreviewing(_ value: Bool) {
        guard previewing != value else { return }
        previewing = value
        cancelWork(clear: true)
        if !value { start() }
    }
    func retry() {
        guard canRetry else { return }
        halted = false; failures = 0; retryAt = nil
        message = nil; commandMessageUntil = nil
        if worker == nil { start() } else { sleeper?.cancel() }
    }
    func stop() { stopped = true; cancelWork(clear: true) }

    private func sessionChanged() {
        cancelWork(clear: true)
        halted = false; retryAt = nil; failures = 0
        if auth.hasSession { start() }
    }
    private var enabled: Bool { auth.hasSession && !suspended && !previewing && !stopped }
    private func start() {
        guard enabled, worker == nil, !halted else { return }
        state = .loading
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
                await self.sleep(self.pollInterval)
            }
            if self.generation == current { self.worker = nil }
        }
    }
    private func valid(_ current: UUID) -> Bool { generation == current && enabled && !Task.isCancelled }
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
            retryAt = Date().addingTimeInterval(delay); state = .rateLimited
        case SpotifyPlaybackError.quotaExceeded:
            halted = true; state = .quotaExceeded
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
        guard changed || (artwork == nil && artworkTask == nil && (artworkRetryAt == nil || artworkRetryAt! <= Date())) else { return }
        artworkTask?.cancel(); artworkTask = nil
        if changed { artworkRetryAt = nil }
        artworkKey = key; artwork = nil
        guard let url, enabled else { return }
        let current = generation
        artworkTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == current && self.artworkKey == key { self.artworkTask = nil }
            }
            do {
                let cgImage = try await self.images.image(for: url)
                guard !Task.isCancelled, self.generation == current, self.artworkKey == key else { return }
                self.artwork = NSImage(cgImage: cgImage, size: .zero)
            } catch {
                if self.generation == current && self.artworkKey == key {
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
        pending = nil; busy = false; seekRollback = nil; isPlaying = false
        if clear {
            snapshot = nil; elapsed = 0; artwork = nil; artworkKey = "idle"; artworkRetryAt = nil
            message = nil; commandMessageUntil = nil; state = .disconnected
        } else if artwork == nil { artworkKey = "idle" }
    }
}
