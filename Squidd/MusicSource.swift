import AppKit
import Foundation

/// The transport actions the card and launcher can ask for. Backends map these onto whatever their service
/// understands: Spotify turns them into Web API requests, Apple Music into Apple events to the Music app.
nonisolated enum PlaybackCommand: Equatable, Sendable {
    case play, pause, previous, next, seek(Double)
}

nonisolated enum MusicSourceKind: String, CaseIterable, Identifiable, Sendable {
    case spotify = "Spotify"
    case appleMusic = "Apple Music"

    var id: String { rawValue }
    var bundleIdentifier: String {
        switch self {
        case .spotify: "com.spotify.client"
        case .appleMusic: "com.apple.Music"
        }
    }
}

/// What a playback backend has to offer for `AppStore` to drive the widget from it. Both `SpotifyPlayback` and
/// `AppleMusicPlayback` are `@Observable`, and reading these through the existential still registers with SwiftUI's
/// observation tracking, so views refresh whichever backend is showing.
@MainActor
protocol MusicSource: AnyObject {
    var kind: MusicSourceKind { get }

    var isPlaying: Bool { get }
    var elapsed: Double { get }
    var duration: Double { get }
    var title: String { get }
    var artist: String { get }
    var artwork: NSImage? { get }
    var artworkKey: String { get }
    var identity: String { get }
    /// One line describing the connection itself, shown when there is nothing playing.
    var status: String { get }
    /// A transient problem worth showing in place of the artist line; nil when all is well.
    var message: String? { get }

    /// Configured enough to be worth showing: a Spotify session exists, or the Music app is reachable.
    var isAvailable: Bool { get }
    /// Something is loaded right now, whether it is playing or paused.
    var hasTrack: Bool { get }
    /// When this backend last played something, used to break ties when both services have a track loaded.
    var lastActiveAt: Date? { get }

    /// Called after anything that could change which backend should be showing.
    var didChange: (() -> Void)? { get set }

    func permits(_ command: PlaybackCommand) -> Bool
    func send(_ command: PlaybackCommand)
    func setSuspended(_ value: Bool)
    func setPreviewing(_ value: Bool)
    /// Watch closely for a while, for moments when a change is likely: the app coming forward, the card opening,
    /// or the Mac waking.
    func boost(for seconds: Double)
    func stop()
}
