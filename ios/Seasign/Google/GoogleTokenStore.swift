import Foundation
import Security

/// Where the Google refresh token lives. The app uses
/// `KeychainGoogleTokenStore`; tests use an in-memory one, so they never touch
/// the real Keychain. Nothing else about the Google sign-in is stored: the
/// access token is kept in memory only (`GoogleAccess`).
protocol GoogleTokenStore: Sendable {
    /// The stored refresh token, or nil when none is stored. Throws when the
    /// store cannot be read (for example before the phone's first unlock).
    func read() throws -> GoogleSecret?
    /// Replaces the stored token.
    func save(_ token: GoogleSecret) throws
    /// Removes the token; removing when none is stored is not an error.
    func delete() throws
}

/// The refresh token as one generic password in this app's Keychain, like
/// the LLM key (`KeychainKeyStore`) but under its own service: readable after
/// the phone's first unlock, never synchronised through iCloud and never
/// moved to another device by a backup
/// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). Needs no entitlement.
struct KeychainGoogleTokenStore: GoogleTokenStore {
    var service = "seasign.google-refresh-token"
    var account = "default"

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    func read() throws -> GoogleSecret? {
        var request = query
        request[kSecReturnData as String] = kCFBooleanTrue
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        guard let data = result as? Data, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw KeychainFailure(status: errSecDecode)
        }
        return GoogleSecret(text)
    }

    func save(_ token: GoogleSecret) throws {
        let data = Data(token.secret.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainFailure(status: status) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainFailure(status: added) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainFailure(status: status)
        }
    }

    /// The accessibility class of the stored item, for the tests.
    func storedAccessibility() throws -> String? {
        var request = query
        request[kSecReturnAttributes as String] = kCFBooleanTrue
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        return (result as? [String: Any])?[kSecAttrAccessible as String] as? String
    }
}

#if DEBUG
/// A refresh-token store in memory, for tests and the DEBUG sample. It
/// reflects and prints as nothing.
final class InMemoryGoogleTokenStore: GoogleTokenStore, CustomStringConvertible, CustomReflectable, @unchecked Sendable {
    private let lock = NSLock()
    private var token: GoogleSecret?
    private var failure: KeychainFailure?

    init(_ token: GoogleSecret? = nil) {
        self.token = token
    }

    /// Makes every call throw, standing in for a Keychain that will not answer.
    func setFailure(_ failure: KeychainFailure?) {
        lock.withLock { self.failure = failure }
    }

    /// What is stored, read without the failure, for the tests.
    var stored: GoogleSecret? {
        lock.withLock { token }
    }

    func read() throws -> GoogleSecret? {
        try lock.withLock {
            if let failure { throw failure }
            return token
        }
    }

    func save(_ token: GoogleSecret) throws {
        try lock.withLock {
            if let failure { throw failure }
            self.token = token
        }
    }

    func delete() throws {
        try lock.withLock {
            if let failure { throw failure }
            token = nil
        }
    }

    var description: String { "InMemoryGoogleTokenStore" }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}
#endif
