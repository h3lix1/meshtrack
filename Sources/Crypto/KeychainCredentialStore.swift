// Keychain-backed `CredentialStore` adapter (SPEC §2.5, §10). The broker
// password is a secret and so lives in the macOS Keychain, never in the GRDB
// store (`ConfigGateway` holds only the non-secret BrokerConfig) and never in
// logs.
//
// IMPORTANT — not on the unit-test critical path. Keychain access typically
// fails in headless / CI runs (no logged-in keychain, no app entitlement), so
// `swift test` exercises the pure account-key construction below; the live
// store/read/delete path is verified by the real app / integration runs. This
// mirrors KeychainKeyStore exactly.

import Domain
import Foundation
import Security

/// macOS Keychain implementation of `Domain.CredentialStore`.
///
/// Each broker password is stored as a `kSecClassGenericPassword` item under a
/// stable service id (default `"org.meshtrack.broker"`), with the account set to
/// `"host|username"` so multiple brokers/accounts coexist and rotate
/// independently (SPEC §10: in-app config, Keychain-stored). A nil username is
/// encoded as an empty username segment, so anonymous and named brokers on the
/// same host stay distinct items.
///
/// Reads are synchronous `SecItemCopyMatching` calls; the type holds no mutable
/// state beyond the immutable service id, so it is `Sendable`.
public struct KeychainCredentialStore: CredentialStore {
    /// Stable Keychain service identifier shared by all broker-password items.
    public static let defaultService = "org.meshtrack.broker"

    private let service: String

    public init(service: String = KeychainCredentialStore.defaultService) {
        self.service = service
    }

    // MARK: - CredentialStore

    public func password(host: String, username: String?) -> String? {
        var query = baseQuery(host: host, username: username)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            // errSecItemNotFound (and any access failure) simply means "no
            // password"; callers treat that as "this broker needs no / has no
            // saved password yet". The secret bytes are never logged.
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Stores, rotates, or deletes the broker password for `host` + `username`.
    ///
    /// A `nil` (or empty) password DELETES the item — clearing a credential is a
    /// first-class operation. Otherwise the item is added, or updated in place so
    /// rotation never leaves a stale duplicate. Throws `KeychainError.osStatus`
    /// with the underlying `OSStatus` on failure (the secret is never included in
    /// the error).
    public func setPassword(_ password: String?, host: String, username: String?) throws {
        guard let password, !password.isEmpty else {
            try delete(host: host, username: username)
            return
        }

        let secret = Data(password.utf8)
        let base = baseQuery(host: host, username: username)

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

    // MARK: - Helpers

    /// Removes the password for `host` + `username`. A missing item is success.
    private func delete(host: String, username: String?) throws {
        let status = SecItemDelete(baseQuery(host: host, username: username) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }

    /// The identifying attributes shared by lookup, store, and delete for one
    /// broker account.
    private func baseQuery(host: String, username: String?) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account(host: host, username: username)
        ]
    }

    /// The stable Keychain account string for a broker account: `"host|username"`
    /// (empty username segment when anonymous). Pure and side-effect-free so it
    /// is unit-testable without a live Keychain.
    static func account(host: String, username: String?) -> String {
        "\(host)|\(username ?? "")"
    }
}
