import AppKit
import CoreGraphics
import Foundation

/// Stands in for the Music app. Sendable because the real bridge is: it is driven from the checks' main actor but
/// answers the backend's `await`s, so its state is guarded rather than actor-isolated.
nonisolated final class FakeMusic: AppleMusicControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _status = AppleMusicStatus()
    private var _permission: AppleMusicPermission = .granted
    private var _sent: [PlaybackCommand] = []
    private var _artworkRequests: [String] = []
    private var _failure: AppleMusicError?
    private var _artwork: CGImage?

    private func guarded<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var status: AppleMusicStatus {
        get { guarded { _status } }
        set { guarded { _status = newValue } }
    }
    var permissionAnswer: AppleMusicPermission {
        get { guarded { _permission } }
        set { guarded { _permission = newValue } }
    }
    var failure: AppleMusicError? {
        get { guarded { _failure } }
        set { guarded { _failure = newValue } }
    }
    var artworkImage: CGImage? {
        get { guarded { _artwork } }
        set { guarded { _artwork = newValue } }
    }
    var sent: [PlaybackCommand] { guarded { _sent } }
    var artworkRequests: [String] { guarded { _artworkRequests } }
    func clearSent() { guarded { _sent = [] } }

    func status() async -> AppleMusicStatus { status }
    func artwork(for identity: String) async -> CGImage? {
        guarded { _artworkRequests.append(identity); return _artwork }
    }
    func send(_ command: PlaybackCommand) async throws {
        if let failure = guarded({ _failure }) { throw failure }
        guarded { _sent.append(command) }
    }
    func permission(prompt: Bool) async -> AppleMusicPermission { permissionAnswer }
}

nonisolated func solidImage() -> CGImage {
    let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    return context.makeImage()!
}

nonisolated func playingStatus(title: String = "Nautilus", artist: String = "Anna Meredith",
                               identity: String = "ABC123", duration: Double = 200,
                               position: Double = 10, playing: Bool = true) -> AppleMusicStatus {
    AppleMusicStatus(isRunning: true, state: playing ? .playing : .paused, position: position,
                     track: AppleMusicTrack(identity: identity, title: title, artist: artist,
                                            album: "Varmints", duration: duration),
                     responded: true)
}
