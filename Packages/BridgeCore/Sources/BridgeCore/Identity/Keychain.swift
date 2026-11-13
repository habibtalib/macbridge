import CryptoKit
import Foundation
import Security

/// Secrets this app keeps in the login keychain: the identity key and the
/// server access token.
public enum Keychain {
    private static let service = "com.habibtalib.macbridge"

    public static func read(_ account: String) -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    public static func write(_ data: Data, to account: String) -> Bool {
        let update = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = base(account)
        item[kSecValueData as String] = data
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func delete(_ account: String) -> Bool {
        let status = SecItemDelete(base(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public enum IdentityStoreError: Error {
    /// A key exists but could not be read (keychain locked or access denied).
    /// Creating a new one here would silently unpair every device.
    case unreadable
    case cannotSave
}

extension Identity {
    private static let account = "identity-key"

    /// Loads this install's key from the keychain, creating it on first run.
    public static func loadOrCreate() throws -> Identity {
        if let stored = Keychain.read(account) {
            guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: stored) else {
                throw IdentityStoreError.unreadable
            }
            return Identity(privateKey: key)
        }
        let identity = Identity()
        guard Keychain.write(identity.privateKey.rawRepresentation, to: account) else {
            // Either the write was refused, or an item exists that we were not allowed to read.
            throw IdentityStoreError.cannotSave
        }
        return identity
    }
}
