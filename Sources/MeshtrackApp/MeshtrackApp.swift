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

    /// The settings window's tab registry. The Connection/Channels/General/Alerts
    /// tabs are owned by other agents and register themselves at integration; here
    /// we register placeholder providers for tabs nothing else has wired yet, so the
    /// window always renders. About is owned here.
    @State private var settingsModel = SettingsModel()
    @State private var root = RootCoordinator()
    /// The live theme applied across the app's chrome; seeded from the saved
    /// `AppSettings.themeID` and updated when the General picker selects a preset.
    @State private var themeController = ThemeController()

    @Environment(\.openSettings) private var openSettings

    init() {
        let store = Self.openStore()
        self.store = store
        configGateway = store // MeshStore conforms to ConfigGateway (Persistence)
        credentialStore = KeychainCredentialStore()
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
                .onAppear { registerSettingsTabs() }
        }
    }

    /// Open Settings on the Connection tab (from onboarding / the status bar).
    private func openConnectionSettings() {
        root.settingsTab = .connection
        openSettings()
    }

    /// Whether the settings tabs have been registered yet (one-shot: `.onAppear`
    /// can fire more than once for the Settings scene).
    @State private var settingsTabsRegistered = false

    /// Register content providers so the Settings window renders end-to-end before
    /// the other agents' tabs land. The About tab is owned here; Connection /
    /// Channels / General / Alerts get bespoke placeholders.
    ///
    /// LEAD: at integration each owning agent registers its real provider by
    /// calling `settingsModel.register(.tab) { … }` from its own composition file.
    /// `register` replaces, so call those registrations AFTER this seed (or simply
    /// drop the matching placeholder line below). This runs once per launch.
    private func registerSettingsTabs() {
        guard !settingsTabsRegistered else { return }
        settingsTabsRegistered = true
        let gateway = configGateway
        let credentials = credentialStore
        let store = store
        let themeController = themeController

        settingsModel.register(.connection) {
            AnyView(ConnectionSettingsView(viewModel: ConnectionSettingsViewModel(
                gateway: gateway,
                credentials: credentials,
                test: { await probeBrokerConnection($0, password: $1) }
            )))
        }
        // Channels: the screen + Keychain key store exist; wiring its (synchronous)
        // ChannelKeyManaging port to a persistent registry needs an async revision —
        // tracked as a follow-up. Placeholder until then.
        settingsModel.register(.channels) { AnyView(PlaceholderSettingsTab(tab: .channels)) }
        settingsModel.register(.general) {
            AnyView(GeneralSettingsView(viewModel: GeneralSettingsViewModel(
                gateway: gateway,
                onThemeSelected: { themeController.apply($0) }
            )))
        }
        settingsModel.register(.alerts) {
            AnyView(AlertsConfigView(viewModel: AlertsConfigViewModel(
                rules: MeshStoreAlertRuleStore(store: store)
            )))
        }
        settingsModel.register(.about) { AnyView(AboutSettingsTab()) }
    }
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

    /// Resolve the saved broker config and (re)start the live coordinator. Builds
    /// the coordinator lazily on first connectable config. Idempotent and
    /// reconnect-safe: `applyConfig` restarts only when the resolved settings
    /// change.
    @MainActor private func resolveAndApply() async {
        defer { resolved = true }
        await seedFromEnvIfNeeded()
        guard await (try? gateway.loadBrokerConfig())?.isConnectable == true else {
            coordinator?.stop()
            return
        }
        let live = coordinator ?? LiveCoordinator(store: store)
        coordinator = live
        await live.applyConfig(gateway: gateway, credentials: credentials)
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
