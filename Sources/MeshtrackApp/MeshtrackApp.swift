// MeshtrackApp — the runnable macOS SwiftUI app (the viewer/controller, SPEC §3).
//
// Composition root (Phase 8): configuration comes from the STORE, not the
// environment. The app resolves the broker connection from a `ConfigGateway`
// (non-secret `BrokerConfig`) + a `CredentialStore` (the password). Three states:
//
//   • a connectable `BrokerConfig` is saved → go LIVE (in-app MQTT ingest →
//     the animating network visualization), reconnecting automatically when the
//     saved config changes;
//   • nothing saved but the `MESHTRACK_MQTT_*` env fallback is present → seed the
//     store from the env and go live (handy for `meshtrackd`/CI/one-shot smokes);
//   • nothing saved and no env → show first-run ONBOARDING (set up a connection,
//     or explore with sample data).
//
// A macOS `Settings { }` scene (⌘,) hosts the `SettingsModel`-driven settings
// window. The live wiring lives in `LiveCoordinator` (this executable) so the
// `App` library stays snapshot-pure (phase7-gui §4).
//
//   swift run MeshtrackApp                 # first run → onboarding
//   live via env fallback (no saved config):
//     MESHTRACK_MQTT_HOST=mqtt.bayme.sh MESHTRACK_MQTT_USER=… MESHTRACK_MQTT_PASS=… \
//     MESHTRACK_MQTT_TLS=1 MESHTRACK_MQTT_TOPIC=msh/US/bayarea/2/e/# swift run MeshtrackApp

import App
import AppKit
import Crypto
import Domain
import Foundation
import Persistence
import SwiftUI

@main
struct MeshtrackApp: App {
    /// The shared on-disk store: the `ConfigGateway` (settings persist across
    /// launches), the `CredentialStore`/`KeyStore` (broker password + channel PSKs,
    /// stored locally in `app_config` — these are already-public secrets), AND the
    /// live-ingest store.
    private let store: MeshStore
    private let configGateway: any ConfigGateway
    private let credentialStore: any CredentialStore
    /// The on-device channel-PSK store, shared between the Channels & Keys screen and
    /// the live decoder so a key registered in Settings decodes without a relaunch.
    private let channelKeyStore: DatabaseKeyStore
    /// The persisted data-source selection (MQTT broker vs locally-attached node).
    /// Non-secret; backed by the shared `MeshStore` `app_config` table so it lives in
    /// the same durable store as the rest of the config (Finding 23). Concrete type so
    /// the composition root can `hydrate()` it from disk before resolving the source.
    private let dataSourceStore: MeshStoreDataSourceStore

    /// The settings window's tab registry, populated eagerly in `init` (before the
    /// Settings window first renders) so the initially-selected tab shows its content.
    @State private var settingsModel: SettingsModel
    @State private var root = RootCoordinator()
    /// The live theme applied across the app's chrome; seeded from the saved
    /// `AppSettings.themeID` and updated when the General picker selects a preset.
    @State private var themeController: ThemeController
    /// Reconnect-on-save signal (Finding 1): the Connection settings save path bumps
    /// it; `ContentView` observes its `token` and re-runs `resolveAndApply()`. Created
    /// in `init` so the same instance is injected into both the Settings tab and the
    /// content view.
    @State private var configRevision: LiveConfigRevision
    /// Deterministic Network-map workload selected by `--map-perf-fixture`.
    private let perfFixture: MapPerfData?

    /// Promotes the process to a regular foreground GUI app on launch — see
    /// `MeshtrackAppDelegate`. Required because `swift run MeshtrackApp` starts a bare
    /// executable, which macOS otherwise treats as a background/accessory process
    /// (no menu bar, keyboard focus stuck on the launching terminal).
    @NSApplicationDelegateAdaptor(MeshtrackAppDelegate.self) private var appDelegate

    @Environment(\.openSettings) private var openSettings

    init() {
        perfFixture = Self.perfFixtureFromArguments()
        let store = Self.openStore()
        self.store = store
        let gateway: any ConfigGateway = store // MeshStore conforms to ConfigGateway
        let credentials: any CredentialStore = DatabaseCredentialStore(store)
        let channelKeys = DatabaseKeyStore(store)
        let dataSources = MeshStoreDataSourceStore(store: store)
        configGateway = gateway
        credentialStore = credentials
        channelKeyStore = channelKeys
        dataSourceStore = dataSources

        // Register the Settings tabs EAGERLY, before the Settings window first
        // renders. (Doing it in `.onAppear` resolved the initially-selected tab
        // against an empty registry, so it stayed blank until the selection changed.)
        let themeController = ThemeController()
        let revision = LiveConfigRevision()
        let model = SettingsModel()
        Self.registerTabs(
            on: model,
            ports: ConfigPorts(gateway: gateway, credentials: credentials, dataSources: dataSources),
            store: store,
            channelKeys: channelKeys,
            themeController: themeController,
            revision: revision
        )
        _settingsModel = State(initialValue: model)
        _themeController = State(initialValue: themeController)
        _configRevision = State(initialValue: revision)
    }

    /// Open the durable on-disk store under Application Support, falling back to an
    /// in-memory store (config won't persist, but the app still runs) if the disk is
    /// unavailable. Only an utterly-unopenable SQLite — which means the app cannot
    /// function — is fatal.
    private static func openStore() -> MeshStore {
        if let store = try? openOnDisk() { return store }
        if let memory = try? MeshStore(DatabaseConnection.inMemory()) { return memory }
        fatalError("Meshtrack: cannot open a database (on-disk or in-memory)")
    }

    /// Open the store at `~/Library/Application Support/Meshtrack/meshtrack.sqlite`,
    /// creating the directory if needed.
    private static func openOnDisk() throws -> MeshStore {
        let manager = FileManager.default
        let dir = try manager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("Meshtrack", isDirectory: true)
        try manager.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("meshtrack.sqlite").path
        return try MeshStore(DatabaseConnection.onDisk(path: path))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let perfFixture {
                    MapPerfFixtureRootView(data: perfFixture)
                } else {
                    ContentView(
                        root: root,
                        store: store,
                        gateway: configGateway,
                        credentials: credentialStore,
                        channelKeys: channelKeyStore,
                        dataSources: dataSourceStore,
                        revision: configRevision,
                        openConnectionSettings: openConnectionSettings
                    )
                }
            }
            .frame(minWidth: 1100, minHeight: 720)
            .preferredColorScheme(.dark)
            .appTheme(themeController.theme)
            .task {
                // Init is synchronous, so resolve the saved theme once on launch.
                if let settings = try? await configGateway.loadAppSettings() {
                    themeController.apply(ThemeController.resolve(themeID: settings.themeID))
                }
            }
        }
        .windowStyle(.hiddenTitleBar)

        // The macOS Settings scene — auto-binds ⌘,. Driven by the SettingsModel
        // registry via the bespoke `SettingsShellView` chrome.
        Settings {
            SettingsShellView(model: settingsModel, tab: root.settingsTab)
                .preferredColorScheme(.dark)
                .appTheme(themeController.theme)
        }
    }

    /// Open Settings on the Connection tab (from onboarding / the status bar).
    private func openConnectionSettings() {
        root.settingsTab = .connection
        openSettings()
    }

    private static func perfFixtureFromArguments() -> MapPerfData? {
        let args = CommandLine.arguments
        for (index, arg) in args.enumerated() {
            if arg == "--map-perf-fixture", args.indices.contains(index + 1) {
                return MapPerfFixture.make(named: args[index + 1])
            }
            let prefix = "--map-perf-fixture="
            if arg.hasPrefix(prefix) {
                let name = String(arg.dropFirst(prefix.count))
                return MapPerfFixture.make(named: name)
            }
        }
        return nil
    }

    /// Register each Settings tab's content provider on `model`. Static and called
    /// from `init` so the registry is fully populated before the Settings window
    /// first renders (the initially-selected tab then shows its content immediately).
    @MainActor
    private static func registerTabs(
        on model: SettingsModel,
        ports: ConfigPorts,
        store: MeshStore,
        channelKeys: DatabaseKeyStore,
        themeController: ThemeController,
        revision: LiveConfigRevision
    ) {
        model.register(.connection) {
            AnyView(ConnectionSettingsView(viewModel: ConnectionSettingsViewModel(
                gateway: ports.gateway,
                credentials: ports.credentials,
                test: { await probeBrokerConnection($0, password: $1) },
                dataSourceStore: ports.dataSources,
                revision: revision
            )))
        }
        model.register(.channels) {
            AnyView(ChannelsSettingsView(viewModel: ChannelsSettingsViewModel(
                keys: LocalChannelManager(keys: channelKeys, store: store)
            )))
        }
        model.register(.general) {
            AnyView(GeneralSettingsView(viewModel: GeneralSettingsViewModel(
                gateway: ports.gateway,
                onThemeSelected: { themeController.apply($0) }
            )))
        }
        model.register(.alerts) {
            // Wrap the persisted store in the hours→seconds decorator so the editor's
            // stale-threshold HOURS become canonical SECONDS on save (and back on load),
            // matching what the rule engine evaluates (Finding 11).
            AnyView(AlertsConfigView(viewModel: AlertsConfigViewModel(
                rules: HoursToSecondsAlertRuleStore(wrapping: MeshStoreAlertRuleStore(store: store))
            )))
        }
        model.register(.about) { AnyView(AboutSettingsTab()) }
    }
}

/// The configuration ports the settings screens + live wiring program against,
/// bundled so they pass as one argument: the `ConfigGateway` (broker config / app
/// settings), the `CredentialStore` (the broker password, in the local app_config
/// store), and the `DataSourceStore` (the MQTT-vs-local-node selection, in UserDefaults).
struct ConfigPorts {
    let gateway: any ConfigGateway
    let credentials: any CredentialStore
    let dataSources: any DataSourceStore
}

/// Holds cross-window navigation state: which Settings tab to show, and whether
/// the operator chose to explore sample data on first run. `@Observable` so both
/// the main window and the Settings scene react.
@MainActor
@Observable
final class RootCoordinator {
    /// The tab the Settings window should open on (set before `openSettings`).
    var settingsTab: SettingsTab = .connection
    /// Operator opted into sample data from onboarding (no broker yet).
    var exploringSample = false
}

/// The main window's content: live shell when a broker is configured, sample shell
/// when the operator chose "Explore", onboarding otherwise. Re-evaluates the broker
/// config on launch and whenever the saved config changes (reconnect-on-change).
struct ContentView: View {
    let root: RootCoordinator
    let store: MeshStore
    let gateway: any ConfigGateway
    let credentials: any CredentialStore
    /// The shared on-device channel-PSK store, handed to the live coordinator so its
    /// decoder reads the same keys the Channels & Keys screen writes.
    let channelKeys: DatabaseKeyStore
    /// Concrete so the view can `hydrate()` the persisted selection from `app_config`
    /// before resolving the live source (Finding 23).
    let dataSources: MeshStoreDataSourceStore
    /// Reconnect-on-save signal (Finding 1): bumped by the Connection settings save;
    /// observing its `token` re-runs `resolveAndApply()` so a save goes live without
    /// a relaunch. A successful save is also an EXPLICIT connect, so it forces a start.
    let revision: LiveConfigRevision
    let openConnectionSettings: () -> Void

    @State private var coordinator: LiveCoordinator?
    /// `nil` until the first config resolution completes (avoids flashing
    /// onboarding before we know whether a broker is saved).
    @State private var resolved = false
    /// Whether a connectable source is saved but we stayed offline at launch (because
    /// `autoConnect` is off). Drives the onboarding "Connect now" affordance (Finding 2).
    @State private var hasConnectableSource = false

    var body: some View {
        content
            .task { await resolveAndApply() }
            // A successful Settings save bumps the revision. Re-resolve AND force a
            // connect: saving a connectable broker is an explicit operator action, so
            // it goes live even when `autoConnect` is off (Finding 1 + Finding 2).
            .onChange(of: revision.token) { _, _ in
                Task { await connectNow() }
            }
    }

    @ViewBuilder private var content: some View {
        if let coordinator, coordinator.status != .offline {
            LiveRootView(coordinator: coordinator)
        } else if root.exploringSample {
            RootView(nodes: SampleNetwork.nodes, traces: SampleNetwork.traces)
        } else if resolved {
            OnboardingView(
                onSetUpConnection: openConnectionSettings,
                onExploreSample: { root.exploringSample = true },
                // Offer an explicit connect only when a connectable source is saved
                // but auto-connect kept us offline at launch (Finding 2).
                onConnectNow: hasConnectableSource ? { Task { await connectNow() } } : nil
            )
        } else {
            // Brief, neutral splash while we read the saved config.
            Color(red: 0.03, green: 0.04, blue: 0.10)
                .overlay(ProgressView().controlSize(.large).tint(.cyan))
        }
    }

    /// Resolve the saved data source (MQTT broker or a locally-attached node) and
    /// (re)start the live coordinator. Builds the coordinator lazily on first
    /// connectable source, using the operator's configured refresh cadence. Idempotent
    /// and reconnect-safe: `applyConfig` restarts only when the resolved source changes.
    ///
    /// Honors `AppSettings.autoConnect` (Finding 2): with auto-connect off the app
    /// stays offline at launch even with a connectable source saved — the operator
    /// connects explicitly via the Connect affordance (which calls `connectNow()`).
    @MainActor private func resolveAndApply() async {
        defer { resolved = true }
        // Load the persisted data-source selection from app_config into the sync cache
        // before resolving (Finding 23).
        await dataSources.hydrate()
        await seedFromEnvIfNeeded()
        // Go live when the active source is connectable: an MQTT broker is configured,
        // OR a local node is selected with the coordinates it needs.
        let brokerConfig = try? await gateway.loadBrokerConfig()
        let connectable = LiveDataSource.resolve(
            dataSource: dataSources.load(),
            brokerConfig: brokerConfig,
            password: { credentials.password(host: $0, username: $1) }
        ) != nil
        hasConnectableSource = connectable
        guard connectable else {
            coordinator?.stop()
            return
        }
        // Build the coordinator with the operator's configured refresh cadence so the
        // slow "surface newly-positioned nodes" loop matches AppSettings (Finding 2).
        let settings = await (try? gateway.loadAppSettings()) ?? .default
        let live = coordinator ?? LiveCoordinator(
            store: store,
            refreshInterval: .seconds(settings.refreshIntervalSeconds),
            channelKeyStore: channelKeys
        )
        coordinator = live
        let allowAutoStart = LiveStartupPolicy.shouldConnectOnLaunch(
            settings: settings,
            hasConnectableSource: connectable
        )
        await live.applyConfig(
            gateway: gateway,
            credentials: credentials,
            dataSourceStore: dataSources,
            allowAutoStart: allowAutoStart
        )
    }

    /// Explicit operator-initiated connect (the Connect affordance / onboarding /
    /// status bar), overriding `autoConnect == false`. Builds the coordinator if
    /// needed (using the configured refresh cadence) and forces a connect.
    @MainActor private func connectNow() async {
        let settings = await (try? gateway.loadAppSettings()) ?? .default
        // Refresh the onboarding "Connect now" eligibility against the latest save.
        let brokerConfig = try? await gateway.loadBrokerConfig()
        hasConnectableSource = LiveDataSource.resolve(
            dataSource: dataSources.load(),
            brokerConfig: brokerConfig,
            password: { credentials.password(host: $0, username: $1) }
        ) != nil
        let live = coordinator ?? LiveCoordinator(
            store: store,
            refreshInterval: .seconds(settings.refreshIntervalSeconds),
            channelKeyStore: channelKeys
        )
        coordinator = live
        await live.connect(gateway: gateway, credentials: credentials, dataSourceStore: dataSources)
        resolved = true
    }

    /// One-time bootstrap: if nothing is saved yet but the legacy `MESHTRACK_MQTT_*`
    /// env fallback is present, persist it into the local store (config + password) so
    /// the saved-config path takes over uniformly — handy for `meshtrackd`/CI/smokes.
    @MainActor private func seedFromEnvIfNeeded() async {
        guard await (try? gateway.loadBrokerConfig()) == nil,
              let env = LiveBrokerSettings.fromEnvironment() else { return }
        try? await gateway.saveBrokerConfig(env.makeBrokerConfig())
        if let password = env.password {
            try? credentials.setPassword(password, host: env.host, username: env.username)
        }
    }
}

/// Promotes the bare SwiftPM executable to a regular foreground GUI app. Launched via
/// `swift run MeshtrackApp` the process starts as a background/accessory app: no menu
/// bar and keyboard focus stays with the launching terminal. Setting the activation
/// policy to `.regular` and activating gives it the standard menu bar (incl. the ⌘,
/// Settings item) and moves keyboard focus to the app window.
@MainActor
final class MeshtrackAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}
