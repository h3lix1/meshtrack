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
    /// launches) AND the live-ingest store. Secrets never touch it — the broker
    /// password lives in the Keychain via `CredentialStore` (SPEC §2.5).
    private let store: MeshStore
    private let configGateway: any ConfigGateway
    private let credentialStore: any CredentialStore
    /// The persisted data-source selection (MQTT broker vs locally-attached node).
    /// Non-secret; `UserDefaults`-backed so broker persistence stays untouched.
    private let dataSourceStore: any DataSourceStore

    /// The settings window's tab registry, populated eagerly in `init` (before the
    /// Settings window first renders) so the initially-selected tab shows its content.
    @State private var settingsModel: SettingsModel
    @State private var root = RootCoordinator()
    /// The live theme applied across the app's chrome; seeded from the saved
    /// `AppSettings.themeID` and updated when the General picker selects a preset.
    @State private var themeController: ThemeController

    /// Promotes the process to a regular foreground GUI app on launch — see
    /// `MeshtrackAppDelegate`. Required because `swift run MeshtrackApp` starts a bare
    /// executable, which macOS otherwise treats as a background/accessory process
    /// (no menu bar, keyboard focus stuck on the launching terminal).
    @NSApplicationDelegateAdaptor(MeshtrackAppDelegate.self) private var appDelegate

    @Environment(\.openSettings) private var openSettings

    init() {
        let store = Self.openStore()
        self.store = store
        let gateway: any ConfigGateway = store // MeshStore conforms to ConfigGateway
        let credentials: any CredentialStore = KeychainCredentialStore()
        let dataSources: any DataSourceStore = UserDefaultsDataSourceStore()
        configGateway = gateway
        credentialStore = credentials
        dataSourceStore = dataSources

        // Register the Settings tabs EAGERLY, before the Settings window first
        // renders. (Doing it in `.onAppear` resolved the initially-selected tab
        // against an empty registry, so it stayed blank until the selection changed.)
        let themeController = ThemeController()
        let model = SettingsModel()
        Self.registerTabs(
            on: model,
            ports: ConfigPorts(gateway: gateway, credentials: credentials, dataSources: dataSources),
            store: store,
            themeController: themeController
        )
        _settingsModel = State(initialValue: model)
        _themeController = State(initialValue: themeController)
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
            ContentView(
                root: root,
                store: store,
                gateway: configGateway,
                credentials: credentialStore,
                dataSources: dataSourceStore,
                openConnectionSettings: openConnectionSettings
            )
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

    /// Register each Settings tab's content provider on `model`. Static and called
    /// from `init` so the registry is fully populated before the Settings window
    /// first renders (the initially-selected tab then shows its content immediately).
    @MainActor
    private static func registerTabs(
        on model: SettingsModel,
        ports: ConfigPorts,
        store: MeshStore,
        themeController: ThemeController
    ) {
        model.register(.connection) {
            AnyView(ConnectionSettingsView(viewModel: ConnectionSettingsViewModel(
                gateway: ports.gateway,
                credentials: ports.credentials,
                test: { await probeBrokerConnection($0, password: $1) },
                dataSourceStore: ports.dataSources
            )))
        }
        model.register(.channels) {
            AnyView(ChannelsSettingsView(viewModel: ChannelsSettingsViewModel(
                keys: KeychainChannelManager(store: store)
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

/// The non-secret configuration ports the settings screens + live wiring program
/// against, bundled so they pass as one argument: the `ConfigGateway` (broker config /
/// app settings), the `CredentialStore` (the broker password, in Keychain), and the
/// `DataSourceStore` (the MQTT-vs-local-node selection, in UserDefaults).
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
    let dataSources: any DataSourceStore
    let openConnectionSettings: () -> Void

    @State private var coordinator: LiveCoordinator?
    /// `nil` until the first config resolution completes (avoids flashing
    /// onboarding before we know whether a broker is saved).
    @State private var resolved = false

    var body: some View {
        content
            .task { await resolveAndApply() }
    }

    @ViewBuilder private var content: some View {
        if let coordinator, coordinator.status != .offline {
            LiveRootView(coordinator: coordinator)
        } else if root.exploringSample {
            RootView(nodes: SampleNetwork.nodes, traces: SampleNetwork.traces)
        } else if resolved {
            OnboardingView(
                onSetUpConnection: openConnectionSettings,
                onExploreSample: { root.exploringSample = true }
            )
        } else {
            // Brief, neutral splash while we read the saved config.
            Color(red: 0.03, green: 0.04, blue: 0.10)
                .overlay(ProgressView().controlSize(.large).tint(.cyan))
        }
    }

    /// Resolve the saved data source (MQTT broker or a locally-attached node) and
    /// (re)start the live coordinator. Builds the coordinator lazily on first
    /// connectable source. Idempotent and reconnect-safe: `applyConfig` restarts only
    /// when the resolved source changes.
    @MainActor private func resolveAndApply() async {
        defer { resolved = true }
        await seedFromEnvIfNeeded()
        // Go live when the active source is connectable: an MQTT broker is configured,
        // OR a local node is selected with the coordinates it needs.
        let brokerConfig = try? await gateway.loadBrokerConfig()
        let connectable = LiveDataSource.resolve(
            dataSource: dataSources.load(),
            brokerConfig: brokerConfig,
            password: { credentials.password(host: $0, username: $1) }
        ) != nil
        guard connectable else {
            coordinator?.stop()
            return
        }
        let live = coordinator ?? LiveCoordinator(store: store)
        coordinator = live
        await live.applyConfig(gateway: gateway, credentials: credentials, dataSourceStore: dataSources)
    }

    /// One-time bootstrap: if nothing is saved yet but the legacy `MESHTRACK_MQTT_*`
    /// env fallback is present, persist it into the store (+ Keychain) so the saved-
    /// config path takes over uniformly — handy for `meshtrackd`/CI/one-shot smokes.
    @MainActor private func seedFromEnvIfNeeded() async {
        guard await (try? gateway.loadBrokerConfig()) == nil,
              let env = LiveBrokerSettings.fromEnvironment() else { return }
        try? await gateway.saveBrokerConfig(env.makeBrokerConfig())
        if let password = env.password {
            try? credentials.setPassword(password, host: env.host, username: env.username)
        }
    }
}

/// The live shell: feeds the coordinator's `@Observable` view model into an
/// `AppModel` (the section registry), so every section renders live data and the
/// Network section animates real traffic. A connection-status badge overlays the
/// top-trailing corner (host only, never credentials).
struct LiveRootView: View {
    let coordinator: LiveCoordinator
    @State private var model: AppModel

    init(coordinator: LiveCoordinator) {
        self.coordinator = coordinator
        let model = AppModel(nodes: [], traces: [], live: true)
        // Wire every section to its live, store-backed view (the headline MapKit map,
        // node directory, telemetry, analytics, alerts, messages, health).
        model.registerLiveSections(store: coordinator.store, clock: SystemWallClock())
        _model = State(initialValue: model)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RootView(model: model)
            if coordinator.viewModel.nodes.isEmpty {
                ConnectingOverlay(host: coordinator.brokerHost)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ConnectionStatusBadge(status: coordinator.status)
                .padding(16)
        }
        // Mirror the live view model into the AppModel registry. Reading the
        // @Observable nodes/traces here re-runs this body as packets arrive, and
        // re-seeding the model rebuilds its section providers over the new data.
        .onChange(of: coordinator.viewModel.nodes) { _, nodes in
            model.nodes = nodes
        }
        .onChange(of: coordinator.viewModel.traces) { _, traces in
            model.traces = traces
        }
    }
}

/// "Connecting…" affordance shown until the first positioned node arrives. Shows
/// only the broker host — never credentials.
struct ConnectingOverlay: View {
    let host: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(.cyan)
            Text("Connecting to \(host)…").font(.headline).foregroundStyle(.white)
            Text("Waiting for nodes to report a position")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
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
