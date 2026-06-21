// InMemoryConfigStore — standalone, process-lifetime config + credential storage
// so `swift run MeshtrackApp` compiles and runs end-to-end before the durable
// concretes land.
//
// LEAD: replace with MeshStore/Keychain at integration. T-Persist ships the real
// GRDB-backed `ConfigGateway` (saved broker config + app settings in the shared
// WAL store) and a Keychain-backed `CredentialStore` (broker password keyed by
// host+username). Swap the two `default*` factory calls in `MeshtrackApp` for the
// real concretes; nothing else in this executable needs to change — the live
// wiring already programs to the `ConfigGateway` / `CredentialStore` ports.

import Domain
import Synchronization

/// In-memory `ConfigGateway`: holds the saved `BrokerConfig` + `AppSettings` for
/// the life of the process. `nil` broker config until something is saved, which is
/// the signal the onboarding/first-run path keys off. Thread-safe via a `Mutex`
/// (Domain's only allowed import beyond the stdlib), so it is `Sendable` and may
/// be shared across the actors the live wiring spans.
final class InMemoryConfigGateway: ConfigGateway {
    private struct State {
        var broker: BrokerConfig?
        var settings: AppSettings = .default
    }

    private let state = Mutex(State())

    /// - Parameter broker: an optional seed config (e.g. from the env fallback) so
    ///   the same store can carry the bootstrap connection until it is re-saved.
    init(broker: BrokerConfig? = nil) {
        if let broker {
            state.withLock { $0.broker = broker }
        }
    }

    func loadBrokerConfig() async throws -> BrokerConfig? {
        state.withLock { $0.broker }
    }

    func saveBrokerConfig(_ config: BrokerConfig) async throws {
        state.withLock { $0.broker = config }
    }

    func loadAppSettings() async throws -> AppSettings {
        state.withLock { $0.settings }
    }

    func saveAppSettings(_ settings: AppSettings) async throws {
        state.withLock { $0.settings = settings }
    }
}

/// In-memory `CredentialStore`: holds the broker password keyed by host+username,
/// mirroring the Keychain key scheme so multiple brokers/accounts coexist. The
/// password lives only in memory and is never logged. Replaced by the Keychain
/// concrete at integration (see the file header).
final class InMemoryCredentialStore: CredentialStore {
    /// A `(host, username, password)` seed so the env fallback's password is
    /// reachable through the same port until the Keychain concrete lands.
    struct Seed {
        var host: String
        var username: String?
        var password: String
    }

    private let store = Mutex<[String: String]>([:])

    init(seed: Seed? = nil) {
        if let seed {
            store.withLock { $0[Self.key(host: seed.host, username: seed.username)] = seed.password }
        }
    }

    func password(host: String, username: String?) -> String? {
        store.withLock { $0[Self.key(host: host, username: username)] }
    }

    func setPassword(_ password: String?, host: String, username: String?) throws {
        let key = Self.key(host: host, username: username)
        store.withLock {
            if let password {
                $0[key] = password
            } else {
                $0.removeValue(forKey: key)
            }
        }
    }

    /// Keychain-style composite key; username is part of the key so the same host
    /// can hold several accounts.
    private static func key(host: String, username: String?) -> String {
        "\(host)\u{0}\(username ?? "")"
    }
}
