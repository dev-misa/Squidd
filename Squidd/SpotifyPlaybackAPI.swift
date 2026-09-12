import Foundation


struct SpotifyPlaybackSnapshot: Decodable, Sendable {
    struct Device: Decodable, Sendable {
        let is_active: Bool?
        let is_restricted: Bool?
        let name: String?
    }
    struct Artwork: Decodable, Sendable {
        let url: String
        let width: Int?
    }
    struct Artist: Decodable, Sendable { let name: String? }
    struct Album: Decodable, Sendable { let images: [Artwork]? }
    struct Show: Decodable, Sendable { let name: String?; let publisher: String? }
    struct Restriction: Decodable, Sendable { let reason: String? }
    struct Item: Decodable, Sendable {
        let id: String?
        let uri: String?
        let name: String?
        let type: String?
        let duration_ms: Double?
        let is_local: Bool?
        let is_playable: Bool?
        let restrictions: Restriction?
        let artists: [Artist]?
        let album: Album?
        let images: [Artwork]?
        let show: Show?
        var identity: String { uri ?? id ?? "\(type ?? "unknown"):\(name ?? ""):\(duration_ms ?? 0)" }
        var artist: String {
            let names = (artists ?? []).compactMap(\.name).filter { !$0.isEmpty }.joined(separator: ", ")
            return names.isEmpty ? (show?.name ?? show?.publisher ?? "Unknown artist") : names
        }
        var artworkURL: URL? {
            (album?.images ?? images ?? []).sorted { abs(($0.width ?? 300) - 300) < abs(($1.width ?? 300) - 300) }
                .compactMap { URL(string: $0.url) }.first { $0.scheme == "https" && $0.host != nil }
        }
    }
    struct Actions: Decodable, Sendable {
        let disallows: [String: Bool]
        private enum CodingKeys: String, CodingKey { case disallows }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.disallows) {
                disallows = try container.decodeIfPresent([String: Bool].self, forKey: .disallows) ?? [:]
            } else { disallows = try decoder.singleValueContainer().decode([String: Bool].self) }
        }
    }
    let device: Device?
    let progress_ms: Double?
    let is_playing: Bool?
    let item: Item?
    let currently_playing_type: String?
    let actions: Actions?

    var duration: Double { min(Double(Int32.max) / 1000, max(0, (item?.duration_ms ?? 0) / 1000)) }
    var elapsed: Double { min(duration, max(0, (progress_ms ?? 0) / 1000)) }
    var identity: String { item?.identity ?? currently_playing_type ?? "idle" }
    var title: String {
        if currently_playing_type == "ad" { return "Advertisement" }
        return item?.name ?? (is_playing == true ? "Playback unavailable" : "Nothing playing")
    }
    func permits(_ command: PlaybackCommand) -> Bool {
        guard device?.is_active == true, device?.is_restricted != true,
              item != nil, item?.is_playable != false, item?.restrictions == nil,
              ["track", "episode"].contains(item?.type ?? currently_playing_type ?? ""),
              currently_playing_type != "ad", is_playing != nil else { return false }
        if case .seek = command, duration <= 0 || progress_ms == nil { return false }
        return actions?.disallows[command.restriction] != true
    }
}

/// How the shared transport actions map onto Spotify's player endpoints and its `disallows` vocabulary.
extension PlaybackCommand {
    var restriction: String {
        switch self {
        case .play: "resuming"
        case .pause: "pausing"
        case .previous: "skipping_prev"
        case .next: "skipping_next"
        case .seek: "seeking"
        }
    }
    var path: String {
        switch self {
        case .play: "play"
        case .pause: "pause"
        case .previous: "previous"
        case .next: "next"
        case .seek: "seek"
        }
    }
    var method: String { self == .previous || self == .next ? "POST" : "PUT" }
}

enum SpotifyPlaybackError: Error, LocalizedError {
    case unauthorized, forbidden, noDevice, quotaExceeded, rateLimited(Double), unavailable, malformed
    var errorDescription: String? {
        switch self {
        case .unauthorized: "Reconnect to Spotify."
        case .forbidden: "Spotify denied playback access. Check the app’s allowed users, playback permissions and Premium eligibility."
        case .noDevice: "Open Spotify and start playback on a device."
        case .quotaExceeded: "Spotify’s development quota is exhausted. Automatic requests are paused."
        case .rateLimited: "Spotify is limiting requests. Waiting before retrying."
        case .unavailable: "Spotify is temporarily unavailable. Retrying shortly."
        case .malformed: "Spotify returned unreadable playback information. Retrying shortly."
        }
    }
}

@MainActor
protocol SpotifyPlaybackRequesting {
    func snapshot() async throws -> SpotifyPlaybackSnapshot?
    func send(_ command: PlaybackCommand) async throws
}

@MainActor
final class SpotifyPlaybackAPI: SpotifyPlaybackRequesting {
    private let auth: any SpotifySessionProviding
    private let session: URLSession
    init(auth: any SpotifySessionProviding, session: URLSession? = nil) {
        self.auth = auth
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }
    func snapshot() async throws -> SpotifyPlaybackSnapshot? {
        // Includes device restrictions in the same request as metadata/progress.
        let data = try await request(path: "", method: "GET", query: [URLQueryItem(name: "additional_types", value: "track,episode")])
        guard let data else { return nil }
        do { return try JSONDecoder().decode(SpotifyPlaybackSnapshot.self, from: data) }
        catch { throw SpotifyPlaybackError.malformed }
    }
    func send(_ command: PlaybackCommand) async throws {
        var query: [URLQueryItem] = []
        if case .seek(let seconds) = command {
            guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) / 1000 else { throw SpotifyPlaybackError.malformed }
            query = [URLQueryItem(name: "position_ms", value: String(Int(seconds * 1000)))]
        }
        _ = try await request(path: "/" + command.path, method: command.method, query: query)
    }
    private func request(path: String, method: String, query: [URLQueryItem]) async throws -> Data? {
        var url = URLComponents(string: "https://api.spotify.com/v1/me/player" + path)!
        if !query.isEmpty { url.queryItems = query }
        for attempt in 0...1 {
            let token = try await auth.accessToken(forceRefresh: attempt == 1)
            try Task.checkCancellation()
            var request = URLRequest(url: url.url!)
            request.httpMethod = method
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw SpotifyPlaybackError.malformed }
            if http.statusCode == 401 {
                if attempt == 0 { continue }
                auth.requireReconnect()
                throw SpotifyPlaybackError.unauthorized
            }
            if http.statusCode == 204 { return nil }
            if http.statusCode == 403 { throw SpotifyPlaybackError.forbidden }
            if http.statusCode == 404 { throw SpotifyPlaybackError.noDevice }
            if http.statusCode == 429 {
                struct Failure: Decodable { struct Detail: Decodable { let reason: String? }; let error: Detail }
                let reason = (try? JSONDecoder().decode(Failure.self, from: data))?.error.reason
                if reason == "QUOTA_EXCEEDED" { throw SpotifyPlaybackError.quotaExceeded }
                throw SpotifyPlaybackError.rateLimited(Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After")))
            }
            guard (200..<300).contains(http.statusCode) else { throw SpotifyPlaybackError.unavailable }
            guard data.count <= 2 * 1024 * 1024 else { throw SpotifyPlaybackError.malformed }
            return data
        }
        throw SpotifyPlaybackError.unauthorized
    }
    static func retryDelay(_ value: String?, now: Date = Date()) -> Double {
        if let value, let seconds = Double(value), seconds.isFinite { return max(1, seconds) }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        if let value, let date = format.date(from: value) { return max(1, date.timeIntervalSince(now)) }
        return 30
    }
}
