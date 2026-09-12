import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScriptingBridge

// MARK: - ScriptingBridge surface

// The subset of /System/Applications/Music.app/Contents/Resources/com.apple.Music.sdef that the widget needs,
// declared by hand rather than generated, so the app carries four small protocols instead of a 4,000-line header.
// Every member is `@objc optional`: ScriptingBridge answers these selectors dynamically, and a missing one
// returns nil instead of trapping, which is what we want if a future Music release drops a property.

// Anything that would need bridging is declared `AnyObject`, never `String`, `Data` or `NSImage`. ScriptingBridge
// answers a property with a generic `SBObject` whenever it cannot type the reply — `raw data` is declared
// `type="any"` in the sdef, and a refused or failed event returns a placeholder for anything else. A declared
// bridged type makes Swift bridge that object *unconditionally*, which sends NSData's or NSString's selectors to an
// SBObject and traps. Read them through the checked accessors below instead, where a wrong type just yields nil.
@objc nonisolated private protocol MusicArtworkScripting {
    @objc optional var rawData: AnyObject { get }
    @objc optional var data: AnyObject { get }
}

@objc nonisolated private protocol MusicTrackScripting {
    @objc optional var name: AnyObject { get }
    @objc optional var artist: AnyObject { get }
    @objc optional var albumArtist: AnyObject { get }
    @objc optional var album: AnyObject { get }
    @objc optional var duration: Double { get }
    @objc optional var persistentID: AnyObject { get }
    @objc optional func artworks() -> AnyObject
}

/// A conditional cast: it checks the object's real class first, so an `SBObject` standing in for a value that
/// could not be read returns nil rather than trapping.
nonisolated private func scriptedText(_ value: AnyObject?) -> String? {
    if let text = value as? String { return text.isEmpty ? nil : text }
    return nil
}

@objc nonisolated private protocol MusicApplicationScripting {
    @objc optional var currentTrack: MusicTrackScripting { get }
    @objc optional var playerPosition: Double { get }
    @objc optional func setPlayerPosition(_ value: Double)
    @objc optional var playerState: UInt32 { get }
    @objc optional func playpause()
    @objc optional func play()
    @objc optional func pause()
    @objc optional func nextTrack()
    @objc optional func previousTrack()
}

nonisolated extension SBObject: MusicTrackScripting, MusicArtworkScripting {}
nonisolated extension SBApplication: MusicApplicationScripting {}

// MARK: - Values

/// `player state` from the scripting dictionary. The raw values are the four-character codes in the `ePlS`
/// enumeration; anything unrecognized becomes `.unknown` so a surprise value reads as "no opinion" rather than
/// silently meaning "stopped".
nonisolated enum AppleMusicPlayerState: Equatable, Sendable {
    case stopped, playing, paused, fastForwarding, rewinding, unknown

    static func code(_ text: String) -> UInt32 {
        text.unicodeScalars.reduce(UInt32(0)) { ($0 << 8) | (UInt32($1.value) & 0xFF) }
    }
    init(raw: UInt32) {
        switch raw {
        case Self.code("kPSP"): self = .playing
        case Self.code("kPSp"): self = .paused
        case Self.code("kPSS"): self = .stopped
        case Self.code("kPSF"): self = .fastForwarding
        case Self.code("kPSR"): self = .rewinding
        default: self = .unknown
        }
    }
    /// The `Player State` string carried by the `com.apple.Music.playerInfo` notification, which arrives without
    /// needing Automation permission and stands in when Apple events are unavailable.
    init(notification text: String) {
        switch text.lowercased() {
        case "playing": self = .playing
        case "paused": self = .paused
        case "stopped": self = .stopped
        default: self = .unknown
        }
    }
    var isPlaying: Bool { self == .playing || self == .fastForwarding || self == .rewinding }
}

nonisolated struct AppleMusicTrack: Equatable, Sendable {
    var identity: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
}

nonisolated struct AppleMusicStatus: Sendable {
    var isRunning = false
    var state: AppleMusicPlayerState = .unknown
    /// nil when `player position` could not be read, which is how a permission refusal shows up.
    var position: Double?
    var track: AppleMusicTrack?
    /// True when an Apple event came back, proving Automation access is working right now.
    var responded = false
}

nonisolated enum AppleMusicPermission: Equatable, Sendable {
    case granted
    /// macOS will show the Automation prompt the first time an event is sent.
    case notDetermined
    /// The user said no; only System Settings can undo it.
    case denied
    case musicNotRunning
    case unknown(OSStatus)
}

nonisolated enum AppleMusicError: Error, LocalizedError {
    case notRunning, notPermitted, failed

    var errorDescription: String? {
        switch self {
        case .notRunning: "Open the Music app to control playback."
        case .notPermitted: "Squidd needs permission to control Music. Grant it in Settings, or in System Settings › Privacy & Security › Automation."
        case .failed: "The Music app did not respond to that command."
        }
    }
}

/// Explicitly `nonisolated`: the target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would
/// otherwise pin these calls to the main actor — the one place this work must never run.
nonisolated protocol AppleMusicControlling: Sendable {
    func status() async -> AppleMusicStatus
    func artwork(for identity: String) async -> CGImage?
    func send(_ command: PlaybackCommand) async throws
    /// `prompt: false` reports the current answer without showing the Automation dialog, which is what the
    /// Settings status row wants; `true` is only used behind an explicit button.
    func permission(prompt: Bool) async -> AppleMusicPermission
}

// MARK: - Bridge

/// Talks to the Music app over Apple events.
///
/// ScriptingBridge calls are synchronous and can block for as long as the target takes to answer, so every one of
/// them runs on a private serial queue and is awaited — never on the main actor, where a busy Music app would
/// freeze the widget. The `SBApplication` is created once and touched only from that queue.
nonisolated final class AppleMusicBridge: AppleMusicControlling, @unchecked Sendable {
    private let bundleIdentifier: String
    private let queue: DispatchQueue
    /// Two seconds, in the sixtieths of a second `SBApplication.timeout` expects. Past that we would rather show
    /// stale values than hold a request open.
    private let replyTimeout = 120
    private var app: SBApplication?
    private var artworkCache: (identity: String, image: CGImage?)?

    init(bundleIdentifier: String = MusicSourceKind.appleMusic.bundleIdentifier) {
        self.bundleIdentifier = bundleIdentifier
        queue = DispatchQueue(label: "com.squidd.apple-music", qos: .userInitiated)
    }

    /// True without sending an Apple event, so polling never launches the Music app or trips a permission prompt.
    private var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    private func connection() -> MusicApplicationScripting? {
        dispatchPrecondition(condition: .onQueue(queue))
        if app == nil {
            app = SBApplication(bundleIdentifier: bundleIdentifier)
            app?.timeout = replyTimeout
        }
        return app
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable (AppleMusicBridge, MusicApplicationScripting) -> T,
                                  fallback: T) async -> T {
        guard isRunning else { return fallback }
        return await withCheckedContinuation { continuation in
            queue.async {
                guard let music = self.connection() else { return continuation.resume(returning: fallback) }
                continuation.resume(returning: body(self, music))
            }
        }
    }

    func status() async -> AppleMusicStatus {
        guard isRunning else { return AppleMusicStatus() }
        return await run({ _, music in
            var status = AppleMusicStatus(isRunning: true)
            // A nil answer here is how a denied or undecided Automation permission presents itself: the event is
            // refused before Music ever sees it. `responded` records that we did get through.
            guard let raw = music.playerState else { return status }
            status.responded = true
            status.state = AppleMusicPlayerState(raw: raw)
            status.position = music.playerPosition
            if let track = music.currentTrack, let title = scriptedText(track.name) {
                let duration = track.duration ?? 0
                let artist = scriptedText(track.artist) ?? scriptedText(track.albumArtist)
                // `persistent ID` is stable for library tracks. Streamed catalog tracks can report a placeholder,
                // so the title and duration back it up and a track change is still noticed.
                let persistent = scriptedText(track.persistentID) ?? ""
                let identity = persistent.isEmpty || persistent.allSatisfy { $0 == "0" }
                    ? "\(title)|\(artist ?? "")|\(Int(duration))" : persistent
                status.track = AppleMusicTrack(
                    identity: identity, title: title, artist: artist ?? "Unknown artist",
                    album: scriptedText(track.album) ?? "", duration: max(0, duration))
            }
            return status
        }, fallback: AppleMusicStatus())
    }

    func artwork(for identity: String) async -> CGImage? {
        await run({ bridge, music in
            if let cached = bridge.artworkCache, cached.identity == identity { return cached.image }
            var image: CGImage?
            if let artworks = music.currentTrack?.artworks?() as? SBElementArray, artworks.count > 0,
               let first = artworks.object(at: 0) as? MusicArtworkScripting {
                // Music answers `data` with a raw `tdta` Apple event descriptor wrapping the image bytes — not the
                // `NSImage` the sdef's `picture` type suggests — so the payload is decoded directly. Read once:
                // each access is another Apple event, and this is the expensive one.
                let value = first.data
                if let descriptor = value as? NSAppleEventDescriptor { image = Self.decode(descriptor.data) }
                else if let picture = value as? NSImage { image = Self.decode(picture) }
                // `raw data` is declared `any`, so ScriptingBridge usually cannot type it; tried last, if at all.
                if image == nil, let bytes = first.rawData as? Data, !bytes.isEmpty { image = Self.decode(bytes) }
            }
            bridge.artworkCache = (identity, image)
            return image
        }, fallback: nil)
    }

    func send(_ command: PlaybackCommand) async throws {
        guard isRunning else { throw AppleMusicError.notRunning }
        let delivered = await run({ _, music in
            switch command {
            // `playpause` would resume a stopped player too, but the widget only offers these while something is
            // loaded, and asking for the state we want avoids a race with a notification that just changed it.
            case .play: music.play?()
            case .pause: music.pause?()
            case .next: music.nextTrack?()
            case .previous: music.previousTrack?()
            case .seek(let seconds): music.setPlayerPosition?(max(0, seconds))
            }
            // Reading anything back proves the command was not silently refused for lack of permission.
            return music.playerState != nil
        }, fallback: false)
        guard delivered else { throw AppleMusicError.notPermitted }
    }

    func permission(prompt: Bool) async -> AppleMusicPermission {
        guard isRunning else { return .musicNotRunning }
        let identifier = bundleIdentifier
        return await withCheckedContinuation { continuation in
            queue.async {
                // Held for the duration of the call: `aeDesc` points into the descriptor's own storage.
                let target = NSAppleEventDescriptor(bundleIdentifier: identifier)
                guard let descriptor = target.aeDesc else {
                    return continuation.resume(returning: .unknown(OSStatus(-1)))
                }
                let status = AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, prompt)
                withExtendedLifetime(target) {}
                continuation.resume(returning: AppleMusicPermission(status: status))
            }
        }
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 300
        ] as CFDictionary)
    }

    private static func decode(_ image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

nonisolated extension AppleMusicPermission {
    /// Spelled out rather than taken from the SDK: these AppleEvents constants are not all surfaced to Swift.
    init(status: OSStatus) {
        switch status {
        case noErr: self = .granted
        case -1743: self = .denied              // errAEEventNotPermitted
        case -1744: self = .notDetermined       // errAEEventWouldRequireUserConsent
        case -600, -609: self = .musicNotRunning // procNotFound, connectionInvalid
        default: self = .unknown(status)
        }
    }
}
