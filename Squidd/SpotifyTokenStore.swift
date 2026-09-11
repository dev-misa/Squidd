import Foundation
import Security

struct SpotifyTokens: Codable, Sendable {
    let clientID: String
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

@MainActor
protocol SpotifyTokenStorage {
    func load() throws -> SpotifyTokens?
    func save(_ tokens: SpotifyTokens) throws
    func delete() throws
}

@MainActor
struct SpotifyKeychain: SpotifyTokenStorage {
    private let service: String
    private let account = "oauth-session"
    init(service: String = "com.squidd.spotify") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func load() throws -> SpotifyTokens? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        do { return try JSONDecoder().decode(SpotifyTokens.self, from: data) }
        catch { throw SpotifyAuthError.message("Saved Spotify credentials could not be read. Disconnect and connect again.") }
    }

    func save(_ tokens: SpotifyTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    private func failure(_ status: OSStatus) -> SpotifyAuthError {
        // Only an OS status is surfaced; never include credential data.
        .message("Keychain access failed (\(status)). Unlock your login keychain and try again.")
    }
}
