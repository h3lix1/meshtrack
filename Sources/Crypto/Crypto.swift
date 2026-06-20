// Crypto — the decryption + key-management adapter (SPEC §2.5). Implements the
// Domain ports `PacketDecryptor` (AES-CTR over CryptoKit) and `KeyStore`
// (Keychain-backed, plus an in-memory fake for tests). Phase 1 placeholder.

/// Module marker; superseded by the AES-CTR decryptor + Keychain key store.
public enum CryptoModule {
    public static let name = "Crypto"
}
