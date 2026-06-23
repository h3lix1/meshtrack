// LiveCoordinator — the GUI composition root for LIVE operation.
//
// This is where the live wiring lives so the `App` library stays snapshot-pure
// (App must NOT import Ingest/Transport/Crypto, phase7-gui §4). The coordinator
// resolves the broker connection from the config store (NOT the environment,
// Phase 8): the non-secret `BrokerConfig` from a `ConfigGateway` + the password
// from a `CredentialStore`. It then connects MQTT → the validated
// `IngestPipeline` (decode + AES-CTR decrypt + persist) → the `NetworkViewModel`,
// so the app animates real fleet traffic:
//
//   - the pipeline persists every reception (positions / telemetry / messages)
//     AND records `observation.ingest_time = frame.receivedAt` (the latency source);
//   - its `onDecoded` tap feeds each decoded packet into the view model so traces
//     animate the moment a packet arrives, even before a position fix lands;
//   - a slow refresh loop calls `loadNodes()` to surface newly-positioned nodes.
//
// Reconnect-on-change: `applyBrokerConfig(_:)` restarts the MQTT stream against a
// new saved config, so saving a broker in Settings goes live without a relaunch.
//
// The legacy `MESHTRACK_MQTT_*` environment path is a FALLBACK only (see
// `LiveBrokerSettings.fromEnvironment`), wired by the composition root when no
// `BrokerConfig` has been saved.

import App
import Crypto
import Domain
import Foundation
import Ingest
import Persistence
import Transport

/// The shell-facing connection state. Carries only the active endpoint — the broker
/// host for MQTT, or the device path/name for a local node — never any credentials,
/// so the status indicator can show "connecting to mqtt.bayme.sh" (or "…to
/// /dev/cu.usbmodem3101") without ever surfacing a secret.
enum LiveConnectionStatus: Equatable {
    case offline
    case connecting(host: String)
    case connected(host: String)

    /// The endpoint, when connecting/connected; `nil` when offline.
    var host: String? {
        switch self {
        case .offline: nil
        case let .connecting(host), let .connected(host): host
        }
    }
}

/// Drives the live network composition: owns the store, the `NetworkViewModel`,
/// and the long-running ingest + refresh tasks. `@MainActor` because it mutates
/// the view model + status the SwiftUI shell observes.
@MainActor
@Observable
final class LiveCoordinator {
    /// The live network view model the shell renders (nodes + animated traces).
    let viewModel: NetworkViewModel
    /// The live packet inspector, fed from the same decoded-packet tap as the network
    /// view model (Finding 17). Backs the `.packets` section with real traffic instead
    /// of sample data, and its `latencyMillis` feeds the map's latency overlay.
    let packetInspector: PacketInspectorViewModel
    /// Mesh-traffic aggregators (Phase 10), fed from the same decoded-packet tap as the
    /// network/inspector VMs. Back the Port Numbers + Largest Offenders sections with
    /// real running totals; both snapshot their aggregates to the store periodically.
    let portStats: PortStatsViewModel
    let offenders: OffendersViewModel
    /// The connection state for the status indicator (endpoint only, never secrets).
    private(set) var status: LiveConnectionStatus = .offline

    /// The active endpoint (broker host or device), for the "connecting…" affordance
    /// (never logs credentials). Named `brokerHost` for source compatibility with the
    /// existing shell; it is the host for MQTT and the device path/name for a node.
    var brokerHost: String {
        status.host ?? ""
    }

    /// The shared in-memory store; exposed so the shell can wire the store-backed
    /// section view models (nodes / telemetry / analytics / alerts / messages).
    let store: MeshStore
    private let refreshInterval: Duration
    /// The currently-running source (MQTT settings incl. resolved password, or a local
    /// node's coordinates). `nil` while offline. Never logged.
    private var dataSource: LiveDataSource?
    private var tasks: [Task<Void, Never>] = []

    /// The well-known Meshtastic default channel key (PSK index 1, "AQ=="), shared
    /// by the public MediumFast/LongFast channels. Used as the *fallback* for any
    /// channel hash the operator hasn't registered a custom PSK for — custom PSKs
    /// are resolved from the local key store first (see `keyStore`).
    private static let defaultKey = ChannelKey(psk: MeshtasticChannelHash.defaultPSK)

    /// The live channel-key resolver: custom PSKs registered in Channels & Keys
    /// (held in the local app store, keyed by channel hash) are resolved FIRST, with the
    /// public default PSK as the fallback. This is what lets a non-default-PSK
    /// channel entered in settings actually decrypt in the live app (Finding 8).
    private let keyStore: any KeyStore

    /// The sync-readable gate the resolver consults for the default-PSK fallback, and
    /// the channel manager that refreshes it from the registry + tombstone. `nil` when
    /// a custom `keyStore` was injected (tests own their own gating). When present, a
    /// removed default channel stops default-key decoding this session and on relaunch
    /// (Finding 16).
    private let defaultGate: DefaultChannelGate?
    private let channelManager: LocalChannelManager?

    /// Build a coordinator over a fresh in-memory store. The broker connection is
    /// resolved later via `applyBrokerConfig(_:)` / `start(settings:)`, so the
    /// coordinator exists before any broker is configured (first-run/onboarding).
    /// `refreshInterval` is the cadence of the slow `loadNodes()` loop that surfaces
    /// newly-positioned nodes.
    ///
    /// `keyStore` resolves the decrypt key per channel hash. It defaults to a
    /// `ChannelKeyResolver` over the local `DatabaseKeyStore`, so custom PSKs the
    /// operator registered in Channels & Keys are resolved by hash, with the public
    /// default PSK as the fallback (Finding 8). Injectable for tests.
    ///
    /// `channelKeyStore` is the shared, on-device PSK store. The composition root
    /// passes ONE instance so the Channels & Keys screen and this decoder read/write
    /// the same keys (a key added in Settings decodes immediately). Defaults to a
    /// fresh one over `store` when not supplied.
    init(
        store: MeshStore,
        refreshInterval: Duration = .seconds(3),
        keyStore: (any KeyStore)? = nil,
        channelKeyStore: DatabaseKeyStore? = nil
    ) {
        self.refreshInterval = refreshInterval
        self.store = store
        if let keyStore {
            // A test injected its own resolver; it owns its default-key gating.
            self.keyStore = keyStore
            defaultGate = nil
            channelManager = nil
        } else {
            // Production: gate the default-PSK fallback on the registry + tombstone so
            // removing the default channel stops default-key decoding (Finding 16). The
            // channel manager shares the same gate so an in-session removal takes effect
            // immediately; the slow refresh loop + startup re-derive it from the store.
            let gate = DefaultChannelGate()
            defaultGate = gate
            // One shared on-device key store for both the manager (writes) and the
            // resolver (reads), so a freshly-registered key decodes without a relaunch.
            let primary = channelKeyStore ?? DatabaseKeyStore(store)
            channelManager = LocalChannelManager(keys: primary, store: store, defaultGate: gate)
            self.keyStore = ChannelKeyResolver(
                primary: primary,
                defaultKey: Self.defaultKey,
                defaultEnabled: { gate.isEnabled() }
            )
        }
        viewModel = NetworkViewModel(store: store)
        packetInspector = PacketInspectorViewModel(clock: SystemWallClock())
        portStats = PortStatsViewModel(store: store)
        offenders = OffendersViewModel(store: store)
    }

    /// Resolve the active data source from the persisted selection (`DataSourceStore`)
    /// plus the broker config/password and, if it is connectable, (re)start the live
    /// stream. Reconnect-on-change: if the resolved source differs from the running
    /// stream's, the stream restarts; identical → no-op. With nothing connectable the
    /// stream stops and the status goes offline. The broker password is read from the
    /// `CredentialStore` and held only in memory; it is never logged.
    ///
    /// `allowAutoStart` gates whether a connectable source is started automatically.
    /// Launch passes `LiveStartupPolicy.shouldConnectOnLaunch(...)` so an operator who
    /// turned `autoConnect` off stays offline until they explicitly connect; an already-
    /// running stream still reconnects-on-change. An explicit `connect()` (the Connect
    /// affordance / a successful Settings save) always starts, regardless of this gate.
    func applyConfig(
        gateway: any ConfigGateway,
        credentials: any CredentialStore,
        dataSourceStore: any DataSourceStore,
        allowAutoStart: Bool = true
    ) async {
        let brokerConfig = try? await gateway.loadBrokerConfig()
        let resolved = LiveDataSource.resolve(
            dataSource: dataSourceStore.load(),
            brokerConfig: brokerConfig,
            password: { credentials.password(host: $0, username: $1) }
        )
        guard let resolved else {
            stop()
            return
        }
        // When auto-start is withheld (autoConnect off) and we are not already
        // streaming, stay offline: don't begin a connection the operator didn't ask
        // for. A live stream still reconnects-on-change so a saved edit takes effect.
        guard allowAutoStart || isRunning else { return }
        apply(dataSource: resolved)
    }

    /// Explicit operator-initiated connect: resolve the active source and start the
    /// live stream regardless of the `autoConnect` preference. Invoked from the
    /// Connect affordance (onboarding / status bar) and from a successful Settings
    /// save, so a user action always overrides `autoConnect == false`.
    func connect(
        gateway: any ConfigGateway,
        credentials: any CredentialStore,
        dataSourceStore: any DataSourceStore
    ) async {
        await applyConfig(
            gateway: gateway,
            credentials: credentials,
            dataSourceStore: dataSourceStore,
            allowAutoStart: true
        )
    }

    /// Whether a live stream is currently running (a source is resolved and tasks are
    /// active). Used to keep reconnect-on-change working while withholding a fresh
    /// auto-start when `autoConnect` is off.
    private var isRunning: Bool {
        dataSource != nil
    }

    /// (Re)start the live stream against `newSettings` (an MQTT broker). Convenience
    /// seam for the env-fallback path and tests; wraps the settings in the MQTT source.
    func apply(settings newSettings: LiveBrokerSettings) {
        apply(dataSource: .mqtt(newSettings))
    }

    /// (Re)start the live stream against `newSource`. Restarts on change, no-ops when
    /// unchanged. Public seam for the composition root and tests.
    func apply(dataSource newSource: LiveDataSource) {
        guard dataSource != newSource else { return }
        stop()
        start(dataSource: newSource)
    }

    /// Connect and begin streaming live packets into the visualization. The
    /// pipeline persists + extracts while `onDecoded` feeds traces; a slow loop
    /// refreshes node positions from the store. Works identically for every source —
    /// MQTT, serial, or BLE — since they all implement `MeshTransport`.
    private func start(dataSource newSource: LiveDataSource) {
        dataSource = newSource
        let host = newSource.displayEndpoint
        status = .connecting(host: host)

        let adapter = newSource.makeTransport(clock: SystemWallClock())
        let decoder = PacketDecoder(
            keyStore: keyStore,
            decryptor: AESCTRPacketDecryptor()
        )
        let pipeline = IngestPipeline(store: store, decoder: decoder)
        let model = viewModel
        let inspector = packetInspector
        let ports = portStats
        let offenderStats = offenders
        // A @MainActor tap that promotes the status to `.connected`; capturing this
        // closure (rather than `self`) keeps the Sendable ingest closure clean.
        let onFirstPacket: @MainActor @Sendable () -> Void = { [weak self] in
            self?.markConnected(host: host)
        }

        // Ingest: decode + decrypt + persist, tapping each decoded packet into the
        // live trace animation AND the packet inspector (Finding 17). `ingest` hops to
        // the main actor (the VMs are @MainActor); the tap is awaited per packet, so it
        // stays in order. The first decoded packet flips the status to `.connected`.
        tasks.append(Task {
            _ = try? await pipeline.run(adapter) { packet in
                await model.ingest(packet)
                await inspector.ingest(packet)
                await ports.ingest(packet)
                await offenderStats.ingest(packet)
                await onFirstPacket()
            }
        })

        // The live alert loop's reusable ports (Finding 7): a store-backed snapshot
        // source, the configured rule store (HOURS→SECONDS over the GRDB adapter), the
        // store sink, and a wall clock. The management lookup is rebuilt per pass so it
        // tracks the latest ownership classification.
        let snapshotSource = StoreAlertSnapshotSource(store: store)
        let ruleStore = HoursToSecondsAlertRuleStore(wrapping: MeshStoreAlertRuleStore(store: store))
        let alertSink = store
        let alertClock = SystemWallClock()

        // Slow refresh: surface nodes as soon as they report a position; re-derive the
        // default-PSK gate from the registry + tombstone so a default-channel removal
        // stops default-key decoding within a refresh cycle (Finding 16); and run live
        // telemetry through RuleEvaluator → AlertEngine → store so battery/stale/voltage
        // alerts the console shows are actually generated (Finding 7).
        tasks.append(Task { [refreshInterval, channelManager] in
            while !Task.isCancelled {
                try? await model.loadNodes()
                await channelManager?.refreshDefaultGate()
                let management = await StoreAlertNodeManagementLookup(store: store)
                let evaluator = LiveAlertEvaluator(
                    snapshots: snapshotSource,
                    rules: ruleStore,
                    management: management,
                    sink: alertSink,
                    clock: alertClock
                )
                _ = try? await evaluator.evaluate()
                try? await Task.sleep(for: refreshInterval)
            }
        })
    }

    /// Cancel the live tasks (disconnects the active stream via its termination
    /// handler — MQTT disconnect, serial close, BLE cancel) and go offline. Safe to
    /// call more than once.
    func stop() {
        for task in tasks {
            task.cancel()
        }
        tasks.removeAll()
        dataSource = nil
        status = .offline
    }

    /// Promote `.connecting` to `.connected` once the stream yields a packet. Only
    /// applies while still pointed at the same host (ignores stale taps from a
    /// stream that was replaced by a reconnect).
    private func markConnected(host: String) {
        if case .connecting(host) = status {
            status = .connected(host: host)
        }
    }
}

/// The real wall-clock adapter for the `Clock` port, confined to this composition
/// root (Domain never reads `Date()`). Stamps each inbound frame's `receivedAt`,
/// which becomes `observation.ingest_time` — the receive→publish latency source.
struct SystemWallClock: Domain.Clock {
    func now() -> Instant {
        Instant(nanosecondsSinceEpoch: Int64((Date().timeIntervalSince1970 * 1_000_000_000).rounded()))
    }
}
