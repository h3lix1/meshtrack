// GeneralSettingsViewModel — presentation logic for the General preferences screen
// (Phase 8). A testable `@MainActor @Observable` view model over the injected
// `ConfigGateway` port (SPEC §2.5/§10): it loads an `AppSettings`, exposes the live
// fields the form binds to, and persists via `gateway.saveAppSettings`. No SwiftUI
// here, so every transform (clamping, theme selection, dirty tracking) is unit-tested.

import Domain
import Observation

@Observable
@MainActor
public final class GeneralSettingsViewModel {
    /// The settings being edited. The form binds directly to these fields; `save()`
    /// writes the current value back through the gateway.
    public var settings: AppSettings

    /// The last value loaded from / saved to the gateway, so the UI can tell whether
    /// there are unsaved edits without re-querying the store.
    public private(set) var savedSettings: AppSettings

    /// Set after a failed `load`/`save`, surfaced as an inline banner. Cleared on the
    /// next successful round-trip.
    public private(set) var errorMessage: String?

    @ObservationIgnored private let gateway: any ConfigGateway

    public init(gateway: any ConfigGateway) {
        self.gateway = gateway
        let defaults = AppSettings.default
        settings = defaults
        savedSettings = defaults
    }

    /// Whether the edited settings differ from the last loaded/saved value.
    public var isDirty: Bool {
        settings != savedSettings
    }

    /// The theme presets the picker offers (reuses the existing `Theme` model).
    public let themePresets: [Theme] = Theme.presets

    /// The currently-selected theme preset, resolved from `settings.themeID`.
    /// Falls back to the first preset when nothing (or an unknown id) is selected.
    public var selectedTheme: Theme {
        themePresets.first { $0.id == settings.themeID } ?? themePresets[0]
    }

    /// Select a theme preset by storing its id.
    public func selectTheme(_ theme: Theme) {
        settings.themeID = theme.id
    }

    // MARK: Bounds (shared by the steppers/sliders and the clamp logic)

    /// Allowed refresh cadence (seconds). Too-fast hammers the store; too-slow makes
    /// the dashboard feel dead.
    public static let refreshIntervalRange: ClosedRange<Double> = 1 ... 60
    public static let refreshIntervalStep: Double = 1

    /// Allowed raw-telemetry retention (days). SPEC §5 default is 30.
    public static let retentionDaysRange: ClosedRange<Int> = 1 ... 365
    public static let retentionDaysStep = 1

    /// Clamp `refreshIntervalSeconds` into range, rounded to the step.
    public func setRefreshInterval(_ seconds: Double) {
        let clamped = min(
            Self.refreshIntervalRange.upperBound,
            max(Self.refreshIntervalRange.lowerBound, seconds)
        )
        settings.refreshIntervalSeconds = (clamped / Self.refreshIntervalStep).rounded() * Self
            .refreshIntervalStep
    }

    /// Nudge the refresh interval by whole steps, clamped.
    public func stepRefreshInterval(by steps: Int) {
        setRefreshInterval(settings.refreshIntervalSeconds + Double(steps) * Self.refreshIntervalStep)
    }

    /// Clamp `telemetryRetentionDays` into range.
    public func setRetentionDays(_ days: Int) {
        settings.telemetryRetentionDays = min(
            Self.retentionDaysRange.upperBound,
            max(Self.retentionDaysRange.lowerBound, days)
        )
    }

    /// Nudge retention by whole steps, clamped.
    public func stepRetentionDays(by steps: Int) {
        setRetentionDays(settings.telemetryRetentionDays + steps * Self.retentionDaysStep)
    }

    // MARK: Effects

    /// Load the persisted settings (or defaults) from the gateway.
    public func load() async {
        do {
            let loaded = try await gateway.loadAppSettings()
            settings = loaded
            savedSettings = loaded
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load settings: \(error)"
        }
    }

    /// Persist the current edits through the gateway.
    public func save() async {
        do {
            try await gateway.saveAppSettings(settings)
            savedSettings = settings
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't save settings: \(error)"
        }
    }
}
