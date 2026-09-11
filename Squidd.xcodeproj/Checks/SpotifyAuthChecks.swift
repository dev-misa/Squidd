import AppKit
import Foundation

@MainActor
final class MemoryTokens: SpotifyTokenStorage {
    var value: SpotifyTokens?
    var saves = 0
    var failDelete = false
    func load() -> SpotifyTokens? { value }
    func save(_ tokens: SpotifyTokens) { value = tokens; saves += 1 }
    func delete() throws {
        if failDelete { throw SpotifyAuthError.message("Test Keychain delete failure") }
        value = nil
    }
}

@MainActor
final class FakeCallback: SpotifyCallbackListening {
    var pending: CheckedContinuation<String, Error>?
    var nonce: String?
    var cancelled = false
    func authorizationCode(state: String, ready: @escaping @MainActor () throws -> Void) async throws -> String {
        nonce = state
        try ready()
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func complete(_ code: String) { let p = pending; pending = nil; p?.resume(returning: code) }
    func cancel() { cancelled = true; let p = pending; pending = nil; p?.resume(throwing: CancellationError()) }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { let status: Int; let body: String; var headers: [String: String] = [:] }
    static let lock = NSLock()
    nonisolated(unsafe) static var replies: [Reply] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static func reset(_ values: [Reply]) { lock.lock(); defer { lock.unlock() }; replies = values; requests = [] }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let reply = Self.replies.isEmpty ? Reply(status: 500, body: "{}") : Self.replies.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct SpotifyAuthChecks {
    @MainActor static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Timed out waiting for expected authentication state")
    }
    @MainActor static func main() async throws {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        assert(SpotifyAuth.challenge(verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let random = try SpotifyAuth.randomURLSafe(bytes: 64)
        let secondRandom = try SpotifyAuth.randomURLSafe(bytes: 64)
        assert((43...128).contains(random.count) && !random.contains("=") && random != secondRandom)
        assert(String(data: SpotifyAuth.formEncoded(["code": "a+b&c= d"]), encoding: .utf8) == "code=a%2Bb%26c%3D%20d")
        let id = String(repeating: "a", count: 32)
        assert(SpotifyAuth.validClientID(id) && !SpotifyAuth.validClientID("secret"))
        let url = SpotifyAuth.authorizationURL(clientID: id, state: "nonce", verifier: verifier)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        assert(query.first(where: { $0.name == "redirect_uri" })?.value == SpotifyAuth.redirectURI)
        assert(!url.absoluteString.contains(verifier) && !url.absoluteString.contains("client_secret"))
        func callback(_ target: String, host: String = "127.0.0.1:8888") -> Data {
            Data("GET \(target) HTTP/1.1\r\nHost: \(host)\r\n\r\n".utf8)
        }
        let parsed = try SpotifyLoopback.parse(callback("/callback?code=hello&state=nonce"), state: "nonce")!.get()
        assert(parsed == "hello")
        assert(SpotifyLoopback.parse(callback("/callback?code=hello&state=wrong"), state: "nonce") == nil)
        assert(SpotifyLoopback.parse(callback("/callback?code=hello&state=nonce&state=nonce"), state: "nonce") == nil)
        assert(SpotifyLoopback.parse(callback("/other?code=hello&state=nonce"), state: "nonce") == nil)
        assert(SpotifyLoopback.parse(callback("/callback?code=hello&state=nonce", host: "example.com"), state: "nonce") == nil)
        assert(SpotifyLoopback.parse(callback("/callback?code=a&code=b&state=nonce"), state: "nonce") == nil)
        assert(SpotifyLoopback.parse(Data(repeating: 65, count: 8193), state: "nonce") == nil)
        if case .failure? = SpotifyLoopback.parse(callback("/callback?error=access_denied&state=nonce"), state: "nonce") {} else { fatalError("Denial not handled") }

        let suite = "Squidd.AuthChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let storage = MemoryTokens()
        var listener = FakeCallback()
        var opened = false
        let auth = SpotifyAuth(defaults: defaults, storage: storage, session: session,
                               makeListener: { listener }, openBrowser: { _ in opened = true; return true })
        assert(auth.saveClientID("  " + id + "\n"))
        StubProtocol.reset([.init(status: 200, body: "{\"access_token\":\"access1\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"refresh_token\":\"refresh1\"}")])
        auth.connect()
        try await waitUntil { listener.pending != nil }
        assert(opened && auth.state == .connecting)
        listener.complete("test-code")
        try await waitUntil { auth.state == .connected }
        assert(storage.value?.accessToken == "access1" && defaults.bool(forKey: "spotifySessionEnabled"))
        let cachedToken = try await auth.accessToken()
        assert(cachedToken == "access1")
        assert(StubProtocol.count == 1)
        auth.stop()
        let restored = SpotifyAuth(defaults: defaults, storage: storage, session: session)
        restored.restore()
        assert(restored.hasSession && restored.state == .connected)
        StubProtocol.reset([.init(status: 200, body: "{\"access_token\":\"access2\",\"token_type\":\"Bearer\",\"expires_in\":3600}")])
        async let a = restored.accessToken(forceRefresh: true)
        async let b = restored.accessToken(forceRefresh: true)
        let values = try await [a, b]
        assert(values == ["access2", "access2"] && StubProtocol.count == 1)
        assert(storage.value?.refreshToken == "refresh1")
        StubProtocol.reset([.init(status: 503, body: "{}")] )
        do { _ = try await restored.accessToken(forceRefresh: true); fatalError("503 succeeded") } catch {}
        assert(restored.hasSession && storage.value != nil && restored.state == .offline)
        StubProtocol.reset([.init(status: 429, body: "{}", headers: ["Retry-After": "90"])])
        do { _ = try await restored.accessToken(forceRefresh: true); fatalError("429 succeeded") } catch {}
        do { _ = try await restored.accessToken(forceRefresh: true); fatalError("Retry delay ignored") } catch {}
        assert(StubProtocol.count == 1 && restored.hasSession)
        restored.disconnect()
        assert(!restored.hasSession && storage.value == nil)
        listener = FakeCallback()
        auth.connect(); try await waitUntil { listener.pending != nil }
        auth.cancelLogin()
        assert(listener.cancelled && auth.state == .disconnected)
        listener.complete("late-code")
        try await Task.sleep(for: .milliseconds(30))
        assert(!auth.hasSession)
        listener = FakeCallback()
        auth.connect(); try await waitUntil { listener.pending != nil }
        assert(auth.saveClientID(String(repeating: "b", count: 32)))
        assert(listener.cancelled && !auth.hasSession)
        storage.value = SpotifyTokens(clientID: id, accessToken: "old", refreshToken: "old-refresh", expiresAt: .distantFuture)
        storage.failDelete = true
        auth.disconnect()
        let afterLogout = SpotifyAuth(defaults: defaults, storage: storage, session: session)
        afterLogout.restore()
        assert(!afterLogout.hasSession && !defaults.bool(forKey: "spotifySessionEnabled"))
        storage.failDelete = false
        defaults.set(id, forKey: "spotifyClientID")
        defaults.set(true, forKey: "spotifySessionEnabled")
        let revoked = SpotifyAuth(defaults: defaults, storage: storage, session: session)
        revoked.restore()
        StubProtocol.reset([.init(status: 400, body: "{\"error\":\"invalid_grant\"}")])
        do { _ = try await revoked.accessToken(forceRefresh: true); fatalError("Revoked grant succeeded") } catch {}
        assert(revoked.state == .reconnectRequired && !revoked.hasSession && storage.value == nil)
        revoked.stop(); restored.stop(); auth.stop(); afterLogout.stop()
        if CommandLine.arguments.contains("--integration") { try await integrationChecks() }
        print("Spotify checks passed: PKCE vector, form encoding, callback validation, login, restore, coalesced refresh, retained refresh token, transient errors, Retry-After, cancellation, Client ID change, logout persistence, revoked grant.")
    }
    @MainActor static func integrationChecks() async throws {
        let keychain = SpotifyKeychain(service: "com.squidd.auth-checks." + UUID().uuidString)
        defer { try? keychain.delete() }
        let original = SpotifyTokens(clientID: "test", accessToken: "test-access", refreshToken: "test-refresh", expiresAt: Date().addingTimeInterval(3600))
        try keychain.save(original)
        let loaded = try keychain.load()
        assert(loaded?.accessToken == original.accessToken)
        let updated = SpotifyTokens(clientID: "test", accessToken: "updated", refreshToken: "test-refresh", expiresAt: original.expiresAt)
        try keychain.save(updated)
        let reloaded = try keychain.load()
        assert(reloaded?.accessToken == "updated")
        try keychain.delete()
        let deleted = try keychain.load()
        assert(deleted == nil)

        let listener = SpotifyLoopback()
        var ready = false
        let callbackTask = Task { try await listener.authorizationCode(state: "integration-nonce") { ready = true } }
        try await waitUntil { ready || callbackTask.isCancelled }
        let occupied = SpotifyLoopback()
        do {
            _ = try await occupied.authorizationCode(state: "other") { fatalError("Two listeners bound to port 8888") }
            fatalError("Port collision was not reported")
        } catch {
            assert(error.localizedDescription.contains("8888"))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let network = URLSession(configuration: configuration)
        defer { network.invalidateAndCancel() }
        let (_, badResponse) = try await network.data(from: URL(string: "http://127.0.0.1:8888/callback?code=test&state=wrong")!)
        assert((badResponse as? HTTPURLResponse)?.statusCode == 400)
        let (_, response) = try await network.data(from: URL(string: "http://127.0.0.1:8888/callback?code=integration-code&state=integration-nonce")!)
        assert((response as? HTTPURLResponse)?.statusCode == 200)
        let code = try await callbackTask.value
        assert(code == "integration-code")
        let cancelled = SpotifyLoopback()
        ready = false
        let cancelTask = Task { try await cancelled.authorizationCode(state: "cancel") { ready = true } }
        try await waitUntil { ready }
        cancelled.cancel()
        do { _ = try await cancelTask.value; fatalError("Cancelled listener returned success") }
        catch { assert(error is CancellationError) }
        print("Integration checks passed: isolated real Keychain save/update/load/delete; loopback callback, invalid-state rejection, port collision, cancellation and port reuse.")
    }

}
