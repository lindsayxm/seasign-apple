import Foundation
import Security

/// The user's LLM API key, held only for as long as one request needs it.
///
/// It prints, reflects and debug-prints as `<redacted>`, so a key that ends
/// up in a string interpolation, a `dump`, a test failure or a debugger
/// summary shows nothing. It is not `Codable` and is never stored anywhere
/// but the Keychain.
struct APIKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The key itself. Read only where the request header is set.
    let secret: String

    /// A key typed or pasted in Settings, trimmed, if it has the shape the
    /// API accepts: 16 to 512 printable ASCII characters with no spaces.
    init?(typed: String) {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValid(trimmed) else { return nil }
        secret = trimmed
    }

    static let minLength = 16
    static let maxLength = 512

    static func isValid(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return (minLength...maxLength).contains(bytes.count)
            && bytes.allSatisfy { (0x21...0x7E).contains($0) }
    }

    var description: String { "<redacted>" }
    var debugDescription: String { "<redacted>" }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Where the key lives. The app uses `KeychainKeyStore`; tests and the DEBUG
/// sample use an in-memory one, so they never touch the real Keychain.
protocol APIKeyStore: Sendable {
    /// The stored key, or nil when none is stored. Throws when the store
    /// cannot be read.
    func read() throws -> APIKey?
    /// Replaces the stored key.
    func save(_ key: APIKey) throws
    /// Removes the key; removing when none is stored is not an error.
    func delete() throws
}

/// A Keychain call that failed. It carries the status code only.
struct KeychainFailure: Error, Equatable {
    var status: OSStatus
}

/// The key as one generic password in this app's Keychain: readable after the
/// phone's first unlock, never synchronised through iCloud and never moved to
/// another device by a backup (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
/// Needs no entitlement.
struct KeychainKeyStore: APIKeyStore {
    var service = "seasign.llm-api-key"
    var account = "default"

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    func read() throws -> APIKey? {
        var request = query
        request[kSecReturnData as String] = kCFBooleanTrue
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            throw KeychainFailure(status: errSecDecode)
        }
        // Something stored that is not a key reads as unreadable, not as no key.
        guard let key = APIKey(typed: text) else { throw KeychainFailure(status: errSecDecode) }
        return key
    }

    func save(_ key: APIKey) throws {
        let data = Data(key.secret.utf8)
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
/// A key store in memory, for tests and the DEBUG sample. It reflects and
/// prints as nothing, like `APIKey`.
final class InMemoryKeyStore: APIKeyStore, CustomStringConvertible, CustomReflectable, @unchecked Sendable {
    private let lock = NSLock()
    private var key: APIKey?
    private var failure: KeychainFailure?

    init(_ key: APIKey? = nil) {
        self.key = key
    }

    /// Makes every call throw, standing in for a Keychain that will not answer.
    func setFailure(_ failure: KeychainFailure?) {
        lock.withLock { self.failure = failure }
    }

    func read() throws -> APIKey? {
        try lock.withLock {
            if let failure { throw failure }
            return key
        }
    }

    func save(_ key: APIKey) throws {
        try lock.withLock {
            if let failure { throw failure }
            self.key = key
        }
    }

    func delete() throws {
        try lock.withLock {
            if let failure { throw failure }
            key = nil
        }
    }

    var description: String { "InMemoryKeyStore" }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}
#endif
