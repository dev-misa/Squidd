import AppKit
import Foundation

@MainActor
final class PlaybackTestSession: SpotifySessionProviding {
    var hasSession = true { didSet { sessionDidChange?() } }
    var sessionDidChange: (() -> Void)?
    var refreshes = 0
    var rejected = false
    func accessToken(forceRefresh: Bool) async throws -> String {
        if forceRefresh { refreshes += 1 }
        return forceRefresh ? "refreshed-test-token" : "test-token"
    }
    func requireReconnect() { rejected = true; hasSession = false }
}

actor EmptyArtwork: SpotifyArtworkLoading {
    func image(for url: URL) async throws -> CGImage { throw URLError(.cannotDecodeContentData) }
}

@MainActor
final class HeldArtwork: SpotifyArtworkLoading {
    var pending: [URL: CheckedContinuation<CGImage, Error>] = [:]
    func image(for url: URL) async throws -> CGImage {
        try await withCheckedThrowingContinuation { pending[url] = $0 }
    }
    func complete(_ url: URL, image: CGImage) { pending.removeValue(forKey: url)?.resume(returning: image) }
}

@MainActor
final class PlaybackTestAPI: SpotifyPlaybackRequesting {
    var next: Result<SpotifyPlaybackSnapshot?, Error> = .success(nil)
    var held: CheckedContinuation<SpotifyPlaybackSnapshot?, Error>?
    var holdNext = false
    var commandFailure: Error?
    var sent: [SpotifyPlaybackCommand] = []
    var polls = 0
    var active = 0
    var maximumActive = 0
    func snapshot() async throws -> SpotifyPlaybackSnapshot? {
        polls += 1; active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if holdNext { holdNext = false; return try await withCheckedThrowingContinuation { held = $0 } }
        return try next.get()
    }
    func send(_ command: SpotifyPlaybackCommand) async throws {
        active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        sent.append(command)
        if let commandFailure { throw commandFailure }
    }
    func release(_ result: Result<SpotifyPlaybackSnapshot?, Error>) { let p = held; held = nil; p?.resume(with: result) }
}

final class PlaybackHTTPStub: URLProtocol, @unchecked Sendable {
    struct Reply { let status: Int; let data: Data; var headers: [String: String] = [:] }
    static let lock = NSLock()
    nonisolated(unsafe) static var replies: [Reply] = []
    nonisolated(unsafe) static var seen: [URLRequest] = []
    static func reset(_ values: [Reply]) { lock.lock(); defer { lock.unlock() }; replies = values; seen = [] }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.seen.append(request)
        let response = Self.replies.isEmpty ? Reply(status: 500, data: Data()) : Self.replies.removeFirst()
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct SpotifyPlaybackChecks {
    @MainActor static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Playback check timed out")
    }
    @MainActor static func sample(_ progress: Double = 10, playing: Bool = true, id: String = "one", restricted: Bool = false, artwork: String? = nil) throws -> SpotifyPlaybackSnapshot {
        let artworkJSON = artwork.map { "[{\"url\":\"\($0)\",\"width\":300}]" } ?? "[]"
        return try JSONDecoder().decode(SpotifyPlaybackSnapshot.self, from: Data("""
        {"device":{"is_active":true,"is_restricted":\(restricted),"name":"Test device"},
         "is_playing":\(playing),"progress_ms":\(progress * 1000),"currently_playing_type":"track",
         "item":{"id":"\(id)","name":"Track \(id)","type":"track","duration_ms":200000,
         "artists":[{"name":"Test artist"}],"album":{"images":\(artworkJSON)}},"actions":{"disallows":{}}}
        """.utf8))
    }
    @MainActor static func main() async throws {
        let track = try sample()
        assert(track.duration == 200 && track.elapsed == 10 && track.permits(.seek(10)))
        let restricted = try sample(restricted: true)
        assert(!restricted.permits(.pause))
        let episode = try JSONDecoder().decode(SpotifyPlaybackSnapshot.self, from: Data("""
        {"device":{"is_active":true},"is_playing":false,"progress_ms":4000,"currently_playing_type":"episode",
        "item":{"type":"episode","name":"Episode","duration_ms":60000,"show":{"name":"Podcast"},
        "images":[{"url":"https://example.com/640","width":640},{"url":"https://example.com/300","width":300}]},
        "actions":{"seeking":true,"skipping_next":true}}
        """.utf8))
        assert(episode.item?.artist == "Podcast" && episode.item?.artworkURL?.lastPathComponent == "300")
        assert(!episode.permits(.seek(1)) && !episode.permits(.next) && episode.permits(.play))
        let ad = try JSONDecoder().decode(SpotifyPlaybackSnapshot.self, from: Data("{\"item\":null,\"currently_playing_type\":\"ad\",\"is_playing\":true}".utf8))
        assert(ad.title == "Advertisement" && !ad.permits(.next))
        let local = try JSONDecoder().decode(SpotifyPlaybackSnapshot.self, from: Data("{\"item\":{\"name\":\"Local file\",\"type\":\"track\",\"is_local\":true},\"is_playing\":false}".utf8))
        assert(local.title == "Local file" && !local.permits(.seek(0)))
        assert(SpotifyPlaybackAPI.retryDelay("12") == 12 && SpotifyPlaybackAPI.retryDelay("NaN") == 30)
        try await checkHTTP()
        try await checkLifecycle()
        try await checkArtwork()
        try await checkProgressAndStaleArtwork()
        print("Live playback checks passed: metadata variants, restrictions, API commands/401/204/403/404/429, serialized polling, stale-response rejection, seek rollback, quota halt, logout, sleep, preview, artwork LRU and decoding.")
    }
    @MainActor static func checkHTTP() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PlaybackHTTPStub.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let auth = PlaybackTestSession(); let api = SpotifyPlaybackAPI(auth: auth, session: session)
        PlaybackHTTPStub.reset([.init(status: 401, data: Data()), .init(status: 204, data: Data())])
        let empty = try await api.snapshot()
        assert(empty == nil && auth.refreshes == 1)
        assert(PlaybackHTTPStub.requests.count == 2 && PlaybackHTTPStub.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-test-token")
        PlaybackHTTPStub.reset(Array(repeating: .init(status: 204, data: Data()), count: 5))
        for command: SpotifyPlaybackCommand in [.previous, .next, .play, .pause, .seek(12.345)] { try await api.send(command) }
        let requests = PlaybackHTTPStub.requests
        assert(requests.map(\.httpMethod) == ["POST", "POST", "PUT", "PUT", "PUT"])
        assert(requests.map { $0.url!.lastPathComponent } == ["previous", "next", "play", "pause", "seek"])
        assert(requests.last!.url!.query == "position_ms=12345")
        for (status, expected) in [(403, "denied"), (404, "Open Spotify")] {
            PlaybackHTTPStub.reset([.init(status: status, data: Data())])
            do { _ = try await api.snapshot(); fatalError("HTTP failure accepted") }
            catch { assert(error.localizedDescription.contains(expected)) }
        }
        PlaybackHTTPStub.reset([.init(status: 429, data: Data("{\"error\":{\"reason\":\"QUOTA_EXCEEDED\"}}".utf8))])
        do { _ = try await api.snapshot(); fatalError("Quota accepted") }
        catch { guard case SpotifyPlaybackError.quotaExceeded = error else { fatalError("Wrong quota error") } }
        PlaybackHTTPStub.reset([.init(status: 429, data: Data(), headers: ["Retry-After": "45"])])
        do { _ = try await api.snapshot(); fatalError("Rate limit accepted") }
        catch { guard case SpotifyPlaybackError.rateLimited(45) = error else { fatalError("Wrong rate limit") } }
        PlaybackHTTPStub.reset([.init(status: 401, data: Data()), .init(status: 401, data: Data())])
        do { _ = try await api.snapshot(); fatalError("Persistent 401 accepted") } catch {}
        assert(auth.rejected && PlaybackHTTPStub.requests.count == 2)
    }
    @MainActor static func checkLifecycle() async throws {
        let auth = PlaybackTestSession(), api = PlaybackTestAPI()
        api.next = .success(try sample())
        let playback = SpotifyPlayback(auth: auth, api: api, images: EmptyArtwork(), pollInterval: 0.05, reconciliationDelay: 0.01)
        defer { playback.stop() }
        try await waitUntil { playback.state == .playing }
        assert(playback.title == "Track one" && playback.permits(.pause))
        api.holdNext = true
        try await waitUntil { api.held != nil }
        playback.send(.seek(80))
        playback.send(.next) // Ignored while a command is pending.
        assert(playback.elapsed >= 80 && playback.busy && api.sent.isEmpty)
        api.next = .success(try sample(80))
        api.release(.success(try sample(2))) // Predates the seek and must be discarded.
        try await waitUntil { !playback.busy }
        assert(api.sent == [.seek(80)] && playback.elapsed >= 80 && api.maximumActive == 1)
        api.commandFailure = URLError(.notConnectedToInternet)
        let prior = playback.elapsed
        playback.send(.seek(150))
        try await waitUntil { !playback.busy }
        assert(playback.elapsed < 150 && abs(playback.elapsed - prior) < 1 && playback.state == .commandError)
        api.commandFailure = nil
        playback.setSuspended(true)
        let frozen = playback.elapsed, polls = api.polls
        try await Task.sleep(for: .milliseconds(120))
        assert(playback.elapsed == frozen && api.polls == polls && !playback.isPlaying)
        playback.setSuspended(false)
        // Backoff remains respected through sleep/wake.
        try await waitUntil { playback.state == .playing }
        playback.setPreviewing(true)
        let previewPolls = api.polls
        try await Task.sleep(for: .milliseconds(120))
        assert(api.polls == previewPolls && !playback.permits(.next))
        playback.setPreviewing(false)
        try await waitUntil { playback.state == .playing }
        api.next = .failure(SpotifyPlaybackError.quotaExceeded)
        try await waitUntil { playback.state == .quotaExceeded }
        let quotaPolls = api.polls
        try await Task.sleep(for: .milliseconds(180))
        assert(api.polls == quotaPolls && !playback.permits(.next))
        api.next = .success(nil); playback.retry()
        try await waitUntil { playback.state == .idle }
        assert(playback.title == "Nothing playing" && playback.duration == 0)
        api.next = .success(try sample())
        try await waitUntil { playback.state == .playing }
        api.holdNext = true
        try await waitUntil { api.held != nil }
        auth.hasSession = false
        api.release(.success(try sample(30, id: "late")))
        try await Task.sleep(for: .milliseconds(60))
        assert(playback.state == .disconnected && playback.snapshot == nil && playback.artwork == nil)
    }
    @MainActor static func checkArtwork() async throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 600, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PlaybackHTTPStub.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let cache = SpotifyArtworkCache(capacity: 2, session: session)
        PlaybackHTTPStub.reset(Array(repeating: .init(status: 200, data: png), count: 4))
        let a = URL(string: "https://example.com/a")!, b = URL(string: "https://example.com/b")!, c = URL(string: "https://example.com/c")!
        let image = try await cache.image(for: a)
        assert(image.width == 300 && image.height == 300)
        _ = try await cache.image(for: b); _ = try await cache.image(for: a)
        assert(PlaybackHTTPStub.requests.count == 2)
        _ = try await cache.image(for: c); _ = try await cache.image(for: b)
        let count = await cache.cachedCount
        assert(count == 2 && PlaybackHTTPStub.requests.count == 4)
    }
    @MainActor static func checkProgressAndStaleArtwork() async throws {
        let auth = PlaybackTestSession(), api = PlaybackTestAPI()
        api.next = .success(try sample(199.8))
        let playback = SpotifyPlayback(auth: auth, api: api, images: EmptyArtwork(), pollInterval: 10)
        try await waitUntil { playback.state == .playing }
        try await Task.sleep(for: .milliseconds(350))
        assert(playback.elapsed == 200) // Local time clamps; never sends an automatic skip.
        assert(api.sent.isEmpty)
        api.next = .success(try sample(50, playing: false)); playback.retry()
        try await waitUntil { playback.state == .paused }
        let paused = playback.elapsed
        try await Task.sleep(for: .milliseconds(350))
        assert(playback.elapsed == paused)
        api.next = .failure(SpotifyPlaybackError.rateLimited(1)); playback.retry()
        try await waitUntil { playback.state == .rateLimited }
        let before = api.polls
        playback.retry(); playback.send(.next)
        try await Task.sleep(for: .milliseconds(250))
        assert(api.polls == before && api.sent.isEmpty)
        playback.stop()

        let artAuth = PlaybackTestSession(), artAPI = PlaybackTestAPI(), images = HeldArtwork()
        let firstURL = URL(string: "https://example.com/first")!, secondURL = URL(string: "https://example.com/second")!
        artAPI.next = .success(try sample(10, artwork: firstURL.absoluteString))
        let artPlayback = SpotifyPlayback(auth: artAuth, api: artAPI, images: images, pollInterval: 0.05)
        defer { artPlayback.stop() }
        try await waitUntil { images.pending[firstURL] != nil }
        artAPI.next = .success(try sample(20, id: "two", artwork: secondURL.absoluteString))
        try await waitUntil { images.pending[secondURL] != nil }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 10, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        images.complete(firstURL, image: bitmap.cgImage!) // Deliberately ignores cancellation.
        try await Task.sleep(for: .milliseconds(20))
        assert(artPlayback.artwork == nil && artPlayback.artworkKey == secondURL.absoluteString)
        images.complete(secondURL, image: bitmap.cgImage!)
        try await waitUntil { artPlayback.artwork != nil }
        assert(artPlayback.title == "Track two")
        artAuth.hasSession = false
        assert(artPlayback.artwork == nil && artPlayback.snapshot == nil)
    }

}
