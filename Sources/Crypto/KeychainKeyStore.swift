// Keychain-backed `KeyStore` adapter (SPEC §2.5, §10). PSKs are secrets and so
// live in the macOS Keychain, never in the GRDB store and never in logs.
//
// IMPORTANT — not on the unit-test critical path. Keychain access typically
// fails in headless / CI runs (no logged-in keychain, no app entitlement), so
// the unit tests exercise the decryptor and `InMemoryKeyStore` instead. This
// adapter is kept compiling and documented; it is verified by the real app /
// integration runs, not by `swift test`.

import Domain
import Foundation
import Security

/// macOS Keychain implementation of `Domain.KeyStore`.
///
/// Each channel key is stored as a `kSecClassGenericPassword` item under a
/// stable service id (default `"org.meshtrack.psk"`), with the account set to
/// the channel hash. This lets up to 20 MQTT / 7 local channel keys (SPEC §10)
/// coexist and be rotated independently.
///
/// Reads are synchronous `SecItemCopyMatching` calls; the type holds no mutable
/// state beyond the immutable service id, so it is `Sendable`.
public struct KeychainKeyStore: KeyStore {
    /// Stable Keychain service identifier shared by all channel-key items.
    public static let defaultService = "org.meshtrack.psk"

    private let service: String

    public init(service: String = KeychainKeyStore.defaultService) {
        self.service = service
    }

    // MARK: - KeyStore

    public func key(forChannelHash channelHash: UInt32) -> ChannelKey? {
        var query = baseQuery(forChannelHash: channelHash)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            // errSecItemNotFound (and any access failure) simply means "no key";
            // callers treat a missing key as "cannot decrypt this channel".
            return nil
        }
        return ChannelKey(psk: [UInt8](data))
    }

    // MARK: - Store / rotate

    /// Stores or rotates the key for `channelHash`.
    ///
    /// Adds a new generic-password item, or updates the existing one in place so
    /// rotation never leaves a stale duplicate. Throws `KeychainError.osStatus`
    /// with the underlying `OSStatus` on failure so callers can surface a
    /// precise reason (the secret bytes are never included in the error).
    public func store(_ key: ChannelKey, forChannelHash channelHash: UInt32) throws {
        let secret = Data(key.psk)
        let base = baseQuery(forChannelHash: channelHash)

        let updateStatus = SecItemUpdate(
            base as CFDictionary,
            [kSecValueData as String: secret] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.osStatus(updateStatus)
        }

        var addQuery = base
        addQuery[kSecValueData as String] = secret
        // Keep the secret on-device only; never synced to iCloud Keychain.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.osStatus(addStatus)
        }
    }

    /// Removes the key for `channelHash`. A missing item is treated as success.
    public func removeKey(forChannelHash channelHash: UInt32) throws {
        let status = SecItemDelete(baseQuery(forChannelHash: channelHash) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }

    // MARK: - Helpers

    /// The identifying attributes shared by lookup, store, and delete for one
    /// channel. The account is the channel hash rendered as a stable string.
    private func baseQuery(forChannelHash channelHash: UInt32) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: String(channelHash)
        ]
    }
}

/// Typed Keychain failures. Carries only an `OSStatus` — never secret material.
public enum KeychainError: Error, Equatable, Sendable {
    /// A Keychain `SecItem*` call returned a non-success status.
    case osStatus(OSStatus)
}
