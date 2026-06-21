@testable import App
import Domain
import Testing

@Suite("GeneralSettingsViewModel")
@MainActor
struct GeneralSettingsViewModelTests {
    @Test
    func `load defaults when nothing is saved`() async {
        let viewModel = GeneralSettingsViewModel(gateway: InMemoryConfigGateway())
        await viewModel.load()
        #expect(viewModel.settings == .default)
        #expect(viewModel.isDirty == false)
        #expect(viewModel.errorMessage == nil)
    }

    @Test
    func `AppSettings round-trips through the gateway`() async {
        let gateway = InMemoryConfigGateway()
        let editor = GeneralSettingsViewModel(gateway: gateway)
        await editor.load()

        editor.setRefreshInterval(7)
        editor.settings.useMetricUnits = false
        editor.selectTheme(.ember)
        editor.setRetentionDays(45)
        editor.settings.notificationsEnabled = false
        editor.settings.startAtLogin = true
        editor.settings.autoConnect = false
        #expect(editor.isDirty)
        await editor.save()
        #expect(editor.isDirty == false)

        // A fresh view model over the same gateway sees the persisted value.
        let reader = GeneralSettingsViewModel(gateway: gateway)
        await reader.load()
        #expect(reader.settings.refreshIntervalSeconds == 7)
        #expect(reader.settings.useMetricUnits == false)
        #expect(reader.settings.themeID == "ember")
        #expect(reader.settings.telemetryRetentionDays == 45)
        #expect(reader.settings.notificationsEnabled == false)
        #expect(reader.settings.startAtLogin == true)
        #expect(reader.settings.autoConnect == false)
    }

    @Test
    func `refresh interval clamps to range and steps`() {
        let viewModel = GeneralSettingsViewModel(gateway: InMemoryConfigGateway())
        viewModel.setRefreshInterval(1000)
        #expect(viewModel.settings.refreshIntervalSeconds == GeneralSettingsViewModel.refreshIntervalRange
            .upperBound)
        viewModel.setRefreshInterval(-5)
        #expect(viewModel.settings.refreshIntervalSeconds == GeneralSettingsViewModel.refreshIntervalRange
            .lowerBound)

        viewModel.setRefreshInterval(5)
        viewModel.stepRefreshInterval(by: 2)
        #expect(viewModel.settings.refreshIntervalSeconds == 7)
        viewModel.stepRefreshInterval(by: -100)
        #expect(viewModel.settings.refreshIntervalSeconds == GeneralSettingsViewModel.refreshIntervalRange
            .lowerBound)
    }

    @Test
    func `retention days clamps to range`() {
        let viewModel = GeneralSettingsViewModel(gateway: InMemoryConfigGateway())
        viewModel.setRetentionDays(9999)
        #expect(viewModel.settings.telemetryRetentionDays == GeneralSettingsViewModel.retentionDaysRange
            .upperBound)
        viewModel.setRetentionDays(0)
        #expect(viewModel.settings.telemetryRetentionDays == GeneralSettingsViewModel.retentionDaysRange
            .lowerBound)

        viewModel.setRetentionDays(30)
        viewModel.stepRetentionDays(by: 5)
        #expect(viewModel.settings.telemetryRetentionDays == 35)
    }

    @Test
    func `selected theme resolves from the id and falls back to the first preset`() {
        let viewModel = GeneralSettingsViewModel(gateway: InMemoryConfigGateway())
        // Nil id → first preset.
        viewModel.settings.themeID = nil
        #expect(viewModel.selectedTheme.id == Theme.presets[0].id)
        // Unknown id → first preset.
        viewModel.settings.themeID = "does-not-exist"
        #expect(viewModel.selectedTheme.id == Theme.presets[0].id)
        // Known id resolves.
        viewModel.selectTheme(.ember)
        #expect(viewModel.selectedTheme.id == "ember")
    }

    @Test
    func `isDirty tracks edits and clears after save`() async {
        let viewModel = GeneralSettingsViewModel(gateway: InMemoryConfigGateway())
        await viewModel.load()
        #expect(viewModel.isDirty == false)
        viewModel.setRetentionDays(60)
        #expect(viewModel.isDirty)
        await viewModel.save()
        #expect(viewModel.isDirty == false)
    }
}
