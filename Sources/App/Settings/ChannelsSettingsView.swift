// ChannelsSettingsView — the Channels & Keys settings screen (Phase 8, T-Channels).
// Bespoke dark UI over `ChannelsSettingsViewModel`: two capacity-capped sections
// (MQTT ≤ 20, local ≤ 7; SPEC §10), per-row key status with rotate/clear, and an
// add-channel field. PSKs are entered via `SecureField` and never echoed back — a
// row only ever shows "Key set" vs "No key" (SPEC §2.5).
//
// The view is store-free: the lead injects a `ChannelsSettingsViewModel` whose
// `ChannelKeyManaging` is the real Keychain adapter at integration.

import Domain
import SwiftUI

public struct ChannelsSettingsView: View {
    @State private var viewModel: ChannelsSettingsViewModel

    public init(viewModel: ChannelsSettingsViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let error = viewModel.lastError {
                    ErrorBanner(text: Self.message(for: error))
                }
                ChannelSection(kind: .mqtt, channels: viewModel.mqttChannels, viewModel: viewModel)
                ChannelSection(kind: .local, channels: viewModel.localChannels, viewModel: viewModel)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(red: 0.03, green: 0.04, blue: 0.10))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Channels & Keys").font(.title.bold()).foregroundStyle(.white)
            Text(
                "Channel PSKs are stored in the macOS Keychain — never in the database or "
                    + "logs. Enter or rotate a key to decode that channel's traffic."
            )
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    static func message(for error: ChannelsSettingsError) -> String {
        switch error {
        case let .capacityReached(kind):
            "\(kind.title) is full (\(kind.capacity) max)."
        case .emptyName:
            "Enter a channel name."
        case .duplicateChannel:
            "A channel with that name already exists."
        case .invalidKey:
            "Enter a valid base64 PSK (16 or 32 bytes) or \"AQ==\" for the default key."
        case .storeFailed:
            "Couldn't update the Keychain. Try again."
        }
    }
}

/// One capacity-capped channel section (MQTT or local) with its rows + add field.
private struct ChannelSection: View {
    let kind: ChannelKind
    let channels: [ChannelEntry]
    let viewModel: ChannelsSettingsViewModel

    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(kind.title).font(.headline).foregroundStyle(.white)
                Spacer()
                Text(viewModel.capacityLabel(for: kind))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(viewModel.canAdd(kind) ? .secondary : Color.orange)
            }

            if channels.isEmpty {
                Text("No channels yet.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(channels) { channel in
                        ChannelRow(channel: channel, viewModel: viewModel)
                    }
                }
            }

            addRow
        }
        .padding(16)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.06)))
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField("Add channel by name", text: $newName)
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .onSubmit(add)
            Button(action: add) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 10).padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .foregroundStyle(viewModel.canAdd(kind) ? Color.cyan : .secondary)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .disabled(!viewModel.canAdd(kind))
        }
    }

    private func add() {
        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        viewModel.addChannel(name: newName, kind: kind)
        if viewModel.lastError == nil {
            newName = ""
        }
    }
}

/// A single channel row: name + hash, a key-status pill, and rotate/clear/delete.
private struct ChannelRow: View {
    let channel: ChannelEntry
    let viewModel: ChannelsSettingsViewModel

    @State private var pskText = ""
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text(String(format: "hash 0x%02X", channel.hash))
                        .font(.system(size: 11).monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                KeyStatusPill(hasKey: channel.hasKey)
                Button(editing ? "Cancel" : (channel.hasKey ? "Rotate" : "Set key")) {
                    editing.toggle()
                    pskText = ""
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.cyan)
                if channel.hasKey {
                    Button("Clear") { viewModel.clearKey(forChannelHash: channel.hash) }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.orange)
                }
                Button {
                    viewModel.removeChannel(hash: channel.hash)
                } label: {
                    Image(systemName: "trash").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(.red.opacity(0.8))
            }

            if editing {
                keyEditor
            }
        }
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var keyEditor: some View {
        HStack(spacing: 8) {
            SecureField("base64 PSK or AQ==", text: $pskText)
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                .onSubmit(saveKey)
            Button("Default") {
                viewModel.useDefaultKey(forChannelHash: channel.hash)
                finishEditing()
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            Button("Save", action: saveKey)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(pskText.isEmpty ? Color.secondary : Color.cyan)
                .disabled(pskText.isEmpty)
        }
    }

    private func saveKey() {
        guard !pskText.isEmpty else { return }
        viewModel.setKey(forChannelHash: channel.hash, pskText: pskText)
        if viewModel.lastError == nil {
            finishEditing()
        }
    }

    private func finishEditing() {
        pskText = ""
        editing = false
    }
}

/// "Key set" / "No key" status indicator. Never shows the key itself.
private struct KeyStatusPill: View {
    let hasKey: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: hasKey ? "lock.fill" : "lock.open")
                .font(.system(size: 10))
            Text(hasKey ? "Key set" : "No key")
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .foregroundStyle(hasKey ? Color.green : Color.gray)
        .background((hasKey ? Color.green : Color.gray).opacity(0.15), in: Capsule())
    }
}

/// A dismissible-looking inline error banner.
private struct ErrorBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.system(size: 12)).foregroundStyle(.white)
            Spacer()
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

#Preview("Channels & Keys") {
    let keys = InMemoryChannelKeyManager()
    let defaultPSK = ChannelKeyMath.defaultPSK
    func add(_ name: String, _ kind: ChannelKind, key: Bool) {
        let hash = ChannelKeyMath.channelHash(name: name, psk: defaultPSK)
        keys.addChannel(name: name, hash: hash, kind: kind)
        if key {
            try? keys.setKey(ChannelKey(psk: defaultPSK), forChannelHash: hash)
        }
    }
    add("LongFast", .mqtt, key: true)
    add("BayMesh", .mqtt, key: false)
    add("admin", .local, key: true)
    return ChannelsSettingsView(viewModel: ChannelsSettingsViewModel(keys: keys))
        .frame(width: 640, height: 560)
}
