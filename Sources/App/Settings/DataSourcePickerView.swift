// DataSourcePickerView — the "where does the live feed come from" controls for the
// Connection settings screen: a three-way picker (MQTT broker / USB serial / BLE)
// plus the local-node fields that appear when a non-MQTT source is selected.
//
// Split out of `ConnectionSettingsView` to keep that file within the project's file
// / type-body length budget. It binds the same `ConnectionSettingsViewModel`, so the
// selection and device fields round-trip through the view model exactly as the broker
// fields do. Bespoke dark styling (no stock `Picker`/`Form`) so the headless
// ImageRenderer snapshot renders faithfully (memory: stock controls render badly
// headless).

import SwiftUI

private enum Palette {
    static let card = Color.white.opacity(0.04)
    static let field = Color.white.opacity(0.06)
    static let accent = Color.cyan
}

/// The data-source picker chips. Switching source clears any stale probe result and
/// (in the parent) swaps in the matching fields (broker vs serial/BLE).
struct DataSourcePicker: View {
    @Bindable var viewModel: ConnectionSettingsViewModel

    var body: some View {
        SettingsCard(title: "DATA SOURCE") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    chip(.mqtt, title: "MQTT broker", systemImage: "network")
                    chip(.serial, title: "USB serial", systemImage: "cable.connector")
                    chip(.ble, title: "Bluetooth", systemImage: "dot.radiowaves.left.and.right")
                }
                Text(subtitle)
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var subtitle: String {
        switch viewModel.dataSourceKind {
        case .mqtt: "Subscribe to a broker and decode the fleet's encrypted feed."
        case .serial: "Read packets from a node plugged in over USB."
        case .ble: "Read packets from a paired node over Bluetooth LE."
        }
    }

    private func chip(_ kind: DataSourceKind, title: String, systemImage: String) -> some View {
        let selected = viewModel.dataSourceKind == kind
        return Button {
            viewModel.selectDataSource(kind)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(
                    selected ? Palette.accent.opacity(0.22) : Palette.field,
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(selected ? Palette.accent.opacity(0.7) : .clear, lineWidth: 1)
                )
                .foregroundStyle(selected ? Palette.accent : .white.opacity(0.7))
        }
        .buttonStyle(.plain)
    }
}

/// The local-node fields: a `/dev/cu.*` device list/path for serial, or an optional
/// peripheral-name filter for BLE. Shown only when the selected source isn't MQTT.
struct LocalNodeFields: View {
    @Bindable var viewModel: ConnectionSettingsViewModel

    var body: some View {
        if viewModel.dataSourceKind == .serial {
            serial
        } else {
            ble
        }
    }

    private var serial: some View {
        SettingsCard(title: "SERIAL DEVICE") {
            VStack(alignment: .leading, spacing: 10) {
                let devices = viewModel.availableSerialDevices()
                if devices.isEmpty {
                    Text("No /dev/cu.* devices found. Plug in a node, or type its path below.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                ForEach(devices, id: \.self) { device in
                    deviceRow(device)
                }
                LabeledField(label: "Device path", systemImage: "cable.connector") {
                    PlainField(placeholder: "/dev/cu.usbserial-0001", text: $viewModel.serialDevicePath)
                }
                Text("Defaults to 115200 baud (Meshtastic's serial default). The path is "
                    + "the call-out device — a /dev/cu.* entry on macOS.")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func deviceRow(_ device: String) -> some View {
        let selected = viewModel.serialDevicePath == device
        return Button {
            viewModel.serialDevicePath = device
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Palette.accent : .white.opacity(0.4))
                Text(device).font(.system(size: 12, design: .monospaced))
                Spacer()
            }
            .padding(10)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    private var ble: some View {
        SettingsCard(title: "BLUETOOTH DEVICE") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledField(label: "Device name (optional)", systemImage: "dot.radiowaves.left.and.right") {
                    PlainField(placeholder: "e.g. Meshtastic_1a2b", text: $viewModel.bleDeviceName)
                }
                Text("Leave blank to connect to the first Meshtastic node found. BLE "
                    + "bring-up runs against real hardware; with no node in range the app "
                    + "shows \"no device\" rather than failing.")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Shared bespoke building blocks (also used by ConnectionSettingsView)

/// A titled dark card matching the Connection screen's section chrome.
struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .bold)).tracking(1.5)
                .foregroundStyle(.white.opacity(0.5))
            content()
        }
        .padding(16)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A label + field pair matching the Connection screen's labeled fields.
struct LabeledField<Field: View>: View {
    let label: String
    let systemImage: String
    @ViewBuilder let field: () -> Field

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            field()
        }
    }
}

/// A plain dark text field matching the Connection screen's inputs.
struct PlainField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .padding(9)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 8))
    }
}
