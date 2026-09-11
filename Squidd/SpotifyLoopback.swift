import Foundation
import Network

@MainActor
protocol SpotifyCallbackListening: AnyObject {
    func authorizationCode(state: String, ready: @escaping @MainActor () throws -> Void) async throws -> String
    func cancel()
}

/// One short-lived HTTP listener, bound to the literal loopback address only.
@MainActor
final class SpotifyLoopback: SpotifyCallbackListening {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?
    private var connections: [UUID: NWConnection] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    private var expectedState = ""
    private var accepting = false

    func authorizationCode(state: String, ready: @escaping @MainActor () throws -> Void) async throws -> String {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                expectedState = state
                accepting = true
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 8888)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    var opened = false
                    listener.stateUpdateHandler = { [weak self] state in
                        MainActor.assumeIsolated {
                            guard let self, self.continuation != nil else { return }
                            switch state {
                            case .ready:
                                guard !opened else { return }; opened = true
                                do { try ready() } catch { self.finish(.failure(error)) }
                            case .failed(let error), .waiting(let error):
                                let message = error == .posix(.EADDRINUSE)
                                    ? "Port 8888 is in use. Quit the old Electron app or other app using that port, then reconnect."
                                    : "Could not start Spotify’s local callback listener. Check this app’s incoming network permission and try again."
                                self.finish(.failure(SpotifyAuthError.message(message)))
                            default: break
                            }
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        MainActor.assumeIsolated { self?.accept(connection) }
                    }
                    listener.start(queue: .main)
                    timeout = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(300)) } catch { return }
                        self?.finish(.failure(SpotifyAuthError.message("Spotify login timed out. Connect again when you’re ready.")))
                    }
                } catch { finish(.failure(SpotifyAuthError.message("Could not open port 8888 for Spotify login."))) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func accept(_ connection: NWConnection) {
        guard accepting, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        deadlines[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.close(id)
        }
        receive(id, data: Data())
    }

    private func receive(_ id: UUID, data: Data) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - data.count) { [weak self] chunk, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, self.connections[id] != nil else { return }
                var bytes = data
                if let chunk { bytes.append(chunk) }
                if bytes.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.respond(id, result: Self.parse(bytes, state: self.expectedState))
                } else if bytes.count >= 8192 || complete || error != nil {
                    self.respond(id, result: nil)
                } else { self.receive(id, data: bytes) }
            }
        }
    }

    /// Invalid/unrelated requests don't consume the pending login.
    static func parse(_ data: Data, state: String) -> Result<String, SpotifyAuthError>? {
        guard data.count <= 8192, let request = String(data: data, encoding: .utf8),
              let headerEnd = request.range(of: "\r\n\r\n") else { return nil }
        let lines = request[..<headerEnd.lowerBound].components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1",
              first[1].hasPrefix("/callback?"),
              let url = URLComponents(string: "http://127.0.0.1:8888" + first[1]),
              url.path == "/callback", url.fragment == nil else { return nil }
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        guard hosts.count == 1,
              hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:8888" else { return nil }
        let items = url.queryItems ?? []
        func values(_ name: String) -> [String] { items.filter { $0.name == name }.compactMap(\.value) }
        guard items.filter({ $0.name == "state" }).count == 1, values("state") == [state], !state.isEmpty else { return nil }
        let codes = values("code"), errors = values("error")
        guard items.filter({ $0.name == "code" }).count <= 1,
              items.filter({ $0.name == "error" }).count <= 1 else { return nil }
        if codes.count == 1, !codes[0].isEmpty, errors.isEmpty { return .success(codes[0]) }
        if errors.count == 1, codes.isEmpty {
            return .failure(.message(errors[0] == "access_denied"
                ? "Spotify login was declined. You can connect again anytime."
                : "Spotify could not authorize this app. Check the Client ID and redirect URI in your developer dashboard."))
        }
        return nil
    }

    private func respond(_ id: UUID, result: Result<String, SpotifyAuthError>?) {
        guard let connection = connections[id] else { return }
        if result != nil {
            guard accepting else { close(id); return }
            accepting = false
        }
        let body = result == nil ? "Invalid callback. Return to Spotify to finish signing in."
            : "Spotify authorization received. Return to Squidd to see the connection result. You can close this tab."
        let status = result == nil ? "400 Bad Request" : "200 OK"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated {
                self?.close(id)
                if let result { self?.finish(result.mapError { $0 as Error }) }
            }
        })
    }

    private func close(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
        deadlines.removeValue(forKey: id)?.cancel()
    }

    private func finish(_ result: Result<String, Error>) {
        guard let pending = continuation else { return }
        continuation = nil; accepting = false; expectedState = ""
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        for id in Array(connections.keys) { close(id) }
        pending.resume(with: result)
    }
}
