import AppKit
import Observation
import ServiceManagement
import SwiftUI

enum PreviewState: String, CaseIterable, Identifiable {
    case off = "Off", playing = "Playing", paused = "Paused", idle = "Idle", error = "Error"
    var id: String { rawValue }
}

enum InkMode: String, CaseIterable {
    case automatic = "Automatic", white = "White", dark = "Dark grey", scrim = "White on scrim"
}

extension Color {
    init?(hex: String) {
        var hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hex.removeAll { $0 == "#" }
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        self = Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    var hexString: String {
        let ns = (NSColor(self).usingColorSpace(.deviceRGB)) ?? NSColor(self)
        return String(format: "#%02X%02X%02X", Int(round(ns.redComponent * 255)), Int(round(ns.greenComponent * 255)), Int(round(ns.blueComponent * 255)))
    }
}

@MainActor @Observable
final class AppStore {
    let spotify: SpotifyAuth
    let playback: SpotifyPlayback
    let appleMusic: AppleMusicPlayback
    /// Which backend the card and launcher are showing right now.
    private(set) var activeKind: MusicSourceKind = .spotify
    /// nil follows whichever service is playing; a value pins one regardless.
    var sourcePreference: MusicSourceKind? {
        didSet {
            defaults.set(sourcePreference?.rawValue ?? Self.automaticSource, forKey: "musicSource")
            reconcileSource()
        }
    }
    var preview: PreviewState = .off
    var cardVisible = true
    var sleeping = false
    private var previewElapsed: Double = 0
    private let previewDuration: Double = 212
    var elapsed: Double { preview == .off ? source.elapsed : previewElapsed }
    var duration: Double { preview == .off ? source.duration : previewDuration }
    var sampleIndex = 0
    var shortcutErrors: [String] = []
    var preferenceError: String?
    var loginStatus = SMAppService.mainApp.status
    var inkChoices: [String: String]
    var customMascotPath: String? { didSet { defaults.set(customMascotPath, forKey: "customMascotPath") } }
    var rimPrimaryHex: String? { didSet { defaults.set(rimPrimaryHex, forKey: "rimPrimaryHex") } }
    var rimAccentHex: String? { didSet { defaults.set(rimAccentHex, forKey: "rimAccentHex") } }
    var showCardOutline: Bool { didSet { defaults.set(showCardOutline, forKey: "showCardOutline") } }
    static let automaticSource = "automatic"
    static let defaultRimPrimary = Color(hex: "#8D0305") ?? Color(red: 0.55, green: 0.01, blue: 0.02)
    static let defaultRimAccent = Color(hex: "#FAFFF5") ?? .white
    private let defaults: UserDefaults
    private var tick: Task<Void, Never>?
    private var lastTick = ProcessInfo.processInfo.systemUptime

    /// `appleMusic` is injectable so checks can drive a stand-in for the Music app.
    init(defaults: UserDefaults = .standard, appleMusic: AppleMusicPlayback? = nil) {
        self.defaults = defaults
        spotify = SpotifyAuth(defaults: defaults)
        // Steady polling stays modest — the progress bar ticks locally and a track's end is anticipated — and drops
        // to 1.5s bursts when a change is likely: Spotify activating, the card opening, or waking from sleep.
        // Roughly 240–900 requests an hour against the Spotify app's quota; polling pauses while the Mac sleeps.
        playback = SpotifyPlayback(auth: spotify, pollInterval: 4, idlePollInterval: 10, boostInterval: 1.5,
                                   defaults: defaults)
        // Apple Music updates arrive by notification from the Music app, so these intervals only correct the play
        // position when someone scrubs inside Music itself. They cost a local Apple event, not a metered request.
        self.appleMusic = appleMusic ?? AppleMusicPlayback(pollInterval: 5, idlePollInterval: 15, boostInterval: 1)
        inkChoices = defaults.dictionary(forKey: "inkOverrides") as? [String: String] ?? [:]
        customMascotPath = defaults.string(forKey: "customMascotPath")
        rimPrimaryHex = defaults.string(forKey: "rimPrimaryHex")
        rimAccentHex = defaults.string(forKey: "rimAccentHex")
        showCardOutline = defaults.object(forKey: "showCardOutline") as? Bool ?? true
        // Assigned once every stored property exists, because its observer reaches back into `self`.
        let saved = defaults.string(forKey: "musicSource") ?? Self.automaticSource
        sourcePreference = saved == Self.automaticSource ? nil : MusicSourceKind(rawValue: saved)
        for source in sources { source.didChange = { [weak self] in self?.reconcileSource() } }
        reconcileSource()
    }

    // MARK: Source selection

    /// Apple Music first: on a Mac with neither service set up, the built-in player is the better thing to show.
    var sources: [any MusicSource] { [appleMusic, playback] }
    var source: any MusicSource { activeKind == .appleMusic ? appleMusic : playback }

    /// Picks the backend to follow. A pinned choice always wins. Otherwise whichever service is actually playing
    /// takes the card, and when neither is, the current one keeps it as long as it still has a track loaded —
    /// so pausing Spotify doesn't hand the widget to an idle Music app and back again.
    private func reconcileSource() {
        if let pinned = sourcePreference { activeKind = pinned; return }
        let candidates = sources.filter(\.isAvailable)
        guard !candidates.isEmpty else { return }
        let playing = candidates.filter(\.isPlaying)
        if playing.count == 1 { activeKind = playing[0].kind; return }
        if playing.count > 1 {
            activeKind = playing.max { ($0.lastActiveAt ?? .distantPast) < ($1.lastActiveAt ?? .distantPast) }!.kind
            return
        }
        if let current = candidates.first(where: { $0.kind == activeKind }), current.hasTrack { return }
        if let loaded = candidates.first(where: \.hasTrack) { activeKind = loaded.kind; return }
        if let recent = candidates.filter({ $0.lastActiveAt != nil }).max(by: { $0.lastActiveAt! < $1.lastActiveAt! }) {
            activeKind = recent.kind
            return
        }
        if !candidates.contains(where: { $0.kind == activeKind }) { activeKind = candidates[0].kind }
    }

    /// Sleep and wake reach every backend, not just the one on screen, so neither keeps working behind a closed lid.
    func setSuspended(_ value: Bool) { for source in sources { source.setSuspended(value) } }
    func boostSources(for seconds: Double = 45) { for source in sources { source.boost(for: seconds) } }
    func boost(_ kind: MusicSourceKind, for seconds: Double = 45) {
        sources.first { $0.kind == kind }?.boost(for: seconds)
    }

    var customMascotURL: URL? { customMascotPath.map { URL(fileURLWithPath: $0) } }
    var rimPrimaryColor: Color { rimPrimaryHex.flatMap { Color(hex: $0) } ?? AppStore.defaultRimPrimary }
    var rimAccentColor: Color { rimAccentHex.flatMap { Color(hex: $0) } ?? AppStore.defaultRimAccent }
    /// True while the ring still uses the built-in colors, so Settings can hide its Reset button.
    var rimIsDefault: Bool {
        rimPrimaryColor.hexString == AppStore.defaultRimPrimary.hexString
            && rimAccentColor.hexString == AppStore.defaultRimAccent.hexString
    }

    func setRimColors(primary: Color, accent: Color) {
        rimPrimaryHex = primary.hexString
        rimAccentHex = accent.hexString
    }

    func resetRimColors() {
        rimPrimaryHex = nil
        rimAccentHex = nil
    }

    private var customAssetsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Squidd", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func removingExisting(prefix: String, in directory: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix(prefix) { try? FileManager.default.removeItem(at: item) }
    }

    func setCustomMascot(from source: URL) {
        let directory = customAssetsDirectory
        removingExisting(prefix: "custom-mascot-", in: directory)
        let ext = source.pathExtension.isEmpty ? "gif" : source.pathExtension
        let destination = directory.appendingPathComponent("custom-mascot-\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            customMascotPath = destination.path
            preferenceError = nil
        } catch { preferenceError = "Custom mascot: \(error.localizedDescription)" }
    }

    func resetCustomMascot() {
        if let path = customMascotPath { try? FileManager.default.removeItem(atPath: path) }
        customMascotPath = nil
    }

    var isPlaying: Bool { preview == .off ? source.isPlaying : preview == .playing }
    var canControl: Bool {
        preview == .off ? (source.permits(.play) || source.permits(.pause) || source.permits(.next) || source.permits(.previous))
            : preview == .playing || preview == .paused
    }
    var canSeek: Bool { preview == .off ? source.permits(.seek(elapsed)) : canControl }
    var title: String { preview == .off ? source.title : (canControl ? (sampleIndex == 0 ? "Preview track" : "Preview track 2") : "Nothing playing") }
    var artist: String {
        switch preview {
        // Before a Spotify session exists the backend has nothing to say, so the connection state stands in.
        case .off: activeKind == .spotify && !spotify.hasSession ? spotify.status : source.artist
        case .idle: "Preview · No active device"
        case .error: "Preview · Playback unavailable"
        default: sampleIndex == 0 ? "Preview · Squidd" : "Preview · Sabrina Carpenter"
        }
    }
    var artworkKey: String { preview == .off ? source.artworkKey : (canControl ? "preview://artwork/\(sampleIndex)" : "idle") }
    var trackIdentity: String { preview == .off ? source.identity : "preview:\(sampleIndex)" }
    var artwork: NSImage? { preview == .off ? source.artwork : nil }
    /// True when there's real album art, or preview art standing in for it, so the launcher can drop the empty slot.
    var showsArtwork: Bool { artwork != nil || (preview != .off && canControl) }
    var ink: InkMode { InkMode(rawValue: inkChoices[artworkKey] ?? "") ?? .automatic }
    var shownDuration: Double { preview == .off ? source.duration : (canControl ? duration : 0) }
    /// False when the service reports no track length — Apple Music streams expose neither duration nor position —
    /// in which case the card hides the scrubber rather than showing one frozen at zero.
    var showsTimeline: Bool { preview == .off ? source.duration > 0 : canControl }

    func permits(_ command: PlaybackCommand) -> Bool { preview == .off ? source.permits(command) : canControl }

    func setInk(_ mode: InkMode) {
        if mode == .automatic { inkChoices.removeValue(forKey: artworkKey) }
        else { inkChoices[artworkKey] = mode.rawValue }
        defaults.set(inkChoices, forKey: "inkOverrides")
    }

    func forgetInk() { inkChoices = [:]; defaults.removeObject(forKey: "inkOverrides") }

    func selectPreview(_ state: PreviewState) {
        preview = state
        previewElapsed = 0
        for source in sources { source.setPreviewing(state != .off) }
        reconcileClock()
    }

    func togglePlayback() {
        if preview == .off { source.send(isPlaying ? .pause : .play); return }
        guard canControl else { return }
        preview = isPlaying ? .paused : .playing
        reconcileClock()
    }

    func skip(previous: Bool = false) {
        if preview == .off { source.send(previous ? .previous : .next); return }
        guard canControl else { return }; sampleIndex = 1 - sampleIndex; previewElapsed = 0
    }
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        if preview == .off { source.send(.seek(seconds)); return }
        guard canControl else { return }; previewElapsed = max(0, min(seconds, duration))
    }

    func openSpotify() {
        if !NSWorkspace.shared.open(URL(string: "spotify:")!) {
            NSWorkspace.shared.open(URL(string: "https://open.spotify.com")!)
        }
    }

    /// Opens whichever service the widget is currently following.
    func openActiveApp() {
        if activeKind == .appleMusic { appleMusic.openMusic() } else { openSpotify() }
    }

    func reconcileClock() {
        tick?.cancel()
        tick = nil
        guard preview == .playing && !sleeping else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        tick = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                guard let self else { break }
                let now = ProcessInfo.processInfo.systemUptime
                self.previewElapsed = min(self.duration, self.previewElapsed + now - self.lastTick)
                self.lastTick = now
                if self.elapsed >= self.duration { self.skip() }
            }
        }
    }

    func stop() {
        tick?.cancel(); tick = nil
        for source in sources { source.stop() }
        spotify.stop()
    }

    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            else { try SMAppService.mainApp.register() }
            preferenceError = nil
        } catch { preferenceError = "Launch at Login: \(error.localizedDescription)" }
        loginStatus = SMAppService.mainApp.status
    }

    var loginDescription: String {
        switch loginStatus {
        case .enabled: "Enabled"
        case .requiresApproval: "Needs approval in System Settings"
        case .notRegistered: "Off"
        case .notFound: "Unavailable for this app installation"
        @unknown default: "Unknown"
        }
    }
}
