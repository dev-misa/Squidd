import AppKit
import CryptoKit
import Foundation
import Observation
import Security

@MainActor
protocol SpotifySessionProviding: AnyObject {
    var hasSession: Bool { get }
    var sessionDidChange: (() -> Void)? { get set }
    func accessToken(forceRefresh: Bool) async throws -> String
    func requireReconnect()
}


enum SpotifyAuthError: Error, LocalizedError {
    case message(String)
    case reconnect
    case retryAfter(TimeInterval)
    var errorDescription: String? {
        switch self {
        case .message(let message): message
        case .reconnect: "Spotify authorization expired or was revoked. Connect again."
        case .retryAfter: "Spotify is limiting requests. Connection will retry after the requested delay."
        }
    }
}

enum SpotifyConnectionState: Equatable {
    case disconnected, connecting, connected, offline, reconnectRequired
}

@MainActor @Observable
final class SpotifyAuth: SpotifySessionProviding {
    static let redirectURI = "http://127.0.0.1:8888/callback"
    static let scopes = "user-read-currently-playing user-read-playback-state user-modify-playback-state"
    private(set) var clientID: String
    private(set) var state: SpotifyConnectionState = .disconnected
    private(set) var message: String?
    @ObservationIgnored var sessionDidChange: (() -> Void)?
    private(set) var hasSession = false {
        didSet { if oldValue != hasSession { sessionDidChange?() } }
    }
    private(set) var suspended = false
    private let defaults: UserDefaults
    private let storage: any SpotifyTokenStorage
    private let session: URLSession
    private let makeListener: @MainActor () -> any SpotifyCallbackListening
    private let openBrowser: @MainActor (URL) -> Bool
    private var tokens: SpotifyTokens?
    private var generation = UUID()
    private var loginTask: Task<Void, Never>?
    private var refreshTask: Task<SpotifyTokens, Error>?
    private var maintenance: Task<Void, Never>?
    private var callback: (any SpotifyCallbackListening)?
    private var retryNotBefore: Date?

    init(defaults: UserDefaults = .standard, storage: (any SpotifyTokenStorage)? = nil,
         session: URLSession? = nil,
         makeListener: @escaping @MainActor () -> any SpotifyCallbackListening = { SpotifyLoopback() },
         openBrowser: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.defaults = defaults
        self.storage = storage ?? SpotifyKeychain()
        self.makeListener = makeListener
        self.openBrowser = openBrowser
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 45
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            self.session = URLSession(configuration: configuration)
        }
        clientID = defaults.string(forKey: "spotifyClientID")
            ?? (Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String ?? "")
    }

    static func validClientID(_ value: String) -> Bool {
        value.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    var status: String {
        switch state {
        case .disconnected: "Not connected"
        case .connecting: "Waiting for Spotify login…"
        case .connected: "Connected to Spotify"
        case .offline: "Connection unavailable · Will retry"
        case .reconnectRequired: "Reconnect to Spotify"
        }
    }

    @discardableResult func saveClientID(_ input: String) -> Bool {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validClientID(value) else {
            message = "Enter the 32-character Client ID from your Spotify developer app. No client secret is needed."
            return false
        }
        if value != clientID {
            disconnect()
            clientID = value
            defaults.set(value, forKey: "spotifyClientID")
        }
        return true
    }

    func restore() {
        guard !hasSession, state != .connecting,
              defaults.bool(forKey: "spotifySessionEnabled") else { return }
        do {
            guard let saved = try storage.load(), saved.clientID == clientID,
                  !saved.refreshToken.isEmpty, !saved.accessToken.isEmpty else {
                defaults.set(false, forKey: "spotifySessionEnabled")
                state = .reconnectRequired
                return
            }
            tokens = saved; hasSession = true
            state = saved.expiresAt > Date() ? .connected : .offline
            scheduleMaintenance()
        } catch {
            state = .reconnectRequired
            message = safeMessage(error)
        }
    }

    func connect() {
        guard Self.validClientID(clientID) else {
            message = "Save your Spotify Client ID in Settings first."
            return
        }
        guard state != .connecting else { return }
        invalidateWork()
        tokens = nil; hasSession = false
        defaults.set(false, forKey: "spotifySessionEnabled")
        state = .connecting; message = nil
        let current = generation, id = clientID
        loginTask = Task { [weak self] in
            guard let self else { return }
            do {
                let verifier = try Self.randomURLSafe(bytes: 64)
                let nonce = try Self.randomURLSafe(bytes: 32)
                let url = Self.authorizationURL(clientID: id, state: nonce, verifier: verifier)
                let listener = self.makeListener()
                self.callback = listener
                let code = try await listener.authorizationCode(state: nonce) {
                    guard self.generation == current, !Task.isCancelled else { throw CancellationError() }
                    guard self.openBrowser(url) else {
                        throw SpotifyAuthError.message("Could not open your browser. Check your default browser and try Connect again.")
                    }
                }
                try self.check(current)
                self.callback = nil
                self.message = "Finishing Spotify connection…"
                let result = try await self.requestTokens(fields: ["grant_type": "authorization_code", "code": code,
                    "redirect_uri": Self.redirectURI, "client_id": id, "code_verifier": verifier], clientID: id, previousRefresh: nil)
                try self.check(current)
                try self.storage.save(result)
                self.tokens = result; self.hasSession = true
                self.defaults.set(true, forKey: "spotifySessionEnabled")
                self.state = .connected; self.message = nil
                self.loginTask = nil
                self.scheduleMaintenance()
            } catch {
                guard self.generation == current else { return }
                self.callback?.cancel(); self.callback = nil; self.loginTask = nil
                self.state = .disconnected
                self.message = error is CancellationError ? nil : self.safeMessage(error)
            }
        }
    }

    func cancelLogin() {
        guard state == .connecting else { return }
        invalidateWork()
        state = .disconnected; message = "Login cancelled."
    }

    func disconnect() {
        invalidateWork()
        // Persist this before deleting: a Keychain failure must not restore logout on relaunch.
        defaults.set(false, forKey: "spotifySessionEnabled")
        tokens = nil; hasSession = false; state = .disconnected; message = nil
        do { try storage.delete() }
        catch { message = safeMessage(error) + " The local session is disabled; retry Disconnect to remove the saved credentials." }
    }

    /// Used by playback in phase 4, including its one allowed retry after HTTP 401.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let saved = tokens, hasSession else { throw SpotifyAuthError.reconnect }
        if let pending = refreshTask {
            let current = generation
            let result = try await pending.value
            try check(current)
            return result.accessToken
        }
        if !forceRefresh, saved.expiresAt.timeIntervalSinceNow > 60 { return saved.accessToken }
        if let retryNotBefore, retryNotBefore > Date() { throw SpotifyAuthError.retryAfter(retryNotBefore.timeIntervalSinceNow) }
        let current = generation
        let task = Task<SpotifyTokens, Error> {
            let result = try await self.requestTokens(fields: ["grant_type": "refresh_token",
                "refresh_token": saved.refreshToken, "client_id": saved.clientID], clientID: saved.clientID,
                previousRefresh: saved.refreshToken)
            try self.check(current)
            try self.storage.save(result)
            self.tokens = result
            self.state = .connected; self.message = nil; self.retryNotBefore = nil
            return result
        }
        refreshTask = task
        do {
            let result = try await task.value
            try check(current)
            refreshTask = nil
            return result.accessToken
        } catch {
            guard generation == current else { throw CancellationError() }
            refreshTask = nil
            if case SpotifyAuthError.reconnect = error {
                tokens = nil; hasSession = false
                defaults.set(false, forKey: "spotifySessionEnabled")
                state = .reconnectRequired
                do { try storage.delete() } catch { message = safeMessage(error) }
            } else if !(error is CancellationError) { state = .offline }
            if case SpotifyAuthError.retryAfter(let seconds) = error {
                retryNotBefore = Date().addingTimeInterval(seconds)
            }
            if !(error is CancellationError) { message = safeMessage(error) }
            throw error
        }
    }

    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        maintenance?.cancel(); maintenance = nil
        if value {
            if state == .connecting { cancelLogin() }
            // Invalidate in-flight results without discarding the saved session.
            generation = UUID(); refreshTask?.cancel(); refreshTask = nil
        } else { scheduleMaintenance() }
    }

    func requireReconnect() {
        disconnect()
        state = .reconnectRequired
        message = "Spotify authorization was rejected. Connect again."
    }

    func stop() { invalidateWork() }

    private func invalidateWork() {
        generation = UUID()
        loginTask?.cancel(); loginTask = nil
        callback?.cancel(); callback = nil
        refreshTask?.cancel(); refreshTask = nil
        maintenance?.cancel(); maintenance = nil
        retryNotBefore = nil
    }

    private func check(_ current: UUID) throws {
        try Task.checkCancellation()
        guard generation == current else { throw CancellationError() }
    }

    private func scheduleMaintenance() {
        maintenance?.cancel(); maintenance = nil
        guard hasSession, !suspended else { return }
        maintenance = Task { [weak self] in
            var backoff: Double = 5
            while !Task.isCancelled {
                guard let self, self.hasSession, !self.suspended, let saved = self.tokens else { return }
                let delay = max(0, saved.expiresAt.timeIntervalSinceNow - 60)
                do {
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    try Task.checkCancellation()
                    _ = try await self.accessToken()
                    backoff = 5
                } catch {
                    if Task.isCancelled || !self.hasSession { return }
                    let retry: Double
                    if case SpotifyAuthError.retryAfter(let seconds) = error { retry = max(1, seconds) }
                    else { retry = backoff; backoff = min(300, backoff * 2) }
                    do { try await Task.sleep(for: .seconds(retry)) } catch { return }
                }
            }
        }
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let token_type: String
        let expires_in: Double
        let refresh_token: String?
        let scope: String?
    }
    private struct TokenFailure: Decodable { let error: String }

    private func requestTokens(fields: [String: String], clientID: String, previousRefresh: String?) async throws -> SpotifyTokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(fields)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw SpotifyAuthError.message("Spotify returned an unreadable response. Try again.") }
        guard data.count <= 64 * 1024 else { throw SpotifyAuthError.message("Spotify returned an oversized login response.") }
        if http.statusCode == 429 {
            let seconds = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            throw SpotifyAuthError.retryAfter(seconds.isFinite ? max(1, seconds) : 60)
        }
        guard http.statusCode == 200 else {
            let code = (try? JSONDecoder().decode(TokenFailure.self, from: data))?.error
            if code == "invalid_grant" { throw SpotifyAuthError.reconnect }
            if code == "invalid_client" || code == "unauthorized_client" {
                throw SpotifyAuthError.message("Spotify rejected this Client ID. Check your developer app settings and save the correct ID.")
            }
            if http.statusCode == 403 {
                throw SpotifyAuthError.message("Spotify denied access. Check your developer app’s allowed users, app-owner Premium status, and permissions.")
            }
            throw SpotifyAuthError.message("Spotify connection failed (HTTP \(http.statusCode)). Try again shortly.")
        }
        let decoded: TokenResponse
        do { decoded = try JSONDecoder().decode(TokenResponse.self, from: data) }
        catch { throw SpotifyAuthError.message("Spotify returned an incomplete login response. Try connecting again.") }
        let refresh = decoded.refresh_token ?? previousRefresh ?? ""
        guard !decoded.access_token.isEmpty, !refresh.isEmpty,
              decoded.token_type.lowercased() == "bearer", decoded.expires_in.isFinite,
              decoded.expires_in > 60 else { throw SpotifyAuthError.message("Spotify returned invalid credentials. Connect again.") }
        if let scope = decoded.scope,
           !Set(Self.scopes.split(separator: " ")).isSubset(of: Set(scope.split(separator: " "))) {
            throw SpotifyAuthError.message("Spotify did not grant the playback permissions. Connect again and allow the requested access.")
        }
        return SpotifyTokens(clientID: clientID, accessToken: decoded.access_token, refreshToken: refresh,
                             expiresAt: Date().addingTimeInterval(decoded.expires_in))
    }

    static func formEncoded(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let value = fields.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&")
        return Data(value.utf8)
    }

    static func challenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    static func authorizationURL(clientID: String, state: String, verifier: String) -> URL {
        var url = URLComponents(string: "https://accounts.spotify.com/authorize")!
        url.queryItems = ["client_id": clientID, "response_type": "code", "redirect_uri": redirectURI,
                         "state": state, "code_challenge_method": "S256", "code_challenge": challenge(verifier),
                         "scope": scopes].sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }
    static func randomURLSafe(bytes: Int) throws -> String {
        var buffer = [UInt8](repeating: 0, count: bytes)
        guard SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer) == errSecSuccess else {
            throw SpotifyAuthError.message("Could not generate a secure Spotify login. Try again.")
        }
        return base64URL(Data(buffer))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func safeMessage(_ error: Error) -> String {
        if let error = error as? SpotifyAuthError { return error.localizedDescription }
        // URLSession errors can carry request URLs; keep auth diagnostics deliberately generic.
        return "Could not reach Spotify. Check your connection; saved credentials will be kept."
    }
}
