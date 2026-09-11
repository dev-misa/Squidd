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
    var preview: PreviewState = .off
    var cardVisible = true
    var sleeping = false
    private var previewElapsed: Double = 0
    private let previewDuration: Double = 212
    var elapsed: Double { preview == .off ? playback.elapsed : previewElapsed }
    var duration: Double { preview == .off ? playback.duration : previewDuration }
    var sampleIndex = 0
    var shortcutErrors: [String] = []
    var preferenceError: String?
    var loginStatus = SMAppService.mainApp.status
    var inkChoices: [String: String]
    var customMascotPath: String? { didSet { defaults.set(customMascotPath, forKey: "customMascotPath") } }
    var rimPrimaryHex: String? { didSet { defaults.set(rimPrimaryHex, forKey: "rimPrimaryHex") } }
    var rimAccentHex: String? { didSet { defaults.set(rimAccentHex, forKey: "rimAccentHex") } }
    var showCardOutline: Bool { didSet { defaults.set(showCardOutline, forKey: "showCardOutline") } }
    static let defaultRimPrimary = Color(red: 0.4, green: 0.2, blue: 0.6)
    static let defaultRimAccent = Color.white
    private let defaults: UserDefaults
    private var tick: Task<Void, Never>?
    private var lastTick = ProcessInfo.processInfo.systemUptime

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        spotify = SpotifyAuth(defaults: defaults)
        playback = SpotifyPlayback(auth: spotify)
        inkChoices = defaults.dictionary(forKey: "inkOverrides") as? [String: String] ?? [:]
        customMascotPath = defaults.string(forKey: "customMascotPath")
        rimPrimaryHex = defaults.string(forKey: "rimPrimaryHex")
        rimAccentHex = defaults.string(forKey: "rimAccentHex")
        showCardOutline = defaults.object(forKey: "showCardOutline") as? Bool ?? true
    }

    var customMascotURL: URL? { customMascotPath.map { URL(fileURLWithPath: $0) } }
    var rimPrimaryColor: Color { rimPrimaryHex.flatMap { Color(hex: $0) } ?? AppStore.defaultRimPrimary }
    var rimAccentColor: Color { rimAccentHex.flatMap { Color(hex: $0) } ?? AppStore.defaultRimAccent }

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

    var isPlaying: Bool { preview == .off ? playback.isPlaying : preview == .playing }
    var canControl: Bool {
        preview == .off ? (playback.permits(.play) || playback.permits(.pause) || playback.permits(.next) || playback.permits(.previous))
            : preview == .playing || preview == .paused
    }
    var canSeek: Bool { preview == .off ? playback.permits(.seek(elapsed)) : canControl }
    var title: String { preview == .off ? playback.title : (canControl ? (sampleIndex == 0 ? "Preview track" : "Preview track 2") : "Nothing playing") }
    var artist: String {
        switch preview {
        case .off: spotify.hasSession ? playback.artist : spotify.status
        case .idle: "Preview · No active device"
        case .error: "Preview · Playback unavailable"
        default: sampleIndex == 0 ? "Preview · Squidd" : "Preview · Sabrina Carpenter"
        }
    }
    var artworkKey: String { preview == .off ? playback.artworkKey : (canControl ? "preview://artwork/\(sampleIndex)" : "idle") }
    var trackIdentity: String { preview == .off ? playback.identity : "preview:\(sampleIndex)" }
    var artwork: NSImage? { preview == .off ? playback.artwork : nil }
    var ink: InkMode { InkMode(rawValue: inkChoices[artworkKey] ?? "") ?? .automatic }
    var shownDuration: Double { preview == .off ? playback.duration : (canControl ? duration : 0) }

    func permits(_ command: SpotifyPlaybackCommand) -> Bool { preview == .off ? playback.permits(command) : canControl }

    func setInk(_ mode: InkMode) {
        if mode == .automatic { inkChoices.removeValue(forKey: artworkKey) }
        else { inkChoices[artworkKey] = mode.rawValue }
        defaults.set(inkChoices, forKey: "inkOverrides")
    }

    func forgetInk() { inkChoices = [:]; defaults.removeObject(forKey: "inkOverrides") }

    func selectPreview(_ state: PreviewState) {
        preview = state
        previewElapsed = 0
        playback.setPreviewing(state != .off)
        reconcileClock()
    }

    func togglePlayback() {
        if preview == .off { playback.send(isPlaying ? .pause : .play); return }
        guard canControl else { return }
        preview = isPlaying ? .paused : .playing
        reconcileClock()
    }

    func skip(previous: Bool = false) {
        if preview == .off { playback.send(previous ? .previous : .next); return }
        guard canControl else { return }; sampleIndex = 1 - sampleIndex; previewElapsed = 0
    }
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        if preview == .off { playback.send(.seek(seconds)); return }
        guard canControl else { return }; previewElapsed = max(0, min(seconds, duration))
    }

    func openSpotify() {
        if !NSWorkspace.shared.open(URL(string: "spotify:")!) {
            NSWorkspace.shared.open(URL(string: "https://open.spotify.com")!)
        }
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

    func stop() { tick?.cancel(); tick = nil; playback.stop(); spotify.stop() }

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
