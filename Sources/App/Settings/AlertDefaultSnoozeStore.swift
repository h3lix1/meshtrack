// AlertDefaultSnoozeStore — the REAL persistence of the operator's default-snooze
// setting, in the `app_config` key-value table.
//
// Finding 10: the production `AlertRuleStore` adapter never implemented
// save/loadDefaultSnoozeSeconds, so it fell through to the port's no-op/3600s
// default and the operator's snooze edit was lost on relaunch. (The in-memory fake
// DID persist it, so tests passed while production silently failed.)
//
// This helper is the durable backing both the live composition root's adapter and
// its tests use, so the round-trip is exercised against a real `MeshStore` (not the
// fake). Lives in the App library — which already depends on `Persistence` — keyed
// under a reserved `app_config` key distinct from broker / app_settings /
// channel_registry.

import Persistence

/// Read/write the operator's default alert-snooze duration (seconds) in the
/// `app_config` table. A free helper rather than a type so the production
/// `AlertRuleStore` adapter and its tests share one persistence path.
public enum AlertDefaultSnoozeStore {
    /// The reserved `app_config` key. Distinct from `broker` / `app_settings`
    /// (`ConfigGateway`) and `channel_registry` (the channel adapter).
    public static let configKey = "alert_default_snooze_seconds"

    /// The port-level default applied when nothing has been persisted yet
    /// (matches `AlertRuleStore`'s default-extension value, SPEC §2.6).
    public static let fallbackSeconds: Double = 3600

    /// Load the persisted default-snooze seconds, or `fallbackSeconds` when unset
    /// (or the stored value is unparseable).
    public static func load(from store: MeshStore) async throws -> Double {
        guard let raw = try await store.appConfigValue(forKey: configKey),
              let seconds = Double(raw) else {
            return fallbackSeconds
        }
        return seconds
    }

    /// Persist `seconds` as the default-snooze duration.
    public static func save(_ seconds: Double, to store: MeshStore) async throws {
        try await store.setAppConfigValue(String(seconds), forKey: configKey)
    }
}
