// GeneralSettingsView — the General preferences screen (Phase 8). A bespoke dark
// form over `GeneralSettingsViewModel`: a refresh-interval stepper, a units toggle,
// a theme picker (reusing the `Theme` presets), a retention stepper, and the boolean
// toggles. It is intentionally control-bespoke (custom step buttons, no stock
// `Stepper`/`ColorPicker`) so it renders deterministically under the headless
// `ImageRenderer` snapshot gate (see the snapshot-gotchas memo). The lead registers
// it for `SettingsTab.general` at integration.

import Domain
import Observation
import SwiftUI

public struct GeneralSettingsView: View {
    @Bindable private var viewModel: GeneralSettingsViewModel

    public init(viewModel: GeneralSettingsViewModel) {
        _viewModel = Bindable(viewModel)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollViewReader { _ in
                VStack(alignment: .leading, spacing: 22) {
                    refreshSection
                    displaySection
                    themeSection
                    retentionSection
                    behaviourSection
                    Spacer(minLength: 0)
                }
            }
            footer
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Self.canvas)
        .foregroundStyle(.white)
        // Load persisted settings before the operator can edit/Save, so opening the
        // tab never shows (and a Save never persists) default model state (Finding 3).
        .task { await viewModel.load() }
    }

    static let canvas = Color(red: 0.03, green: 0.04, blue: 0.10)

    // MARK: Header / footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("General").font(.title.bold())
            Text("app + collector preferences")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.bottom, 20)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let message = viewModel.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .lineLimit(2)
            } else if viewModel.isDirty {
                Text("Unsaved changes")
                    .font(.system(size: 11)).foregroundStyle(.yellow.opacity(0.85))
            }
            Spacer(minLength: 0)
            Button("Save") { Task { await viewModel.save() } }
                .buttonStyle(SettingsPrimaryButtonStyle(enabled: viewModel.isDirty))
                .disabled(!viewModel.isDirty)
        }
        .padding(.top, 18)
    }

    // MARK: Sections

    private var refreshSection: some View {
        SettingsGroup(title: "REFRESH") {
            StepperRow(
                label: "Refresh interval",
                detail: "how often newly-positioned nodes surface",
                value: String(format: "%.0fs", viewModel.settings.refreshIntervalSeconds),
                onDecrement: { viewModel.stepRefreshInterval(by: -1) },
                onIncrement: { viewModel.stepRefreshInterval(by: 1) },
                canDecrement: viewModel.settings.refreshIntervalSeconds >
                    GeneralSettingsViewModel.refreshIntervalRange.lowerBound,
                canIncrement: viewModel.settings.refreshIntervalSeconds <
                    GeneralSettingsViewModel.refreshIntervalRange.upperBound
            )
        }
    }

    private var displaySection: some View {
        SettingsGroup(title: "DISPLAY") {
            ToggleRow(
                label: "Use metric units",
                detail: "metres / °C vs feet / °F",
                isOn: $viewModel.settings.useMetricUnits
            )
        }
    }

    private var themeSection: some View {
        SettingsGroup(title: "THEME") {
            HStack(spacing: 10) {
                ForEach(viewModel.themePresets) { preset in
                    let isSelected = viewModel.settings.themeID == preset.id
                    Button { viewModel.selectTheme(preset) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(preset.accentColor).frame(width: 10, height: 10)
                            Text(preset.name).font(.system(size: 12))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.white.opacity(isSelected ? 0.16 : 0.05), in: Capsule())
                        .overlay(Capsule().strokeBorder(
                            preset.accentColor.opacity(isSelected ? 0.8 : 0),
                            lineWidth: 1
                        ))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var retentionSection: some View {
        SettingsGroup(title: "RETENTION") {
            StepperRow(
                label: "Raw telemetry",
                detail: "days kept before downsample-only rollups",
                value: "\(viewModel.settings.telemetryRetentionDays)d",
                onDecrement: { viewModel.stepRetentionDays(by: -1) },
                onIncrement: { viewModel.stepRetentionDays(by: 1) },
                canDecrement: viewModel.settings.telemetryRetentionDays >
                    GeneralSettingsViewModel.retentionDaysRange.lowerBound,
                canIncrement: viewModel.settings.telemetryRetentionDays <
                    GeneralSettingsViewModel.retentionDaysRange.upperBound
            )
        }
    }

    private var behaviourSection: some View {
        SettingsGroup(title: "BEHAVIOUR") {
            ToggleRow(
                label: "Notifications",
                detail: "deliver alerts to macOS Notification Center",
                isOn: $viewModel.settings.notificationsEnabled
            )
            ToggleRow(
                label: "Start at login",
                detail: "run the collector in the background via LaunchAgent",
                isOn: $viewModel.settings.startAtLogin
            )
            ToggleRow(
                label: "Auto-connect",
                detail: "connect to the configured broker on launch",
                isOn: $viewModel.settings.autoConnect
            )
        }
    }
}

// MARK: - Bespoke form components

/// A titled group of rows in the dark settings form.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 10, weight: .bold)).tracking(1)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.06)))
        }
    }
}

/// A label + detail on the left, a `.switch` toggle on the right. The detail text
/// wraps so a long subtitle never forces the row wider — that overflow is what used
/// to push the switches out of a consistent trailing column.
struct ToggleRow: View {
    let label: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            SettingsRowLabel(label: label, detail: detail)
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 9)
    }
}

/// The shared leading label + wrapping detail subtitle used by every settings row,
/// so the label column lines up and long helper text wraps instead of overflowing.
struct SettingsRowLabel: View {
    let label: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 13))
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A label + detail on the left, a bespoke −/value/+ stepper on the right. Bespoke
/// (no stock `Stepper`) so it renders deterministically headless.
struct StepperRow: View {
    let label: String
    let detail: String
    let value: String
    let onDecrement: () -> Void
    let onIncrement: () -> Void
    var canDecrement = true
    var canIncrement = true

    var body: some View {
        HStack(spacing: 12) {
            SettingsRowLabel(label: label, detail: detail)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                stepButton("minus", action: onDecrement, enabled: canDecrement)
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .frame(minWidth: 44)
                stepButton("plus", action: onIncrement, enabled: canIncrement)
            }
        }
        .padding(.vertical, 9)
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void, enabled: Bool) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(enabled ? 0.85 : 0.25))
                .frame(width: 24, height: 24)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// The save button's filled style; dims when there is nothing to save.
struct SettingsPrimaryButtonStyle: ButtonStyle {
    let enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 8)
            .background(
                (enabled ? Color.accentColor : Color.white.opacity(0.12))
                    .opacity(configuration.isPressed ? 0.7 : 1),
                in: RoundedRectangle(cornerRadius: 8)
            )
    }
}

#if DEBUG
    @MainActor private func previewGeneralViewModel() -> GeneralSettingsViewModel {
        let seeded = AppSettings(
            refreshIntervalSeconds: 5,
            themeID: "ember",
            useMetricUnits: false,
            telemetryRetentionDays: 45,
            notificationsEnabled: true,
            startAtLogin: true,
            autoConnect: true
        )
        let viewModel = GeneralSettingsViewModel(gateway: InMemoryConfigGateway(appSettings: seeded))
        viewModel.settings = seeded
        return viewModel
    }

    #Preview("General settings") {
        GeneralSettingsView(viewModel: previewGeneralViewModel())
            .frame(width: 560, height: 620)
    }
#endif
