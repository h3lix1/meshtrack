// ConnectionSettingsView — the Connection settings screen (Phase 8, SPEC §2.5 /
// §10). A bespoke dark form (no stock `Form`/`List` chrome so the headless
// ImageRenderer snapshot renders faithfully — memory: stock controls render badly
// headless) driving `ConnectionSettingsViewModel`.
//
// Fields: host + port, TLS + allow-untrusted toggles, a topics add/remove editor,
// username, a `SecureField` password, a "Test Connection" button surfacing the
// probe result, and Save. The password is never echoed to any label or log — only
// the obscured `SecureField` shows it.

import Domain
import SwiftUI

private enum Palette {
    static let background = Color(red: 0.03, green: 0.04, blue: 0.10)
    static let card = Color.white.opacity(0.04)
    static let field = Color.white.opacity(0.06)
    static let accent = Color.cyan
}

public struct ConnectionSettingsView: View {
    @State private var viewModel: ConnectionSettingsViewModel
    @State private var newTopic = ""

    public init(viewModel: ConnectionSettingsViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                DataSourcePicker(viewModel: viewModel)
                if viewModel.dataSourceKind == .mqtt {
                    brokerSection
                    securitySection
                    topicsSection
                    credentialsSection
                } else {
                    LocalNodeFields(viewModel: viewModel)
                }
                actionsSection
            }
            .padding(22)
        }
        .background(Palette.background)
        .foregroundStyle(.white)
        .task { try? await viewModel.load() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(Palette.accent)
                Text("Connection").font(.system(size: 18, weight: .bold))
            }
            Text("Where the live feed comes from: an MQTT broker, or a locally-attached "
                + "node over USB-serial or BLE. Credentials are stored in the Keychain — "
                + "never in the database or logs.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Broker (host / port)

    private var brokerSection: some View {
        section("BROKER") {
            HStack(alignment: .top, spacing: 12) {
                labeledField("Host", systemImage: "server.rack") {
                    textField("mqtt.example.org", text: $viewModel.host)
                }
                labeledField("Port", systemImage: "number") {
                    textField(viewModel.useTLS ? "8883" : "1883", text: $viewModel.portText)
                        .frame(width: 90)
                }
                .fixedSize()
            }
        }
    }

    // MARK: Security (TLS toggles)

    private var securitySection: some View {
        section("SECURITY") {
            VStack(alignment: .leading, spacing: 10) {
                toggleRow(
                    "Use TLS",
                    subtitle: "Encrypt the broker connection (recommended).",
                    isOn: $viewModel.useTLS
                )
                toggleRow(
                    "Allow untrusted certificate",
                    subtitle: "Accept self-signed / mismatched certs. Use with care.",
                    isOn: $viewModel.allowUntrustedCert
                )
                .disabled(!viewModel.useTLS)
                .opacity(viewModel.useTLS ? 1 : 0.4)
            }
        }
    }

    // MARK: Topics editor

    private var topicsSection: some View {
        section("SUBSCRIBE TOPICS") {
            VStack(alignment: .leading, spacing: 8) {
                if viewModel.topics.isEmpty {
                    Text("Add at least one topic to go live (e.g. msh/US/bayarea/2/e/#).")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                ForEach(Array(viewModel.topics.enumerated()), id: \.offset) { index, topic in
                    HStack(spacing: 10) {
                        Image(systemName: "number.circle.fill")
                            .font(.caption).foregroundStyle(Palette.accent)
                        Text(topic).font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Button {
                            viewModel.removeTopic(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .help("Remove topic")
                    }
                    .padding(10)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 9))
                }
                HStack(spacing: 10) {
                    textField("msh/REGION/2/e/CHANNEL/#", text: $newTopic)
                        .onSubmit(commitTopic)
                    Button(action: commitTopic) {
                        Label("Add", systemImage: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(Palette.accent.opacity(0.18), in: Capsule())
                            .foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(newTopic.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func commitTopic() {
        viewModel.addTopic(newTopic)
        newTopic = ""
    }

    // MARK: Credentials (username + secret password)

    private var credentialsSection: some View {
        section("CREDENTIALS") {
            VStack(alignment: .leading, spacing: 12) {
                labeledField("Username", systemImage: "person") {
                    textField("optional", text: $viewModel.username)
                }
                labeledField("Password", systemImage: "key.fill") {
                    SecureField("stored in Keychain", text: $viewModel.password)
                        .textFieldStyle(.plain)
                        .padding(9)
                        .background(Palette.field, in: RoundedRectangle(cornerRadius: 8))
                }
                Text("The password is held only in the Keychain, keyed by host + "
                    + "username. It is never written to the database or any log.")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Test + Save actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            testResultBanner
            HStack(spacing: 12) {
                Button {
                    Task { await viewModel.testConnection() }
                } label: {
                    Label("Test Connection", systemImage: "bolt.horizontal.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Palette.card, in: Capsule())
                        .overlay(Capsule().stroke(Palette.accent.opacity(0.5), lineWidth: 1))
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.isConnectable || viewModel.testResult == .testing)

                Spacer()

                if viewModel.didSave {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.green)
                }
                Button {
                    Task { try? await viewModel.save() }
                } label: {
                    Label("Save", systemImage: "tray.and.arrow.down.fill")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Palette.accent.opacity(0.22), in: Capsule())
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.isConnectable)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var testResultBanner: some View {
        switch viewModel.testResult {
        case .untested:
            EmptyView()
        case .testing:
            banner("Testing…", systemImage: "ellipsis.circle", tint: .yellow)
        case let .success(detail):
            banner("Connected — \(detail)", systemImage: "checkmark.seal.fill", tint: .green)
        case let .failure(reason):
            banner(reason, systemImage: "xmark.octagon.fill", tint: .red)
        }
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
            Spacer()
        }
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.4), lineWidth: 1))
    }

    // MARK: Reusable building blocks

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .bold)).tracking(1.5)
                .foregroundStyle(.white.opacity(0.5))
            content()
        }
        .padding(16)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func labeledField(
        _ label: String,
        systemImage: String,
        @ViewBuilder _ field: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            field()
        }
    }

    private func textField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .padding(9)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 8))
    }

    private func toggleRow(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Palette.accent)
        }
    }
}

#if DEBUG
    #Preview("Connection settings") {
        ConnectionSettingsView(
            viewModel: ConnectionSettingsViewModel(
                gateway: InMemoryConfigGateway(
                    broker: BrokerConfig(
                        host: "mqtt.bayme.sh",
                        port: 8883,
                        username: "meshtrack",
                        useTLS: true,
                        topics: ["msh/US/bayarea/2/e/#", "msh/US/2/e/LongFast/#"]
                    )
                ),
                credentials: {
                    let store = InMemoryCredentialStore()
                    try? store.setPassword("hunter2", host: "mqtt.bayme.sh", username: "meshtrack")
                    return store
                }(),
                test: { config, _ in
                    .success(detail: "\(config.topics.count) topic(s) subscribed")
                },
                dataSourceStore: InMemoryDataSourceStore(),
                serialDevices: StaticSerialDeviceEnumerator(
                    devices: ["/dev/cu.usbmodem3101", "/dev/cu.Bluetooth-Incoming-Port"]
                )
            )
        )
        .frame(width: 560, height: 760)
    }
#endif
